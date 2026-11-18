package com.relayphone.voip

import java.nio.file.Path
import kotlin.io.path.readText
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ReducerTest {
    @Test
    fun `every shared rule is exercised by the reducer`() {
        val observed = mutableSetOf<String>()
        fun scenario(previews: Boolean = false, outgoing: OutgoingMedia = OutgoingMedia.WHEN_PROVIDED) =
            Scenario(previews, outgoing, trace = { observed += it.id })
        fun remote(event: String, reason: EndReason = EndReason.RemoteEnded) =
            Input.RemoteEnd(EndTarget.Canonical(id), EventID(event), reason)
        fun Scenario.request(action: Action, name: String) = send(Input.Request(action, ActionID(name), supported = true))
        fun Scenario.report() = send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>().attempt
        fun Scenario.answer() = request(Action.Answer(id), "answer").only<Effect.RequestClaim>().attempt
        fun Scenario.start() = request(Action.Start(id, line, party), "start").only<Effect.RequestPlacement>().attempt
        fun Scenario.beginJoin(): Attempt {
            ring()
            send(remote("elsewhere", EndReason.AnsweredElsewhere))
            return request(Action.Join(id), "join").only<Effect.RequestPlacement>().attempt
        }
        val reset = Input.FrameworkReset(SystemFailure(Platform.ANDROID, SystemOperation.RESET))
        val actionError = CallError.SystemFailed(SystemFailure(Platform.ANDROID, SystemOperation.ACTION))
        val placementError = CallError.PlacementFailed(PlacementFailure.HANDLER_FAILED)
        val mediaError = CallError.MediaFailed(MediaStage.PREPARE, MediaFailure.TRANSPORT)
        val connected = Input.Connected(id, EventID("connected"), ConnectionAuthority.APPLICATION)
        scenario().apply {
            send(remote("before-invite"))
            val admission = report()
            request(Action.End(id), "before-admission")
            val end = send(Input.Admitted(admission)).only<Effect.CloseMedia>().attempt
            request(Action.End(id), "after-server-end")
            send(Input.SystemRemoved(end))
            send(Input.MediaReleased(end))
            assertTrue(send(Input.MediaPrepared(end)).isEmpty())
        }
        scenario(previews = true).apply {
            val admission = report()
            send(remote("before-admission", EndReason.AnsweredElsewhere))
            send(Input.Admitted(admission))
        }
        scenario().apply {
            val admission = report()
            val failure = SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION)
            assertTrue(send(Input.AdmissionFailed(admission.copy(generation = admission.generation + 1), failure)).isEmpty())
            send(Input.AdmissionFailed(admission, failure))
        }
        scenario().apply {
            val placement = start()
            send(Input.Placed(placement))
            send(Input.StartFailed(placement, SystemFailure(Platform.ANDROID, SystemOperation.START)))
        }
        scenario().apply {
            val admission = report()
            val cleanup = request(Action.End(id), "end").only<Effect.CloseMedia>().attempt
            request(Action.End(id), "repeat-end")
            send(Input.MediaReleased(cleanup))
            send(Input.Admitted(admission))
        }
        scenario().apply {
            ring()
            send(Input.BindRemote(id, RemoteCallID("alias")))
            at(state.configuration.budgets.incomingRing, TimerKind.NO_ANSWER)
        }
        scenario().apply {
            ring()
            send(remote("server-end"))
        }
        scenario().apply {
            ring()
            val authority = answer()
            val reconcile = at(state.configuration.budgets.answer.claim, TimerKind.CLAIM).only<Effect.Reconcile>().attempt
            send(Input.ReconciliationUnknown(reconcile))
            send(Input.AuthorityAllowed(authority, AttemptID("late")))
        }
        listOf(
            true to RefusalReason.AnsweredElsewhere,
            false to RefusalReason.DeclinedElsewhere,
            false to RefusalReason.NotAllowed,
        ).forEach { (previews, refusal) ->
            scenario(previews).apply {
                ring()
                send(Input.AnswerRefused(answer(), refusal))
            }
        }
        scenario().apply {
            val attempt = start()
            send(Input.Placed(attempt))
            send(connected)
            val media = send(Input.ProvideMedia(id)).only<Effect.PrepareMedia>().attempt
            send(Input.MediaPrepared(media))
        }
        scenario(outgoing = OutgoingMedia.DURING_PLACEMENT).apply {
            val media = send(Input.Placed(start())).only<Effect.PrepareMedia>().attempt
            send(Input.MediaPrepared(media))
        }
        scenario(previews = true).apply {
            val join = beginJoin()
            val media = send(Input.Placed(join)).only<Effect.PrepareMedia>().attempt
            send(Input.MediaPrepared(media))
            send(Input.Placed(join, placementError))
        }
        scenario(previews = true).apply {
            val media = send(Input.Placed(beginJoin())).only<Effect.PrepareMedia>().attempt
            send(Input.MediaFailed(media, mediaError))
        }
        scenario(previews = true).apply {
            beginJoin()
            at(state.configuration.budgets.placement, TimerKind.PLACEMENT)
        }
        scenario().apply {
            start()
            at(state.configuration.budgets.placement, TimerKind.PLACEMENT)
        }
        scenario().apply {
            send(Input.MediaFailed(connect(), mediaError))
        }
        scenario().apply {
            val media = connect()
            val recovery = send(Input.TransportLost(media)).only<Effect.ArmTimer>().attempt
            send(Input.TransportRecovered(recovery))
            val tones = Action.Tones(id, DTMFSequence("5"))
            send(Input.Request(tones, ActionID("unsupported")))
            listOf(Action.Hold(id, true), Action.Mute(id, true), Action.Video(id, true), tones)
                .forEachIndexed { index, action ->
                    val attempt = request(action, "fail-$index").controlAttempt()
                    send(Input.ApplyFailed(attempt, actionError))
                    val retry = request(action, "apply-$index").controlAttempt()
                    send(Input.Applied(retry))
                }
            send(reset)
        }

        val catalog = Wire.json.parseToJsonElement(Path.of(System.getProperty("spec.transitions")).readText())
            .jsonObject.getValue("rules").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }
        val declared = Rule.entries.map { it.id }
        assertEquals(catalog.sorted(), declared.sorted(), "Reducer tags must match the shared catalog")
        assertEquals(catalog.toSet(), observed, "Every catalog rule must run in the reducer")
    }

    @Test
    fun `claim timeout reconciles once and stale permits release once in either lifecycle`() {
        val scenario = Scenario()
        scenario.ring()
        val answer = Input.Request(Action.Answer(id), ActionID("answer"))
        val claim = scenario.send(answer).only<Effect.RequestClaim>()
        assertTrue(scenario.send(answer).isEmpty())
        val expired = scenario.at(2500.milliseconds, TimerKind.CLAIM)
        val reconciliation = expired.only<Effect.Reconcile>()
        assertEquals(listOf(Effect.ClaimTimedOut::class, Effect.ArmTimer::class, Effect.Reconcile::class), expired.map { it::class })
        assertEquals(claim.actionID, reconciliation.actionID)

        val stale = Input.AuthorityAllowed(claim.attempt, AttemptID("late"))
        assertEquals(listOf(Effect.ReleasePermit(stale.permit, stale.attempt)), scenario.send(stale))
        assertTrue(scenario.send(stale).isEmpty())

        val allowed = Input.AuthorityAllowed(reconciliation.attempt, AttemptID("live"))
        val preparation = scenario.send(allowed).only<Effect.PrepareMedia>()
        assertTrue(scenario.send(allowed).isEmpty())
        val settled = scenario.send(Input.MediaPrepared(preparation.attempt)).only<Effect.SettleAction>()
        assertEquals(claim.actionID, settled.actionID)
        val end = scenario.send(Input.Request(Action.End(id), ActionID("end")))
        assertEquals(allowed.permit, end.only<Effect.ReleasePermit>().permit)
        assertTrue(scenario.send(allowed).isEmpty())
    }

    @Test
    fun `timer deliveries and port completions cannot extend deadlines or reuse a generation`() {
        val scenario = Scenario()
        scenario.ring()
        val answer = scenario.send(Input.Request(Action.Answer(id), ActionID("answer"))).only<Effect.RequestClaim>()
        scenario.instant += 2500.milliseconds
        val late = scenario.send(Input.AuthorityAllowed(answer.attempt, AttemptID("too-late")))
        assertEquals(1, late.count { it is Effect.Reconcile })
        assertEquals(1, late.count { it is Effect.ReleasePermit })
        assertTrue(scenario.fire(TimerKind.CLAIM).isEmpty())
        val reconcile = late.only<Effect.Reconcile>()
        val preparation = scenario.send(Input.AuthorityAllowed(reconcile.attempt, AttemptID("within-reconciliation")))
            .only<Effect.PrepareMedia>()
        scenario.instant += 1500.milliseconds
        val result = scenario.send(Input.MediaPrepared(preparation.attempt))
        assertFalse(result.any { it is Effect.SettleAction })
        assertTrue(scenario.call.lifecycle is Lifecycle.Ending)
    }

    @Test
    fun `controls publish before settlement, reject once on end and ignore stale success`() {
        val scenario = Scenario()
        scenario.connect()
        val request = Input.Request(Action.Hold(id, true), ActionID("hold"), supported = true)
        val hold = scenario.send(request).only<Effect.Apply>()
        assertTrue(scenario.send(request).isEmpty())
        assertFalse(scenario.call.held)
        val failed = CallError.SystemFailed(SystemFailure(Platform.ANDROID, SystemOperation.ACTION))
        assertEquals(failed, scenario.send(Input.ApplyFailed(hold.attempt, failed)).only<Effect.RejectAction>().error)
        assertFalse(scenario.call.held)
        val next = scenario.send(request.copy(id = ActionID("retry"))).only<Effect.Apply>()
        assertTrue(scenario.send(Input.Applied(hold.attempt)).isEmpty())
        assertEquals(listOf(Effect.Publish::class, Effect.SettleAction::class), scenario.send(Input.Applied(next.attempt)).map { it::class })
        assertTrue(scenario.call.held)
        assertTrue(scenario.state.participating.isEmpty())

        val tones = Action.Tones(id, DTMFSequence("*1#"))
        assertEquals(CallError.Unsupported(Feature.TONES),
            scenario.send(Input.Request(tones, ActionID("no-transport"))).only<Effect.RejectAction>().error)
        val send = scenario.send(Input.Request(tones, ActionID("tones"), supported = true)).only<Effect.SendTones>()
        assertEquals(listOf(Effect.TonesPerformed::class, Effect.SettleAction::class), scenario.send(Input.Applied(send.attempt)).map { it::class })
        val video = scenario.send(Input.Request(Action.Video(id, true), ActionID("video"), supported = true)).only<Effect.Apply>()
        val teardown = scenario.send(Input.Request(Action.End(id), ActionID("end")))
        assertEquals(CallError.InvalidTransition(LifecycleKind.CONNECTED), teardown.only<Effect.RejectAction>().error)
        assertTrue(scenario.send(Input.Applied(video.attempt)).isEmpty())
    }

    @Test
    fun `a previous recovery cannot complete a later reconnection`() {
        val scenario = Scenario()
        val media = scenario.connect()
        val original = (scenario.call.lifecycle as Lifecycle.Connected).connectedAt
        val first = scenario.send(Input.TransportLost(media)).only<Effect.ArmTimer>().attempt
        scenario.send(Input.TransportRecovered(first))
        val second = scenario.send(Input.TransportLost(media)).only<Effect.ArmTimer>().attempt
        assertTrue(scenario.send(Input.TransportRecovered(first)).isEmpty())
        assertEquals(Lifecycle.Reconnecting(original), scenario.call.lifecycle)
        scenario.send(Input.TransportRecovered(second))
        assertEquals(Lifecycle.Connected(original), scenario.call.lifecycle)
    }

    @Test
    fun `binding drains both alias ends in receive order without inventing local End`() {
        val scenario = Scenario(previews = true)
        scenario.ring()
        val alias = RemoteCallID("alias")
        scenario.send(Input.RemoteEnd(EndTarget.Alias(alias), EventID("elsewhere"), EndReason.AnsweredElsewhere))
        scenario.send(Input.RemoteEnd(EndTarget.Alias(alias), EventID("remote"), EndReason.RemoteEnded))
        val effects = scenario.send(Input.BindRemote(id, alias))
        assertTrue(effects.filterIsInstance<Effect.Publish>().first().call.lifecycle is Lifecycle.Previewing)
        assertEquals(Lifecycle.Ending(EndReason.RemoteEnded), scenario.call.lifecycle)
        val end = scenario.send(Input.Request(Action.End(id), ActionID("end"))).only<Effect.CompleteEnd>()
        assertEquals(EndResult.AlreadyEnded(EndReason.RemoteEnded), end.result)
    }

    @Test
    fun `eager placement waits for preparation and still requires authoritative connection`() {
        val scenario = Scenario(outgoing = OutgoingMedia.DURING_PLACEMENT)
        val startID = ActionID("start")
        val placement = scenario.send(Input.Request(Action.Start(id, line, party), startID)).only<Effect.RequestPlacement>()
        val effects = scenario.send(Input.Placed(placement.attempt))
        assertEquals(Lifecycle.Placing, scenario.call.lifecycle)
        assertFalse(effects.any { it is Effect.NativeStart })
        val media = effects.only<Effect.PrepareMedia>()
        val start = scenario.send(Input.MediaPrepared(media.attempt)).only<Effect.NativeStart>()
        assertEquals(startID, start.actionID)
        assertEquals(Lifecycle.Dialing, scenario.call.lifecycle)
        scenario.send(Input.Connected(id, EventID("wrong-source"), ConnectionAuthority.NATIVE_MEDIA))
        assertEquals(Lifecycle.Dialing, scenario.call.lifecycle)
        val active = scenario.send(Input.Connected(id, EventID("connected"), ConnectionAuthority.APPLICATION)).only<Effect.SetActive>()
        assertEquals(media.attempt, active.attempt)
        assertTrue(scenario.call.lifecycle is Lifecycle.Connected)
    }

    @Test
    fun `preview join failure restores the preview and releases the owned media attempt`() {
        val scenario = Scenario(previews = true)
        scenario.ring()
        val preview = Lifecycle.Previewing(PreviewReason.AnsweredElsewhere)
        scenario.send(Input.RemoteEnd(EndTarget.Canonical(id), EventID("elsewhere"), EndReason.AnsweredElsewhere))
        assertEquals(preview, scenario.call.lifecycle)
        val join = scenario.send(Input.Request(Action.Join(id), ActionID("join"))).only<Effect.RequestPlacement>()
        val media = scenario.send(Input.Placed(join.attempt)).only<Effect.PrepareMedia>()
        assertEquals(ActionID("join"), scenario.send(Input.MediaPrepared(media.attempt)).only<Effect.SettleAction>().actionID)
        val failure = scenario.send(Input.Placed(join.attempt, CallError.PlacementFailed(PlacementFailure.HANDLER_FAILED)))
        assertEquals(media.attempt, failure.only<Effect.CloseMedia>().mediaAttempt)
        assertEquals(preview, scenario.call.lifecycle)
        assertTrue(scenario.send(Input.MediaPrepared(media.attempt)).isEmpty())
    }

    @Test
    fun `terminal records expire at 120 seconds and keep only the newest 256`() {
        val scenario = Scenario()
        repeat(257) { index ->
            val callID = CallID("call-$index")
            scenario.endAdmitted(callID).let(scenario::completeCleanup)
        }
        assertEquals(256, scenario.state.calls.size)
        assertFalse(CallID("call-0") in scenario.state.calls)
        val retained = CallID("call-1")
        scenario.instant += 119.seconds
        assertTrue(scenario.send(Input.Request(Action.End(retained), ActionID("repeat"))).only<Effect.CompleteEnd>().result is EndResult.Ended)
        scenario.instant += 1.seconds
        assertEquals(CallError.UnknownCall(retained),
            scenario.send(Input.Request(Action.End(retained), ActionID("after-expiry"))).only<Effect.RejectAction>().error)
        assertTrue(scenario.state.calls.isEmpty())
    }

    @Test
    fun `configured retention bounds terminal outcomes and buffered ends`() {
        val retention = RetentionBudget(lifetime = 2.seconds, terminalRecords = 1)
        val scenario = Scenario(budgets = Budgets().withRetention(retention))
        val earlier = CallID("earlier")
        val later = CallID("later")
        listOf(earlier, later).forEach { callID ->
            scenario.endAdmitted(callID).let(scenario::completeCleanup)
        }
        assertEquals(setOf(later), scenario.state.calls.keys)

        val unknown = CallID("unknown")
        scenario.send(Input.RemoteEnd(EndTarget.Canonical(unknown), EventID("before-admission"), EndReason.RemoteEnded))
        val fresh = scenario.send(Input.Incoming(unknown, EventID("fresh-invite"), line, party)).only<Effect.ReportIncoming>()
        val cleanup = scenario.send(Input.Admitted(fresh.attempt)).only<Effect.CloseMedia>().attempt
        assertEquals(Lifecycle.Ending(EndReason.RemoteEnded), scenario.state.calls.getValue(unknown).lifecycle)
        assertEquals(setOf(later, unknown), scenario.state.calls.keys)
        scenario.completeCleanup(cleanup)
        assertEquals(setOf(unknown), scenario.state.calls.keys)

        scenario.send(Input.RemoteEnd(EndTarget.Canonical(id), EventID("expired-end"), EndReason.RemoteEnded))
        scenario.instant += retention.lifetime
        scenario.ring()
        assertEquals(mapOf(id to Lifecycle.Ringing), scenario.state.calls.mapValues { it.value.lifecycle })
    }

    @Test
    fun `count and age bounds preserve late media and system cleanup`() {
        listOf(true, false).forEach { mediaIsLate ->
            val retention = RetentionBudget(lifetime = 1.seconds, terminalRecords = 1)
            val scenario = Scenario(budgets = Budgets().withRetention(retention))
            val late = scenario.endAdmitted(id)
            val media = Input.MediaReleased(late)
            val system = Input.SystemRemoved(late)
            val completion = if (mediaIsLate) media else system
            scenario.send(if (mediaIsLate) system else media)
            val completed = CallID("completed")
            scenario.completeCleanup(scenario.endAdmitted(completed))
            assertEquals(setOf(id, completed), scenario.state.calls.keys)
            scenario.instant += retention.lifetime
            scenario.send(Input.Request(Action.End(id), ActionID("repeat"))).only<Effect.CompleteEnd>()
            assertEquals(setOf(id), scenario.state.calls.keys)
            assertTrue(scenario.send(completion).only<Effect.Publish>().call.lifecycle is Lifecycle.Ended)
            assertTrue(scenario.state.calls.isEmpty())
        }
    }

    @Test
    fun `late admission reopens removal and a failed removal completes its generation`() {
        val retention = RetentionBudget(lifetime = 1.seconds, terminalRecords = 1)
        val scenario = Scenario(budgets = Budgets().withRetention(retention))
        val admission = scenario.send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>()
        val close = scenario.send(Input.Request(Action.End(id), ActionID("end"))).only<Effect.CloseMedia>()
        scenario.completeCleanup(close.attempt)
        scenario.instant += retention.lifetime
        val lateRemoval = scenario.send(Input.Admitted(admission.attempt)).only<Effect.RequestRemoval>()
        assertFalse(lateRemoval.attempt == close.attempt)
        assertFalse(id in scenario.state.systemRemoved)
        assertTrue(scenario.send(Input.SystemRemoved(close.attempt)).isEmpty())
        assertTrue(id in scenario.state.calls)
        assertTrue(scenario.send(Input.SystemRemovalFailed(lateRemoval.attempt)).isEmpty())
        assertTrue(scenario.state.calls.isEmpty())
    }

    @Test
    fun `an owned permit pins its terminated call until release is confirmed`() {
        val retention = RetentionBudget(lifetime = 1.seconds, terminalRecords = 1)
        val scenario = Scenario(budgets = Budgets().withRetention(retention))
        val media = scenario.connect()
        val end = scenario.send(Input.Request(Action.End(id), ActionID("end")))
        val release = end.only<Effect.ReleasePermit>()
        scenario.completeCleanup(end.only<Effect.CloseMedia>().attempt)
        scenario.instant += retention.lifetime
        assertTrue(scenario.send(Input.AuthorityAllowed(release.attempt, release.permit)).isEmpty())
        assertTrue(scenario.call.lifecycle is Lifecycle.Ended)
        scenario.send(Input.PermitReleased(media, release.permit))
        assertTrue(id in scenario.state.calls)
        scenario.send(Input.PermitReleased(release.attempt, release.permit))
        assertFalse(id in scenario.state.calls)
    }

    @Test
    fun `terminal cleanup waits for earlier preview cleanup under a tiny bound`() {
        val retention = RetentionBudget(lifetime = 1.seconds, terminalRecords = 1)
        val scenario = Scenario(previews = true, budgets = Budgets().withRetention(retention))
        scenario.ring()
        val first = scenario.send(Input.RemoteEnd(EndTarget.Canonical(id), EventID("elsewhere"), EndReason.AnsweredElsewhere))
            .only<Effect.CloseMedia>().attempt
        val second = scenario.send(Input.Request(Action.End(id), ActionID("end"))).only<Effect.CloseMedia>().attempt
        scenario.completeCleanup(second)
        scenario.instant += retention.lifetime
        assertTrue(scenario.send(Input.MediaReleased(first)).only<Effect.Publish>().call.lifecycle is Lifecycle.Ended)
        assertTrue(id in scenario.state.calls)
        scenario.send(Input.SystemRemoved(first))
        assertFalse(id in scenario.state.calls)
    }

    @Test
    fun `late preview admission can be removed while a join owns the current call`() {
        val scenario = Scenario(previews = true)
        val admission = scenario.send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>()
        scenario.send(Input.RemoteEnd(EndTarget.Canonical(id), EventID("elsewhere"), EndReason.AnsweredElsewhere))
        val reset = Input.FrameworkReset(SystemFailure(Platform.ANDROID, SystemOperation.RESET))
        scenario.completeCleanup(scenario.send(reset).only<Effect.CloseMedia>().attempt)
        scenario.send(Input.Request(Action.Join(id), ActionID("join"))).only<Effect.RequestPlacement>()
        val removal = scenario.send(Input.Admitted(admission.attempt)).only<Effect.RequestRemoval>()
        assertEquals(EndReason.AnsweredElsewhere, removal.reason)
        scenario.send(Input.SystemRemoved(removal.attempt))
        assertEquals(Lifecycle.Placing, scenario.call.lifecycle)
        assertFalse(id in scenario.state.systemRemoved)
    }

    @Test
    fun `framework reset retains the adapter supplied platform failure`() {
        Platform.entries.forEach { platform ->
            val scenario = Scenario()
            scenario.ring()
            val failure = SystemFailure(platform, SystemOperation.RESET, nativeCode = 42)
            val effects = scenario.send(Input.FrameworkReset(failure))
            val reason = EndReason.Failed(CallError.SystemFailed(failure))
            assertEquals(Lifecycle.Ending(reason), scenario.call.lifecycle)
            assertEquals(reason, effects.only<Effect.RequestRemoval>().reason)
        }
    }

    @Test
    fun `admission rejection preserves the retained reason without removal or preview`() {
        val scenario = Scenario(previews = true)
        val report = scenario.send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>()
        val reason = EndReason.AnsweredElsewhere
        scenario.send(Input.RemoteEnd(EndTarget.Canonical(id), EventID("elsewhere"), reason))
        val rejected = Input.AdmissionFailed(report.attempt, SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION))
        val effects = scenario.send(rejected)
        assertEquals(listOf(Effect.CloseMedia::class, Effect.Publish::class), effects.map { it::class })
        assertEquals(Lifecycle.Ending(reason), scenario.call.lifecycle)
        assertEquals(setOf(id), scenario.state.systemRemovalNotApplicable)
        assertTrue(scenario.send(rejected).isEmpty())
        assertTrue(scenario.send(Input.Admitted(report.attempt)).isEmpty())
    }

    @Test
    fun `rejection after local End releases the pending admission without changing the reason`() {
        val retention = RetentionBudget(lifetime = 1.seconds, terminalRecords = 1)
        val scenario = Scenario(budgets = Budgets().withRetention(retention))
        val report = scenario.send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>()
        val close = scenario.send(Input.Request(Action.End(id), ActionID("end"))).only<Effect.CloseMedia>()
        scenario.send(Input.MediaReleased(close.attempt))
        val ended = scenario.call.lifecycle
        val rejection = Input.AdmissionFailed(report.attempt, SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION))
        assertTrue(scenario.send(rejection).isEmpty())
        assertEquals(EndReason.LocalEnded, (ended as Lifecycle.Ended).reason)
        assertEquals(ended, scenario.call.lifecycle)
        assertEquals(setOf(id), scenario.state.systemRemovalNotApplicable)
        assertTrue(scenario.send(Input.SystemRemoved(close.attempt)).isEmpty())
        assertTrue(scenario.state.systemRemoved.isEmpty())
        assertEquals(setOf(id), scenario.state.systemRemovalNotApplicable)
        scenario.instant += retention.lifetime
        scenario.send(rejection)
        assertTrue(scenario.state.calls.isEmpty())
    }

    @Test
    fun `start rejection rejects the matching action once while placing or dialing`() {
        for (placed in listOf(false, true)) {
            val scenario = Scenario()
            val action = ActionID("start")
            val attempt = scenario.send(Input.Request(Action.Start(id, line, party), action))
                .only<Effect.RequestPlacement>().attempt
            if (placed) scenario.send(Input.Placed(attempt))
            val failure = SystemFailure(Platform.ANDROID, SystemOperation.START, nativeCode = 42)
            val error = CallError.SystemFailed(failure)
            assertTrue(scenario.send(Input.StartFailed(attempt.copy(generation = attempt.generation + 1), failure)).isEmpty())
            val rejected = Input.StartFailed(attempt, failure)
            val effects = scenario.send(rejected).filterNot { it is Effect.CancelTimer }
            assertEquals(listOf(Effect.RejectAction::class, Effect.CloseMedia::class, Effect.Publish::class), effects.map { it::class })
            assertEquals(Effect.RejectAction(id, action, error), effects.only<Effect.RejectAction>())
            assertEquals(Lifecycle.Ending(EndReason.Failed(error)), scenario.call.lifecycle)
            assertEquals(setOf(id), scenario.state.systemRemovalNotApplicable)
            assertTrue(scenario.send(rejected).isEmpty())
        }
    }

    private class Scenario(
        previews: Boolean = false, outgoing: OutgoingMedia = OutgoingMedia.WHEN_PROVIDED, budgets: Budgets = Budgets(),
        private val trace: (Rule) -> Unit = {},
    ) {
        var state = State(Configuration(budgets, outgoing, ConnectionAuthority.APPLICATION, 1, previews))
        var instant = Instant.fromEpochSeconds(0)
        private val timers = mutableMapOf<TimerKind, Effect.ArmTimer>()
        val call: Call get() = state.calls.getValue(id)

        fun send(input: Input): List<Effect> {
            val transition = reduce(state, input, Now(monotonic = instant, utc = instant), trace)
            state = transition.state
            transition.effects.filterIsInstance<Effect.ArmTimer>().forEach { timers[it.kind] = it }
            return transition.effects
        }

        fun fire(kind: TimerKind): List<Effect> = send(Input.TimerExpired(timers.getValue(kind).attempt, kind))

        fun at(elapsed: Duration, kind: TimerKind): List<Effect> {
            instant += elapsed
            return fire(kind)
        }

        fun ring() {
            admit(id, EventID("invite"))
        }

        fun endAdmitted(callID: CallID): Attempt {
            admit(callID, EventID("invite-${callID.value}"))
            return send(Input.Request(Action.End(callID), ActionID("end-${callID.value}"))).only<Effect.CloseMedia>().attempt
        }

        fun completeCleanup(attempt: Attempt) {
            send(Input.MediaReleased(attempt))
            send(Input.SystemRemoved(attempt))
        }

        private fun admit(callID: CallID, event: EventID) {
            val report = send(Input.Incoming(callID, event, line, party)).only<Effect.ReportIncoming>()
            send(Input.Admitted(report.attempt))
        }

        fun connect(): Attempt {
            ring()
            val answer = send(Input.Request(Action.Answer(id), ActionID("answer"))).only<Effect.RequestClaim>()
            val media = send(Input.AuthorityAllowed(answer.attempt, AttemptID("permit"))).only<Effect.PrepareMedia>()
            send(Input.MediaPrepared(media.attempt))
            send(Input.Connected(id, EventID("connected"), ConnectionAuthority.APPLICATION))
            return media.attempt
        }
    }

    private companion object {
        val id = CallID("call")
        val line = CallingLine(AccountID("account"), LineID("line"), "Line")
        val party = Party(PartyID("party"), Handle.Opaque("sip:caller@example.test"), "Caller")
        inline fun <reified T : Effect> List<Effect>.only(): T = filterIsInstance<T>().single()
        fun List<Effect>.controlAttempt(): Attempt =
            filterIsInstance<Effect.Apply>().singleOrNull()?.attempt ?: only<Effect.SendTones>().attempt
    }
}
