package com.relayphone.voip.system

import com.relayphone.voip.Action
import com.relayphone.voip.ActionID
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.Effect
import com.relayphone.voip.EndReason
import com.relayphone.voip.EndResult
import com.relayphone.voip.EndTarget
import com.relayphone.voip.EventID
import com.relayphone.voip.Feature
import com.relayphone.voip.Input
import com.relayphone.voip.Outcome
import com.relayphone.voip.Platform
import com.relayphone.voip.RetentionBudget
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.TimedStage
import com.relayphone.voip.runtime.SystemPort
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private val TELECOM_CALLBACK_LIMIT = 5.seconds
// Allow the callback to unwind and Core-Telecom to deliver its result before the platform timeout.
private val CALLBACK_RESERVE = 300.milliseconds
private val SESSION_CLEANUP_LIMIT = 5.seconds

internal class TelecomPort<NativeID : Any>(
    private val backend: TelecomBackend<NativeID>,
    private val submit: (Input) -> Boolean,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : SystemPort {
    override val platform = Platform.ANDROID
    override val answerDeadline = TELECOM_CALLBACK_LIMIT - CALLBACK_RESERVE

    private val sessions = Sessions<NativeID>()
    private val receipts = ConcurrentHashMap<ReceiptKey, Receipt>()

    suspend fun answer(callID: CallID): Outcome<Unit, CallError> {
        val session = sessions.find(callID) ?: return Outcome.Failure(CallError.UnknownCall(callID))
        val receipt = beginAnswer(session, Origin.APP) ?: return Outcome.Failure(CallError.BridgeUnavailable)
        return receipt.result.await()
    }

    override suspend fun reportIncoming(
        call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
    ): Outcome<Unit, SystemFailure> = runSession(call, SystemOperation.ADMISSION, admitted)

    override suspend fun startOutgoing(
        call: Call, request: Effect.NativeStart, admitted: () -> Unit,
    ): Outcome<Unit, SystemFailure> = runSession(call, SystemOperation.START, admitted)

    private suspend fun runSession(call: Call, operation: SystemOperation, admitted: () -> Unit):
        Outcome<Unit, SystemFailure> = coroutineScope {
        val session = Session<NativeID>(call.id, this)
        if (!sessions.reserve(session)) return@coroutineScope Outcome.Failure(failure(operation))
        var result: Outcome<Unit, SystemFailure> = Outcome.Success(Unit)
        try {
            withContext(dispatcher) {
                backend.addCall(call, TelecomCallbacks(
                    answer = { systemCallback(session) { systemAnswer(session) } },
                    disconnect = { systemCallback(session) { systemDisconnect(session) } },
                    setHeld = { held -> systemCallback(session) { systemHold(session, held) } },
                )) { control ->
                    sessions.attach(session, control)
                    admitted()
                    session.ready.complete(control)
                }
            }
        } catch (error: CancellationException) {
            val control = session.control
            if (control != null && session.beginDisconnect(Origin.APP)) {
                withContext(NonCancellable + dispatcher) {
                    val cleanup = withTimeoutOrNull(SESSION_CLEANUP_LIMIT) {
                        session.controlLock.withLock {
                            nativeResult(SystemOperation.REMOVAL) { control.disconnect(TelecomEnd.LOCAL) }
                        }
                    } ?: Outcome.Failure(failure(SystemOperation.REMOVAL))
                    session.disconnectReply.complete(cleanup)
                }
            }
            result = Outcome.Failure(failure(SystemOperation.REMOVAL))
            throw error
        } catch (error: Exception) {
            result = Outcome.Failure(failure(operation, error))
        } finally {
            val control = session.control
            session.ready.complete(null)
            synchronized(session) {
                session.closed = true
                session.answer?.let { receipt ->
                    val unavailable = Outcome.Failure(CallError.BridgeUnavailable)
                    receipt.decision.complete(unavailable)
                    receipt.result.complete(unavailable)
                    receipts.remove(receipt.key)
                }
            }
            session.finished.complete(if (control != null && result is Outcome.Success) {
                Outcome.Success(Unit)
            } else {
                Outcome.Failure(failure(SystemOperation.REMOVAL))
            })
            sessions.release(session)
        }
        if (session.control == null) {
            (result as? Outcome.Failure) ?: Outcome.Failure(failure(operation))
        } else {
            if (session.disconnectOrigin == null) {
                val setupFailure = (result as? Outcome.Failure)?.error
                sessionLost(session.id, CallError.SystemFailed(SystemFailure(platform, SystemOperation.ACTION, setupFailure?.nativeCode)))
            }
            Outcome.Success(Unit)
        }
    }

    override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
        val session = sessions.find(call.id)
            ?: return sessions.removal(call.id)?.await() ?: Outcome.Failure(failure(SystemOperation.REMOVAL))
        val control = session.ready.await() ?: return Outcome.Failure(failure(SystemOperation.REMOVAL))
        if (session.beginDisconnect(Origin.APP)) {
            var result: Outcome<Unit, SystemFailure> = Outcome.Failure(failure(SystemOperation.REMOVAL))
            try {
                result = session.controlLock.withLock {
                    nativeResult(SystemOperation.REMOVAL) { control.disconnect(telecomEnd(request.reason, call.direction)) }
                }
            } finally {
                session.disconnectReply.complete(result)
            }
        }
        return session.removal().await()
    }

    private suspend fun systemCallback(session: Session<NativeID>, perform: suspend () -> Unit) {
        val completed = withTimeoutOrNull(answerDeadline) {
            if (session.ready.await() == null) throw CallbackRejected()
            perform()
            true
        }
        if (completed == null) {
            val error = CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION)
            synchronized(session) {
                session.answer?.let { completeAnswer(session, it, Outcome.Failure(error)) }
            }
            sessionLost(session.id, error)
            throw CallbackRejected()
        }
    }

    private suspend fun systemDisconnect(session: Session<NativeID>) {
        if (!session.beginDisconnect(Origin.SYSTEM)) return
        request(Action.End(session.id)).requireAccepted()
    }

    private fun beginAnswer(session: Session<NativeID>, origin: Origin): Answer? {
        val answer = synchronized(session) {
            if (session.closed || session.disconnectOrigin != null) return null
            session.answer?.let { return it }
            Answer(key(session.id), origin).also {
                session.answer = it
                receipts[it.key] = it.decision
            }
        }
        if (!submit(Input.Request(Action.Answer(session.id), answer.key.actionID, effectiveDeadline = answerDeadline))) {
            answer.decision.complete(Outcome.Failure(CallError.BridgeUnavailable))
        }
        if (origin == Origin.APP) {
            session.scope.launch { finishAnswer(session, answer) }
        }
        return answer
    }

    private suspend fun systemAnswer(session: Session<NativeID>) {
        val answer = beginAnswer(session, Origin.SYSTEM) ?: throw CallbackRejected()
        // An app Answer can echo here while its own native operation is still suspended.
        // Both paths await the reducer's decision, and only the app path calls answer().
        val decision = answer.decision.await()
        if (answer.origin == Origin.SYSTEM) {
            val result = if (decision is Outcome.Failure) decision else Outcome.Success(Unit)
            completeAnswer(session, answer, result)
        }
        decision.requireAccepted()
    }

    private suspend fun finishAnswer(session: Session<NativeID>, answer: Answer) {
        val result = withTimeoutOrNull(answerDeadline) {
            val decision = answer.decision.await()
            if (decision is Outcome.Failure) return@withTimeoutOrNull decision
            val control = session.ready.await() ?: return@withTimeoutOrNull Outcome.Failure(CallError.BridgeUnavailable)
            session.controlLock.withLock {
                withContext(dispatcher) {
                    if (!session.canAnswer(answer)) return@withContext Outcome.Failure(CallError.BridgeUnavailable)
                    nativeResult(SystemOperation.ACTION) { control.answer() }.asAction().also {
                        if (it is Outcome.Failure) sessionLost(session.id, it.error)
                    }
                }
            }
        } ?: CallError.DeadlineExceeded(TimedStage.SYSTEM_ACTION).let { error ->
            sessionLost(session.id, error)
            Outcome.Failure(error)
        }
        completeAnswer(session, answer, result)
    }

    private fun completeAnswer(session: Session<NativeID>, answer: Answer, result: Outcome<Unit, CallError>) {
        synchronized(session) {
            if (result is Outcome.Failure && session.answer === answer) session.answer = null
            receipts.remove(answer.key)
            answer.result.complete(result)
        }
    }

    override suspend fun setActive(request: Effect.SetActive) {
        val session = sessions.find(request.attempt.callID) ?: return
        val answer = synchronized(session) { session.answer }
        if (answer != null) {
            answer.result.await()
            return
        }
        val control = session.ready.await() ?: return
        val result = nativeResult(SystemOperation.ACTION) { control.setHeld(false) }
        if (result is Outcome.Failure) sessionLost(session.id, CallError.SystemFailed(result.error))
    }

    override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> = when (val action = request.action) {
        is Action.Hold -> applyHold(action, request.actionID)
        is Action.Video -> Outcome.Failure(CallError.Unsupported(Feature.VIDEO))
        else -> Outcome.Failure(CallError.SystemFailed(failure(SystemOperation.ACTION)))
    }

    private suspend fun applyHold(action: Action.Hold, id: ActionID): Outcome<Unit, CallError> {
        val session = sessions.find(action.callID) ?: return Outcome.Failure(CallError.UnknownCall(action.callID))
        if (session.systemHold == id) {
            session.held = action.held
            return Outcome.Success(Unit)
        }
        val control = session.ready.await() ?: return Outcome.Failure(CallError.BridgeUnavailable)
        session.requestedHold = action.held
        return try {
            nativeResult(SystemOperation.ACTION) { control.setHeld(action.held) }.asAction().also {
                if (it is Outcome.Success) session.held = action.held
            }
        } finally {
            session.requestedHold = null
        }
    }

    private suspend fun systemHold(session: Session<NativeID>, held: Boolean) {
        if (session.closed || held == session.held || held == session.requestedHold) return
        val key = key(session.id)
        session.systemHold = key.actionID
        try {
            request(Action.Hold(session.id, held), key, supported = true).requireAccepted()
        } finally {
            session.systemHold = null
        }
    }

    override fun settle(result: Effect.SettleAction) {
        receipts[ReceiptKey(result.callID, result.actionID)]?.complete(Outcome.Success(null))
    }

    override fun reject(result: Effect.RejectAction) {
        result.actionID?.let { receipts[ReceiptKey(result.callID, it)] }?.complete(Outcome.Failure(result.error))
    }

    override fun completeEnd(result: Effect.CompleteEnd) {
        receipts[ReceiptKey(result.callID, result.actionID)]?.complete(Outcome.Success(result.result))
    }

    private suspend fun request(
        action: Action,
        key: ReceiptKey = key(action.callID),
        supported: Boolean = false,
    ): Outcome<EndResult?, CallError> {
        val receipt: Receipt = CompletableDeferred()
        receipts[key] = receipt
        return try {
            if (submit(Input.Request(action, key.actionID, supported))) receipt.await()
            else Outcome.Failure(CallError.BridgeUnavailable)
        } finally {
            receipts.remove(key)
        }
    }

    private suspend fun nativeResult(
        operation: SystemOperation, perform: suspend () -> Unit,
    ): Outcome<Unit, SystemFailure> = try {
        withContext(dispatcher) { perform() }
        Outcome.Success(Unit)
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Outcome.Failure(failure(operation, error))
    }

    private fun sessionLost(id: CallID, error: CallError) {
        submit(Input.RemoteEnd(EndTarget.Canonical(id), EventID(UUID.randomUUID().toString()),
            EndReason.Failed(error)))
    }

    private fun failure(operation: SystemOperation, error: Exception? = null): SystemFailure =
        SystemFailure(platform, operation, nativeCode = (error as? NativeTelecomFailure)?.code)
}

