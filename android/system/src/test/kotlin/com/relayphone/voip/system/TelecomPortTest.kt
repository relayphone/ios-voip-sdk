package com.relayphone.voip.system

import com.relayphone.voip.AccountID
import com.relayphone.voip.Action
import com.relayphone.voip.Attempt
import com.relayphone.voip.ActionID
import com.relayphone.voip.Audio
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.Direction
import com.relayphone.voip.Effect
import com.relayphone.voip.EndReason
import com.relayphone.voip.Handle
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.LineID
import com.relayphone.voip.Media
import com.relayphone.voip.Outcome
import com.relayphone.voip.Owner
import com.relayphone.voip.Party
import com.relayphone.voip.PartyID
import com.relayphone.voip.Platform
import com.relayphone.voip.Preparation
import com.relayphone.voip.RefusalReason
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.TimedStage
import com.relayphone.voip.Transport
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
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
    fun `app Answer and an inline system echo use one action and one native answer`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        val admitted = CompletableDeferred<Unit>()
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted.complete(Unit) } }
        backend.open.complete(Unit)
        admitted.await()

        val first = async { port.answer(incoming.id) }
        val second = async { port.answer(incoming.id) }
        val answer = requests.receive() as Input.Request
        assertEquals(Action.Answer(incoming.id), answer.action)
        assertEquals(5.seconds, answer.effectiveDeadline)
        assertEquals(5.seconds, port.answerDeadline)
        port.settle(Effect.SettleAction(incoming.id, answer.id))

        assertEquals(Outcome.Success(Unit), first.await())
        assertEquals(Outcome.Success(Unit), second.await())
        assertEquals(1, backend.answers)
        assertFalse(requests.tryReceive().isSuccess)
        val removal = async { port.remove(incoming, Effect.RequestRemoval(attempt, EndReason.LocalEnded)) }
        assertEquals(TelecomEnd.LOCAL, backend.disconnected.await())
        backend.close.complete(Unit)
        removal.await()
        report.await()
    }

    @Test
    fun `an early system Answer waits for admission and shares a typed refusal with the app`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        var admitted = false
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) { admitted = true } }
        val callback = async { runCatching { backend.callbacks.await().answer() } }
        runCurrent()
        assertFalse(requests.tryReceive().isSuccess)
        backend.open.complete(Unit)

        val answer = requests.receive() as Input.Request
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
    fun `system callback and the shared app receipt expire at five seconds`() = runTest {
        val backend = FakeBackend()
        val requests = Channel<Input>(Channel.UNLIMITED)
        val port = TelecomPort(backend, { requests.trySend(it).isSuccess }, StandardTestDispatcher(testScheduler))
        val report = async { port.reportIncoming(incoming, Effect.ReportIncoming(attempt)) {} }
        backend.open.complete(Unit)
        val callback = async { runCatching { backend.callbacks.await().answer() } }
        assertEquals(Action.Answer(incoming.id), (requests.receive() as Input.Request).action)
        val app = async { port.answer(incoming.id) }
        runCurrent()
        advanceTimeBy(4_999)
        assertFalse(callback.isCompleted)
        advanceTimeBy(1)
        runCurrent()
        val error = CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION)
        assertEquals(Outcome.Failure(error), app.await())
        assertEquals(true, callback.await().isFailure)
        assertEquals(EndReason.Failed(error), (requests.receive() as Input.RemoteEnd).reason)
        backend.close.complete(Unit)
        report.await()
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

    private class FakeBackend(private val disconnectError: Int? = null) : TelecomBackend<Long> {
        val open = CompletableDeferred<Unit>()
        val close = CompletableDeferred<Unit>()
        val callbacks = CompletableDeferred<TelecomCallbacks>()
        val disconnected = CompletableDeferred<TelecomEnd>()
        var answers = 0
            private set

        override suspend fun addCall(
            call: Call, callbacks: TelecomCallbacks, admitted: (TelecomControl<Long>) -> Unit,
        ) {
            this.callbacks.complete(callbacks)
            open.await()
            admitted(object : TelecomControl<Long> {
                override val id = 101L
                override suspend fun answer() {
                    answers++
                    callbacks.answer()
                }
                override suspend fun setHeld(held: Boolean) = Unit
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
