package com.relayphone.voip.runtime

import com.relayphone.voip.Action
import com.relayphone.voip.ActionID
import com.relayphone.voip.ActionReceipt
import com.relayphone.voip.AttemptID
import com.relayphone.voip.Budgets
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.Configuration
import com.relayphone.voip.ConnectionAuthority
import com.relayphone.voip.Effect
import com.relayphone.voip.EndReason
import com.relayphone.voip.EndTarget
import com.relayphone.voip.EventID
import com.relayphone.voip.IncomingRefusal
import com.relayphone.voip.IncomingResult
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.OutgoingMedia
import com.relayphone.voip.Outcome
import com.relayphone.voip.Party
import com.relayphone.voip.PlacementResult
import com.relayphone.voip.Platform
import com.relayphone.voip.RefusalReason
import com.relayphone.voip.RemoteCallID
import com.relayphone.voip.RemoteEvent
import com.relayphone.voip.RetentionBudget
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.TimedStage
import com.relayphone.voip.Wire
import java.io.File
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
internal class BridgeRuntimeTest {
    private val commands = fixture("commands.json")
    private val incoming = commands.first { it.stringOrNull("operation") == "reportIncoming" && it.string("kind") == "command" }
        .getValue("input").jsonObject.let {
            Input.Incoming(
                CallID(it.string("callID")), EventID(it.string("eventID")),
                Wire.json.decodeFromJsonElement(CallingLine.serializer(), it.getValue("line")),
                Wire.json.decodeFromJsonElement(Party.serializer(), it.getValue("party")),
            )
        }