private typealias Receipt = CompletableDeferred<Outcome<EndResult?, CallError>>

private data class ReceiptKey(val callID: CallID, val actionID: ActionID)
private fun key(callID: CallID) = ReceiptKey(callID, ActionID(UUID.randomUUID().toString()))
private enum class Origin { APP, SYSTEM }
private class CallbackRejected : Exception()

private class Answer(val key: ReceiptKey, val origin: Origin) {
    val decision: Receipt = CompletableDeferred()
    val result = CompletableDeferred<Outcome<Unit, CallError>>()
}

private class Session<NativeID : Any>(val id: CallID, val scope: CoroutineScope) {
    @Volatile var control: TelecomControl<NativeID>? = null
    val ready = CompletableDeferred<TelecomControl<NativeID>?>()
    val finished = CompletableDeferred<Outcome<Unit, SystemFailure>>()
    val disconnectReply = CompletableDeferred<Outcome<Unit, SystemFailure>>()
    val controlLock = Mutex()
    @Volatile var disconnectOrigin: Origin? = null
        private set

    @Volatile var closed = false
    var answer: Answer? = null
    @Volatile var held = false
    @Volatile var requestedHold: Boolean? = null
    @Volatile var systemHold: ActionID? = null

    fun beginDisconnect(origin: Origin): Boolean = synchronized(this) {
        if (closed || disconnectOrigin != null) return false
        disconnectOrigin = origin
        true
    }

