package com.relayphone.voip

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ReducerTest {
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
            scenario.send(Input.Incoming(callID, EventID("invite-$index"), line, party))
            val close = scenario.send(Input.Request(Action.End(callID), ActionID("end-$index"))).only<Effect.CloseMedia>()
            scenario.send(Input.MediaReleased(close.attempt))
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

    private class Scenario(previews: Boolean = false, outgoing: OutgoingMedia = OutgoingMedia.WHEN_PROVIDED) {
        var state = State(Configuration(Budgets(), outgoing, ConnectionAuthority.APPLICATION, 1, previews))
        var instant = Instant.fromEpochSeconds(0)
        private val timers = mutableMapOf<TimerKind, Effect.ArmTimer>()
        val call: Call get() = state.calls.getValue(id)

        fun send(input: Input): List<Effect> {
            val transition = reduce(state, input, instant)
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
            val report = send(Input.Incoming(id, EventID("invite"), line, party)).only<Effect.ReportIncoming>()
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
    }
}
