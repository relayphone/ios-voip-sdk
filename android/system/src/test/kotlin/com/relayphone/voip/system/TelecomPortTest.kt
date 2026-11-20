package com.relayphone.voip.system

import com.relayphone.voip.AccountID
import com.relayphone.voip.Action
import com.relayphone.voip.ActionID
import com.relayphone.voip.ActionOrigin
import com.relayphone.voip.ActionReceipt
import com.relayphone.voip.AnswerBudget
import com.relayphone.voip.Attempt
import com.relayphone.voip.Budgets
import com.relayphone.voip.Audio
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.Configuration
import com.relayphone.voip.ConnectionAuthority
import com.relayphone.voip.Direction
import com.relayphone.voip.Effect
import com.relayphone.voip.EndReason
import com.relayphone.voip.EndTarget
import com.relayphone.voip.EventID
import com.relayphone.voip.Handle
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.LineID
import com.relayphone.voip.Media
import com.relayphone.voip.Outcome
import com.relayphone.voip.OutgoingMedia
import com.relayphone.voip.Owner
import com.relayphone.voip.Party
import com.relayphone.voip.PartyID
import com.relayphone.voip.PlacementResult
import com.relayphone.voip.Platform
import com.relayphone.voip.Preparation
import com.relayphone.voip.RefusalReason
import com.relayphone.voip.RemoteEvent
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.TimedStage
import com.relayphone.voip.Transport
import com.relayphone.voip.runtime.AnswerDecision
import com.relayphone.voip.runtime.AuthorityPort
import com.relayphone.voip.runtime.CallRuntime
import com.relayphone.voip.runtime.MediaPort
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.runtime.Reconciliation
import com.relayphone.voip.runtime.RuntimeFrame
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TelecomPortTest {
    @Test
    fun `session admission occurs at control entry and removal waits for session exit`() = runTest {
        val backend = FakeBackend()
        val port = TelecomPort(backend, { true }, StandardTestDispatcher(testScheduler))
        var admitted = false
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted = true } }
        runCurrent()
        assertFalse(admitted)
        backend.open.complete(Unit)
        runCurrent()
        assertEquals(true, admitted)
        assertFalse(report.isCompleted)

        val removal = async { port.remove(incoming, Effect.RequestRemoval(attempt, EndReason.AnsweredElsewhere)) }
        assertEquals(TelecomEnd.REMOTE, backend.disconnected.await())
        assertFalse(removal.isCompleted)
        backend.close.complete(Unit)
        assertEquals(Outcome.Success(Unit), removal.await())
        assertEquals(Outcome.Success(Unit), report.await())
    }

    @Test
    fun `rejections retain operation and native code before admission`() = runTest {
        val backend = TelecomBackendFailure()
        val port = TelecomPort(backend, { true }, StandardTestDispatcher(testScheduler))
        val report = port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { error("Unexpected admission") }
        val start = port.startOutgoing(outgoing, Effect.NativeStart(attempt, ActionID("start"))) {
            error("Unexpected admission")
        }
        assertEquals(Outcome.Failure(SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION, 7)), report)
        assertEquals(Outcome.Failure(SystemFailure(Platform.ANDROID, SystemOperation.START, 7)), start)
    }

    @Test
    fun `system hold releases participation and a held call cannot resume while another is active`() = runTest {
        val first = outgoing.id
        val second = CallID("second")
        val firstBackend = FakeBackend()
        val secondBackend = FakeBackend(nativeID = 102L)
        val dispatcher = StandardTestDispatcher(testScheduler)
        val backend = object : TelecomBackend<Long> {
            override suspend fun addCall(call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<Long>) -> Unit) {
                val session = if (call.id == first) firstBackend else secondBackend
                session.addCall(call, callbacks, admitted)
            }
        }
        lateinit var runtime: CallRuntime
        val port = TelecomPort(backend, { runtime.submit(it) }, dispatcher, testScheduler.timeSource)
        val authority = object : AuthorityPort {
            override suspend fun placeCall(call: Call, request: Effect.RequestPlacement) = PlacementResult.Placed()
            override suspend fun claim(request: Effect.RequestClaim): AnswerDecision = error("Unexpected claim")
            override suspend fun reconcile(request: Effect.Reconcile): Reconciliation = error("Unexpected reconciliation")
            override suspend fun release(request: Effect.ReleasePermit) = Unit
        }
        val media = object : MediaPort {
            override suspend fun prepare(request: Effect.PrepareMedia) = Outcome.Success(Unit)
            override suspend fun close(request: Effect.CloseMedia) = Unit
            override suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError> = error("Unexpected tones")
        }
        runtime = (CallRuntime.start(
            Configuration(Budgets(), OutgoingMedia.DURING_PLACEMENT, ConnectionAuthority.APPLICATION, 1, false),
            backgroundScope, port, authority, media, {}, MonotonicClock { Instant.fromEpochMilliseconds(testScheduler.currentTime) },
        ) as Outcome.Success).value
        firstBackend.open.complete(Unit)
        secondBackend.open.complete(Unit)

        suspend fun connect(id: CallID, session: FakeBackend) {
            assertTrue(runtime.startOutgoing(id, outgoing.line, outgoing.parties) is Outcome.Success)
            runtime.receive(RemoteEvent.Connected(EventID("connect-${id.value}"), EndTarget.Canonical(id)))
            assertEquals(false, session.nativeHolds.receive())
            assertTrue(runtime.snapshot().state.calls.getValue(id).lifecycle is Lifecycle.Connected)
        }

        connect(first, firstBackend)
        assertEquals(Outcome.Failure(CallError.Refused(RefusalReason.NotAllowed)),
            runtime.startOutgoing(second, outgoing.line, outgoing.parties))
        val beforeHold = runtime.snapshot().cursor
        firstBackend.callbacks.await().setHeld(true)
        val systemHold = runtime.observe(beforeHold).filterIsInstance<RuntimeFrame.ActionPerformed>().first().receipt
        assertEquals(Action.Hold(first, true), systemHold.action)
        assertEquals(ActionOrigin.SYSTEM, systemHold.origin)
        assertTrue(firstBackend.nativeHolds.tryReceive().isFailure)

        connect(second, secondBackend)
        assertEquals(setOf(second), runtime.snapshot().state.participating)
        assertEquals(Outcome.Failure(CallError.Refused(RefusalReason.NotAllowed)), runtime.setHeld(first, false))
        assertTrue(firstBackend.nativeHolds.tryReceive().isFailure)
        assertTrue(runtime.setHeld(first, true) is Outcome.Success)
        assertTrue(firstBackend.nativeHolds.tryReceive().isFailure)

        assertTrue(runtime.setHeld(second, true) is Outcome.Success)
        assertEquals(true, secondBackend.nativeHolds.receive())
        assertTrue(runtime.setHeld(first, false) is Outcome.Success)
        assertEquals(false, firstBackend.nativeHolds.receive())
        assertEquals(setOf(first), runtime.snapshot().state.participating)
        for ((id, session) in listOf(first to firstBackend, second to secondBackend)) {
            assertTrue(runtime.submit(Input.Request(Action.End(id), ActionID("end-${id.value}"))))
            assertEquals(TelecomEnd.LOCAL, session.disconnected.await())
            session.close.complete(Unit)
        }
        runtime.close()
    }

    @Test
    fun `app Answer and an inline system echo use one action and one native answer`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        val admitted = CompletableDeferred<Unit>()
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted.complete(Unit) } }
        backend.open.complete(Unit)
        admitted.await()

        val first = async { port.answerWithReceipt(incoming.id) }
        val second = async { port.answerWithReceipt(incoming.id) }
        val answer = requests.receive() as Input.Request
        assertEquals(Action.Answer(incoming.id), answer.action)
        assertEquals(ActionOrigin.APP, answer.origin)
        assertEquals(4_700.milliseconds, answer.effectiveDeadline)
        assertEquals(port.answerDeadline, answer.effectiveDeadline)
        port.settle(Effect.SettleAction(incoming.id, answer.id))

        val confirmation = requests.receive() as Input.AnswerConfirmed
        assertEquals(Input.AnswerConfirmed(incoming.id, answer.id), confirmation)
        assertFalse(first.isCompleted)
        port.completeAnswer(confirmation, Outcome.Success(Unit))
        val receipt = Outcome.Success(ActionReceipt(answer.id, answer.action, ActionOrigin.APP))
        assertEquals(receipt, first.await())
        assertEquals(receipt, second.await())
        assertEquals(1, backend.answers)
        assertFalse(requests.tryReceive().isSuccess)
        val removal = async { port.remove(incoming, Effect.RequestRemoval(attempt, EndReason.LocalEnded)) }
        assertEquals(TelecomEnd.LOCAL, backend.disconnected.await())
        backend.close.complete(Unit)
        removal.await()
        report.await()
    }

    @Test
    fun `an app retry keeps the first system Answer receipt and origin`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) {} }
        backend.open.complete(Unit)
        val callback = async { backend.callbacks.await().answer() }
        val answer = requests.receive() as Input.Request
        assertEquals(ActionOrigin.SYSTEM, answer.origin)
        val app = async { port.answerWithReceipt(incoming.id) }
        runCurrent()
        assertFalse(app.isCompleted)
        assertFalse(requests.tryReceive().isSuccess)

        port.settle(Effect.SettleAction(incoming.id, answer.id))
        val confirmation = requests.receive() as Input.AnswerConfirmed
        assertEquals(Input.AnswerConfirmed(incoming.id, answer.id), confirmation)
        assertFalse(callback.isCompleted)
        port.completeAnswer(confirmation, Outcome.Success(Unit))
        callback.await()
        assertEquals(Outcome.Success(ActionReceipt(answer.id, answer.action, ActionOrigin.SYSTEM)), app.await())
        assertFalse(requests.tryReceive().isSuccess)
        assertEquals(0, backend.answers)
        backend.close.complete(Unit)
        report.await()
    }

    @Test
    fun `an early system Answer waits for admission and shares a typed refusal with the app`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess },
            StandardTestDispatcher(testScheduler), testScheduler.timeSource)
        var admitted = false
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted = true } }
        val callback = async { runCatching { backend.callbacks.await().answer() } }
        runCurrent()
        assertFalse(requests.tryReceive().isSuccess)
        advanceTimeBy(800)
        backend.open.complete(Unit)

        val answer = requests.receive() as Input.Request
        assertEquals(3_900.milliseconds, answer.effectiveDeadline)
        assertEquals(true, admitted)
        val app = async { port.answer(incoming.id) }
        runCurrent()
        val refused = CallError.Refused(RefusalReason.NotAllowed)
        port.reject(Effect.RejectAction(incoming.id, answer.id, refused))
        assertEquals(Outcome.Failure(refused), app.await())
        assertEquals(true, callback.await().isFailure)
        assertEquals(0, backend.answers)
        assertFalse(requests.tryReceive().isSuccess)
        backend.close.complete(Unit)
        report.await()
    }

    @Test
    fun `a system callback with no decision fails before the Telecom limit`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) {} }
        backend.open.complete(Unit)
        val callback = async { runCatching { backend.callbacks.await().answer() } }
        assertEquals(Action.Answer(incoming.id), (requests.receive() as Input.Request).action)
        val app = async { port.answer(incoming.id) }
        runCurrent()
        advanceTimeBy(4_699)
        runCurrent()
        assertFalse(callback.isCompleted)
        assertFalse(app.isCompleted)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(callback.isCompleted)
        assertTrue(app.isCompleted)
        assertTrue(testScheduler.currentTime.milliseconds < 5.seconds)
        val error = CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION)
        assertEquals(Outcome.Failure(error), app.await())
        assertEquals(true, callback.await().isFailure)
        assertEquals(EndReason.Failed(error), (requests.receive() as Input.RemoteEnd).reason)
        backend.close.complete(Unit)
        report.await()
    }

    @Test
    fun `default Answer budget fits inside the effective callback deadline`() = runTest {
        val port = TelecomPort(FakeBackend(), { true }, StandardTestDispatcher(testScheduler))
        val budget = AnswerBudget()
        assertEquals(Outcome.Success(Unit), budget.validateFor(port.answerDeadline))
        assertEquals(200.milliseconds, port.answerDeadline - budget.total)
    }

    @Test
    fun `an unsuccessful disconnect never becomes confirmed on session exit`() = runTest {
        val backend = FakeBackend(disconnectError = 3)
        val port = TelecomPort(backend, { true }, StandardTestDispatcher(testScheduler))
        val admitted = CompletableDeferred<Unit>()
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted.complete(Unit) } }
        backend.open.complete(Unit)
        admitted.await()
        val request = Effect.RequestRemoval(attempt, EndReason.LocalEnded)
        val failure = Outcome.Failure(SystemFailure(Platform.ANDROID, SystemOperation.REMOVAL, 3))
        assertEquals(failure, port.remove(incoming, request))
        backend.close.complete(Unit)
        report.await()
        assertEquals(failure, port.remove(incoming, request))
    }

    @Test
    fun `transactional disconnects use the platform supported causes`() {
        val cases = mapOf(
            EndReason.LocalEnded to TelecomEnd.LOCAL,
            EndReason.LocalDeclined to TelecomEnd.REJECTED,
            EndReason.RemoteEnded to TelecomEnd.REMOTE,
            EndReason.AnsweredElsewhere to TelecomEnd.REMOTE,
            EndReason.DeclinedElsewhere to TelecomEnd.REMOTE,
            EndReason.Failed(CallError.Refused(RefusalReason.NotAllowed)) to TelecomEnd.REJECTED,
        )
        for (direction in Direction.entries) {
            cases.forEach { (reason, expected) -> assertEquals(expected, telecomEnd(reason, direction)) }
        }
        assertEquals(TelecomEnd.MISSED, telecomEnd(EndReason.Unanswered, Direction.INCOMING))
        assertEquals(TelecomEnd.REMOTE, telecomEnd(EndReason.Unanswered, Direction.OUTGOING))
    }

    private class FakeBackend(private val disconnectError: Int? = null, private val nativeID: Long = 101L) : TelecomBackend<Long> {
        val open = CompletableDeferred<Unit>()
        val close = CompletableDeferred<Unit>()
        val callbacks = CompletableDeferred<TelecomCallbacks>()
        val disconnected = CompletableDeferred<TelecomEnd>()
        val nativeHolds = Channel<Boolean>(Channel.UNLIMITED)
        var answers = 0
            private set

        override suspend fun addCall(
            call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<Long>) -> Unit,
        ) {
            this.callbacks.complete(callbacks)
            open.await()
            admitted(object : TelecomControl<Long> {
                override val id = nativeID
                override suspend fun answer() {
                    answers++
                    callbacks.answer()
                }
                override suspend fun setHeld(held: Boolean) {
                    callbacks.setHeld(held)
                    nativeHolds.send(held)
                }
                override suspend fun disconnect(cause: TelecomEnd) {
                    check(disconnected.complete(cause))
                    disconnectError?.let { throw NativeTelecomFailure(it) }
                }
            })
            close.await()
        }
    }

    private class TelecomBackendFailure : TelecomBackend<Long> {
        override suspend fun addCall(
            call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<Long>) -> Unit,
        ) {
            throw NativeTelecomFailure(7)
        }
    }

    private companion object {
        val attempt = Attempt(CallID("call-without-native-uuid"), 1)
        val incoming = Call(
            attempt.callID, CallingLine(AccountID("account"), LineID("default"), "Work"), Direction.INCOMING,
            listOf(Party(PartyID("party"), Handle.Phone("+12025550123"), "Example")), Lifecycle.Reporting,
            held = false, muted = false, video = false,
            Media(Owner.NATIVE, Preparation.UNPROVIDED, Audio.INACTIVE, Transport.DISCONNECTED),
        )
        val outgoing = incoming.copy(direction = Direction.OUTGOING, lifecycle = Lifecycle.Dialing)
    }
}