    fun canAnswer(receipt: Answer): Boolean = synchronized(this) {
        !closed && disconnectOrigin == null && answer === receipt
    }

    fun removal() = Removal(finished, disconnectReply.takeIf { disconnectOrigin == Origin.APP })
}

private class Removal(
    private val finished: CompletableDeferred<Outcome<Unit, SystemFailure>>,
    private val disconnect: CompletableDeferred<Outcome<Unit, SystemFailure>>?,
) {
    suspend fun await(): Outcome<Unit, SystemFailure> {
        val result = disconnect?.await()
        return if (result is Outcome.Failure) result else finished.await()
    }
}

private class Sessions<NativeID : Any> {
    private val byCall = mutableMapOf<CallID, Session<NativeID>>()
    private val byNative = mutableMapOf<NativeID, CallID>()
    private val recentRemovals = LinkedHashMap<CallID, Removal>()

    fun reserve(session: Session<NativeID>): Boolean = synchronized(this) {
        if (byCall.putIfAbsent(session.id, session) != null) return false
        recentRemovals.remove(session.id)
        true
    }

    fun find(id: CallID): Session<NativeID>? = synchronized(this) { byCall[id] }
    fun removal(id: CallID): Removal? = synchronized(this) { recentRemovals[id] }

    fun attach(session: Session<NativeID>, control: TelecomControl<NativeID>) = synchronized(this) {
        check(byNative.putIfAbsent(control.id, session.id) == null)
        session.control = control
    }

    fun release(session: Session<NativeID>) = synchronized(this) {
        session.control?.let {
            byNative.remove(it.id, session.id)
            recentRemovals[session.id] = session.removal()
            if (recentRemovals.size > removalLimit) {
                recentRemovals.remove(recentRemovals.keys.first())
            }
        }
        byCall.remove(session.id, session)
    }

    private companion object {
        val removalLimit = RetentionBudget().terminalRecords
    }
}

private fun Outcome<Unit, SystemFailure>.asAction(): Outcome<Unit, CallError> = when (this) {
    is Outcome.Success -> this
    is Outcome.Failure -> Outcome.Failure(CallError.SystemFailed(error))
}

private fun Outcome<EndResult?, CallError>.requireAccepted() {
    if (this is Outcome.Failure) throw CallbackRejected()
}