    @Test
    fun `incoming retries share the pending operation and return the retained decision`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        for (nativeResult in listOf(Outcome.Success(Unit), Outcome.Failure(admissionFailure))) {
            val suffix = ports.incomingReports
            val invitation = if (suffix == 0) incoming
                else incoming.copy(callID = CallID("call-$suffix"), eventID = EventID("event-$suffix"))
            val conflicting = invitation.copy(callID = CallID("different-call"))
            val first = async { runtime.reportIncoming(invitation) }
            val duplicate = async { runtime.reportIncoming(conflicting) }
            runCurrent()
            assertFalse(first.isCompleted)
            assertFalse(duplicate.isCompleted)
            assertEquals(suffix + 1, ports.incomingReports)

            ports.admission.complete(nativeResult)
            val expected = when (nativeResult) {
                is Outcome.Success -> {
                    assertEquals("admitted", commands.first {
                        it.string("kind") == "reply" && it.stringOrNull("operation") == "reportIncoming"
                    }.getValue("result").jsonObject.getValue("value").jsonObject.string("kind"))
                    IncomingResult.Admitted(invitation.callID)
                }
                is Outcome.Failure -> IncomingResult.Refused(invitation.callID, IncomingRefusal.SystemFailed(nativeResult.error))
            }
            assertEquals(Outcome.Success(expected), first.await())
            assertEquals(Outcome.Success(IncomingResult.Duplicate(expected)), duplicate.await())
            assertEquals(Outcome.Success(IncomingResult.Duplicate(expected)), runtime.reportIncoming(conflicting))
            assertFalse(conflicting.callID in runtime.snapshot().state.calls)
            assertEquals(suffix + 1, ports.incomingReports)
            ports.admission = CompletableDeferred()
        }
        runtime.close()
    }

    @Test
    fun `native admission at the invitation deadline is refused without publishing ringing`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        val initial = runtime.snapshot()
        val expiresAt = Instant.parse("2026-11-18T00:00:00.500Z")
        val receipt = async { runtime.reportIncoming(incoming.copy(expiresAt = expiresAt)) }
        runCurrent()
        advanceTimeBy(500)
        ports.admission.complete(Outcome.Success(Unit))
        assertEquals(Outcome.Success(IncomingResult.Refused(incoming.callID, IncomingRefusal.Expired)), receipt.await())
        val head = runtime.snapshot().cursor
        val frames = runtime.observe(initial.cursor).take(head.sequence.toInt()).toList()
        assertTrue(frames.filterIsInstance<RuntimeFrame.StateRevision>().none {
            it.state.calls[incoming.callID]?.lifecycle == Lifecycle.Ringing
        })
        runCurrent()
        assertTrue(incoming.callID in runtime.snapshot().state.systemRemoved)
        runtime.close()
    }

    @Test
    fun `journal confirms the fixture actions with their original receipts after state`() = runTest {
        val ports = Ports()
        val runtime = start(ports, capacity = 128)
        val scope = runtime.snapshot().cursor
        val transcript = fixture("actions.json").map { it.getValue("receipt") }
        val (answer, hold, end) = transcript.map { Wire.json.decodeFromJsonElement(ActionReceipt.serializer(), it) }
        val id = incoming.callID
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming)
        // A caller cannot confirm before the reducer authorizes the matching Answer.
        runtime.submit(Input.AnswerConfirmed(id, answer.actionID))
        runtime.submit(Input.Request(answer.action, answer.actionID, origin = answer.origin))
        runCurrent()
        assertEquals(Lifecycle.Connecting, runtime.snapshot().state.calls.getValue(id).lifecycle)
        val beforeAnswer = runtime.snapshot().cursor
        val before = runtime.observe(scope).take(beforeAnswer.sequence.toInt()).toList()
        assertTrue(before.none { it is RuntimeFrame.ActionPerformed })
        runtime.submit(Input.AnswerConfirmed(id, ActionID("unknown-answer")))
        runtime.submit(Input.AnswerConfirmed(id, answer.actionID))
        runtime.submit(Input.AnswerConfirmed(id, answer.actionID))
        runtime.receive(RemoteEvent.Connected(EventID("connected-a"), EndTarget.Canonical(id)))
        runtime.submit(Input.Request(hold.action, hold.actionID, supported = true, origin = hold.origin))
        runCurrent()
        runtime.submit(Input.Request(end.action, end.actionID, origin = end.origin))
        runtime.submit(Input.Request(Action.End(id), ActionID("repeated-end")))
        runCurrent()

        val head = runtime.snapshot().cursor
        val frames = runtime.observe(beforeAnswer).take((head.sequence - beforeAnswer.sequence).toInt()).toList()
        val receipts = frames.filterIsInstance<RuntimeFrame.ActionPerformed>()
        assertEquals(transcript, receipts.map { Wire.json.encodeToJsonElement(ActionReceipt.serializer(), it.receipt) })
        val revisions = receipts.map { confirmed ->
            frames.filterIsInstance<RuntimeFrame.StateRevision>().single {
                it.cursor.sequence + 1 == confirmed.cursor.sequence
            }.state.calls.getValue(id)
        }
        assertEquals(Lifecycle.Connecting, revisions[0].lifecycle)
        assertTrue(revisions[1].held)
        assertTrue(revisions[2].lifecycle is Lifecycle.Ending)
        runtime.close()
    }

    @Test
    fun `an Answer confirmation at its deadline is rejected without a performed frame`() = runTest {
        val ports = Ports()
        val runtime = start(ports, capacity = 128)
        val id = incoming.callID
        val actionID = ActionID("answer-deadline")
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming)
        runtime.submit(Input.Request(Action.Answer(id), actionID))
        runCurrent()
        assertEquals(Lifecycle.Connecting, runtime.snapshot().state.calls.getValue(id).lifecycle)
        val before = runtime.snapshot().cursor
        advanceTimeBy(Budgets().answer.total.inWholeMilliseconds)
        val confirmation = Input.AnswerConfirmed(id, actionID)
        runtime.submit(confirmation)
        runCurrent()

        val error = CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION)
        assertEquals(listOf(confirmation to Outcome.Failure(error)), ports.answers)
        val head = runtime.snapshot().cursor
        val frames = runtime.observe(before).take((head.sequence - before.sequence).toInt()).toList()
        assertTrue(frames.none { it is RuntimeFrame.ActionPerformed })
        assertEquals(Lifecycle.Ending(EndReason.Failed(error)), runtime.snapshot().state.calls.getValue(id).lifecycle)
        runtime.close()
    }

    @Test
    fun `placement commits the fixture alias and drains buffered events once`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        val alias = fixtureAlias()
        val id = CallID("outbound-a")
        val event = RemoteEvent.Connected(EventID("event-a"), EndTarget.Alias(alias))
        runtime.receive(event)
        val request = startPlacement(runtime, ports, id)
        assertTrue(runtime.settlePlacement(request.attempt, PlacementResult.Placed(alias)))
        assertFalse(runtime.settlePlacement(request.attempt, PlacementResult.Placed(RemoteCallID("second-alias"))))
        assertEquals(alias, runtime.snapshot().state.calls.getValue(id).remoteID)
        runCurrent()
        assertTrue(ports.placementFinished.isCompleted)
        assertEquals(1, ports.outgoingReports)
        assertTrue(runtime.snapshot().state.calls.getValue(id).lifecycle is Lifecycle.Connected)
        runtime.close()
    }

    @Test
    fun `preview join applies a connection buffered for the fixture alias`() = runTest {
        val placement = fixture("placement.json")
        val requested = placement.single { it.stringOrNull("kind") == "placementRequested" &&
            it.getValue("request").jsonObject.string("kind") == "join" }
        val id = CallID(requested.getValue("request").jsonObject.string("callID"))
        val actionID = ActionID(requested.string("actionID"))
        val settlement = placement.first {
            it.stringOrNull("operation") == "placement.settle" && it.string("kind") == "command" &&
                it.getValue("input").jsonObject.string("actionID") == actionID.value
        }
        val alias = RemoteCallID(settlement.getValue("input").jsonObject.getValue("result").jsonObject
            .getValue("value").jsonObject.string("remoteID"))
        val ports = Ports()
        val runtime = start(ports, previews = true)
        ports.mediaClose.complete(Unit)
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming.copy(callID = id))
        runtime.receive(RemoteEvent.Ended(EventID("elsewhere"), EndTarget.Canonical(id), EndReason.AnsweredElsewhere))
        assertTrue(runtime.snapshot().state.calls.getValue(id).lifecycle is Lifecycle.Previewing)
        runtime.receive(RemoteEvent.Connected(EventID("connect"), EndTarget.Alias(alias)))
        runtime.submit(Input.Request(Action.Join(id), actionID))
        assertTrue(runtime.settlePlacement(ports.request.await().attempt, PlacementResult.Placed(alias)))
        runCurrent()
        assertEquals(alias, runtime.snapshot().state.calls.getValue(id).remoteID)
        assertTrue(runtime.snapshot().state.calls.getValue(id).lifecycle is Lifecycle.Connected)
        runtime.close()
    }

    @Test
    fun `cancelled and expired attempts cannot bind the fixture alias`() = runTest {
        val placement = fixture("placement.json")
        val remaining = placement.first { it.string("kind") == "placementRequested" }.getValue("remainingMs").jsonPrimitive.long
        val alias = fixtureAlias()
        for (cancel in listOf(true, false)) {
            val ports = Ports()
            val runtime = start(ports, Budgets(placement = remaining.milliseconds))
            val id = CallID("outbound-a")
            val request = startPlacement(runtime, ports, id)
            if (cancel) {
                runtime.submit(Input.Request(Action.End(id), ActionID("end-a")))
                runCurrent()
            } else {
                // The settlement arrives at the boundary, before the timer coroutine runs again.
                advanceTimeBy(remaining)
            }
            assertFalse(runtime.settlePlacement(request.attempt, PlacementResult.Placed(alias)))
            assertNull(runtime.snapshot().state.calls.getValue(id).remoteID)
            assertEquals(0, ports.outgoingReports)
            runtime.close()
        }
    }

    @Test
    fun `placement preserves typed refusal and rejects an alias owned by another live call`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        val alias = fixtureAlias()
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming)
        runtime.bindRemote(incoming.callID, alias)

        val id = CallID("outbound-a")
        val request = startPlacement(runtime, ports, id)
        ports.placement.complete(PlacementResult.Placed(alias))
        val conflict = CallError.RemoteIdentityConflict(alias)
        runCurrent()
        assertEquals(conflict, ports.rejections.single { it.actionID == request.actionID }.error)
        assertEquals(alias, runtime.snapshot().state.calls.getValue(incoming.callID).remoteID)
        assertNull(runtime.snapshot().state.calls.getValue(id).remoteID)
        assertEquals(0, ports.outgoingReports)
        runtime.close()

        val refusing = Ports()
        val second = start(refusing)
        val refused = startPlacement(second, refusing, id)
        refusing.placement.complete(PlacementResult.Refused(RefusalReason.AnsweredElsewhere))
        runCurrent()
        assertEquals(CallError.Refused(RefusalReason.AnsweredElsewhere), refusing.rejections.single {
            it.actionID == refused.actionID
        }.error)
        second.close()
    }

    @Test
    fun `snapshots cover ordered cleanup and completion from the observation fixture`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        val transcript = fixture("observations.json")
        val id = CallID(transcript.first { it.stringOrNull("kind") == "cleanup" }.string("callID"))
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming.copy(callID = id))
        val ringing = runtime.snapshot()
        runtime.submit(Input.Request(Action.End(id), ActionID("end-a")))
        runCurrent()
        assertTrue(id in runtime.snapshot().state.systemRemoved)
        assertFalse(id in runtime.snapshot().state.completedTerminalCalls)
        ports.mediaClose.complete(Unit)
        runCurrent()

        val ended = runtime.snapshot()
        val frames = runtime.observe(ringing.cursor).take((ended.cursor.sequence - ringing.cursor.sequence).toInt()).toList()
            .filterIsInstance<RuntimeFrame>()
        assertEquals((ringing.cursor.sequence + 1..ended.cursor.sequence).toList(), frames.map { it.cursor.sequence })
        val cleanup = frames.filterIsInstance<RuntimeFrame.Cleanup>().single()
        val completion = frames.filterIsInstance<RuntimeFrame.TerminalCompleted>().single()
        assertTrue(cleanup.completion.removed)
        assertEquals(id, cleanup.completion.attempt.callID)
        assertEquals(id, completion.event.callID)
        assertTrue(cleanup.cursor.sequence < completion.cursor.sequence)
        assertTrue(id in ended.state.completedTerminalCalls)
        assertEquals(ended.state, runtime.state.value)
        runtime.close()
    }

    @Test
    fun `expired and foreign recovery cursors return a fresh snapshot then resume the journal`() = runTest {
        val ports = Ports()
        val runtime = start(ports, capacity = 2)
        val empty = runtime.snapshot()
        val transcript = fixture("recovery.json")
        val gapHead = transcript[2].getValue("cursor").jsonObject.getValue("sequence").jsonPrimitive.long
        repeat(gapHead.toInt()) { runtime.submit(Input.AdapterIdle) }
        runCurrent()
        val foreign = RuntimeCursor(transcript[4].getValue("cursor").jsonObject.string("epoch"), 1)
        for (cursor in listOf(empty.cursor, foreign, runtime.snapshot().cursor.copy(sequence = 99))) {
            val recovery = runtime.observe(cursor).take(3).onEach { observation ->
                if (observation is RuntimeObservation.Snapshot) runtime.submit(Input.AdapterIdle)
            }.toList()
            assertEquals(RuntimeObservation.ResyncRequired, recovery[0])
            val snapshot = (recovery[1] as RuntimeObservation.Snapshot).snapshot
            val next = recovery[2] as RuntimeFrame.StateRevision
            assertEquals(snapshot.cursor.copy(sequence = snapshot.cursor.sequence + 1), next.cursor)
        }
        assertEquals(runtime.snapshot(), (runtime.observe().first() as RuntimeObservation.Snapshot).snapshot)
        runtime.close()
    }

    @Test
    fun `a call that expires during cleanup still has an ordered completion`() = runTest {
        val ports = Ports()
        val runtime = start(ports, Budgets().withRetention(RetentionBudget(lifetime = 500.milliseconds)))
        ports.admission.complete(Outcome.Success(Unit))
        runtime.reportIncoming(incoming)
        val id = incoming.callID
        runtime.submit(Input.Request(Action.End(id), ActionID("end-a")))
        runCurrent()
        val pending = runtime.snapshot()
        advanceTimeBy(500)
        assertTrue(id in runtime.snapshot().state.calls)
        ports.mediaClose.complete(Unit)
        runCurrent()

        val head = runtime.snapshot()
        assertFalse(id in head.state.calls)
        val frames = runtime.observe(pending.cursor).take((head.cursor.sequence - pending.cursor.sequence).toInt()).toList()
        val revision = frames.filterIsInstance<RuntimeFrame.StateRevision>().first { id !in it.state.calls }
        assertEquals(setOf(id), revision.completing)
        val completed = frames.filterIsInstance<RuntimeFrame.TerminalCompleted>().single()
        assertEquals(id, completed.event.callID)
        assertEquals(revision.cursor.sequence + 1, completed.cursor.sequence)
        runtime.close()
    }

    @Test
    fun `a slow collector observes resync before reading the latest snapshot`() = runTest {
        val runtime = start(Ports(), capacity = 2)
        val resume = CompletableDeferred<Unit>()
        val reader = async {
            runtime.observe(runtime.snapshot().cursor).take(3).onEach {
                if (it is RuntimeFrame.StateRevision) resume.await()
                if (it == RuntimeObservation.ResyncRequired) {
                    runtime.receive(RemoteEvent.Connected(EventID("event-new"), EndTarget.Canonical(incoming.callID)))
                }
            }.toList()
        }
        runCurrent()
        runtime.submit(Input.AdapterIdle)
        runCurrent()
        repeat(3) { runtime.submit(Input.AdapterIdle) }
        runCurrent()
        val beforeRecovery = runtime.snapshot().cursor
        resume.complete(Unit)
        val observations = reader.await()
        assertEquals(1L, (observations[0] as RuntimeFrame.StateRevision).cursor.sequence)
        assertEquals(RuntimeObservation.ResyncRequired, observations[1])
        val snapshot = (observations[2] as RuntimeObservation.Snapshot).snapshot
        assertEquals(beforeRecovery.copy(sequence = beforeRecovery.sequence + 1), snapshot.cursor)
        runtime.close()
    }

    private suspend fun TestScope.startPlacement(runtime: CallRuntime, ports: Ports, id: CallID): Effect.RequestPlacement {
        val command = commands.single { it.string("kind") == "command" && it.stringOrNull("operation") == "start" }
        val parties = command.getValue("input").jsonObject.getValue("parties").jsonArray.map {
            Wire.json.decodeFromJsonElement(Party.serializer(), it)
        }
        runtime.submit(Input.Start(id, incoming.line, parties, video = false, ActionID("start-a")))
        return ports.request.await()
    }

    private fun fixtureAlias(): RemoteCallID =
        fixture("placement.json").first { it.stringOrNull("operation") == "placement.settle" }
            .getValue("input").jsonObject.getValue("result").jsonObject.getValue("value").jsonObject
            .let { RemoteCallID(it.string("remoteID")) }

    private fun TestScope.start(
        ports: Ports, budgets: Budgets = Budgets(), capacity: Int = 64, previews: Boolean = false,
    ): CallRuntime {
        val origin = Instant.parse("2026-11-18T00:00:00Z")
        val clock = MonotonicClock { origin + testScheduler.currentTime.milliseconds }
        val utc = object : Clock { override fun now(): Instant = clock.now() }
        val result = CallRuntime.start(
            Configuration(budgets, OutgoingMedia.DURING_PLACEMENT, ConnectionAuthority.APPLICATION, 1, previews),
            backgroundScope, ports, ports, ports, ports, clock, utc, replayCapacity = capacity,
        ) as Outcome.Success
        return result.value
    }

    private class Ports : SystemPort, AuthorityPort, MediaPort, PresentationPort {
        override val platform = Platform.ANDROID
        override val answerDeadline = 5.seconds
        val request = CompletableDeferred<Effect.RequestPlacement>()
        val placement = CompletableDeferred<PlacementResult>()
        val placementFinished = CompletableDeferred<Unit>()
        var admission = CompletableDeferred<Outcome<Unit, SystemFailure>>()
        val rejections = mutableListOf<Effect.RejectAction>()
        val answers = mutableListOf<Pair<Input.AnswerConfirmed, Outcome<Unit, CallError>>>()
        var incomingReports = 0
        var outgoingReports = 0
        val mediaClose = CompletableDeferred<Unit>()
        private val removal = mutableMapOf<CallID, CompletableDeferred<Unit>>()

        override suspend fun reportIncoming(
            call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            incomingReports++
            val result = admission.await()
            if (result is Outcome.Success) {
                val released = removal.getOrPut(call.id) { CompletableDeferred() }
                admitted()
                released.await()
            }
            return result
        }

        override suspend fun startOutgoing(
            call: Call, request: Effect.NativeStart, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            outgoingReports++
            admitted()
            awaitCancellation()
        }

        override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
            removal.remove(call.id)?.complete(Unit)
            return Outcome.Success(Unit)
        }

        override suspend fun placeCall(call: Call, request: Effect.RequestPlacement): PlacementResult {
            this.request.complete(request)
            try {
                return placement.await()
            } finally {
                placementFinished.complete(Unit)
            }
        }
        override suspend fun claim(request: Effect.RequestClaim): AnswerDecision = AnswerDecision.Allow(AttemptID("permit"))
        override suspend fun reconcile(request: Effect.Reconcile): Reconciliation = Reconciliation.Unknown
        override suspend fun release(request: Effect.ReleasePermit) = Unit
        override suspend fun prepare(request: Effect.PrepareMedia): Outcome<Unit, CallError.MediaFailed> = Outcome.Success(Unit)
        override suspend fun close(request: Effect.CloseMedia) = mediaClose.await()
        override suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError> = Outcome.Success(Unit)
        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> = Outcome.Success(Unit)
        override suspend fun setActive(request: Effect.SetActive) = Unit
        override fun settle(result: Effect.SettleAction) = Unit
        override fun reject(result: Effect.RejectAction) { rejections += result }
        override fun completeEnd(result: Effect.CompleteEnd) = Unit
        override fun completeAnswer(confirmation: Input.AnswerConfirmed, result: Outcome<Unit, CallError>) {
            answers += confirmation to result
        }
        override fun publish(call: Call) = Unit
    }

    private companion object {
        val admissionFailure = SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION, 42)

        fun fixture(name: String): List<JsonObject> =
            Wire.json.parseToJsonElement(File(System.getProperty("spec.bridge"), name).readText()).jsonArray.map { it.jsonObject }

        fun JsonObject.string(name: String) = getValue(name).jsonPrimitive.content
        fun JsonObject.stringOrNull(name: String) = get(name)?.jsonPrimitive?.content
    }
}
