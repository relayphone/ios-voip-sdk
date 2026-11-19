package com.relayphone.voip.runtime

import com.relayphone.voip.Attempt
import com.relayphone.voip.ActionReceipt
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.CommandReceipt
import com.relayphone.voip.Configuration
import com.relayphone.voip.Effect
import com.relayphone.voip.IncomingResult
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.Now
import com.relayphone.voip.Outcome
import com.relayphone.voip.PlacementResult
import com.relayphone.voip.ReceiveDisposition
import com.relayphone.voip.RemovalCompletion
import com.relayphone.voip.RemoteCallID
import com.relayphone.voip.RemoteEvent
import com.relayphone.voip.State
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemFailureDetail
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.reduce
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Clock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Runs the pure call reducer in one coroutine. Each call owns its session, operations and timers. */
public class CallRuntime private constructor(
    configuration: Configuration,
    parent: CoroutineScope,
    private val system: SystemPort,
    private val authority: AuthorityPort,
    private val media: MediaPort,
    private val presentation: PresentationPort,
    private val monotonicClock: MonotonicClock,
    private val utcClock: Clock,
    private val timers: TimerPort,
    replayCapacity: Int,
) {
    private val lifetime = Job(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + lifetime)
    private val inbox = Channel<Message>(Channel.UNLIMITED, onUndeliveredElement = { message ->
        if (message is Message.Command) message.reply.complete(null)
    })
    private val accepting = AtomicBoolean(true)
    private val calls = mutableMapOf<CallID, CallWork>()
    private val timerJobs = mutableMapOf<Attempt, Job>()
    private val startSetups = mutableMapOf<Attempt, StartSetup>()
    private val placementJobs = mutableMapOf<Attempt, Job>()
    private val admissions = mutableMapOf<Attempt, CompletableDeferred<IncomingResult.Decision?>>()
    private val current = MutableStateFlow(State(configuration))
    private val journal = RuntimeJournal(current.value, replayCapacity)
    private var eventSequence = 0L
    private val observations = MutableSharedFlow<RuntimeEvent>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Latest domain state, independent of notification visibility and audio routing. */
    public val state: StateFlow<State> = current.asStateFlow()

    /**
     * Live event projection with its own positions. Use [observe] for bounded replay and
     * authoritative recovery alongside state revisions and cleanup results.
     */
    public val events: SharedFlow<RuntimeEvent> = observations.asSharedFlow()

    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                for (message in inbox) {
                    when (message) {
                        is Message.Deliver -> deliver(message.input)
                        is Message.Command -> {
                            try {
                                val receipt = deliver(message.input)
                                if (message.input is Input.Placed && receipt is CommandReceipt.Placement && receipt.accepted) {
                                    placementJobs.remove(message.input.attempt)?.cancel()
                                }
                                val admission = (receipt as? CommandReceipt.Incoming.Pending)?.let {
                                    admissions.getOrPut(it.attempt) { CompletableDeferred() }
                                }
                                message.reply.complete(receipt?.let { CommandReply(it, admission) })
                            } finally {
                                message.reply.complete(null)
                            }
                        }
                        is Message.StartSetupResolved -> deliver(requireNotNull(startSetups.remove(message.attempt)?.result()))
                        is Message.Finished -> finish(message)
                        is Message.RemovalFailed ->
                            deliver(Input.SystemRemovalFailed(message.attempt), removalFailure = message.failure)
                    }
                }
            } finally {
                shutdown()
            }
        }
    }

    /** Queues input from any port or caller. Returns false after shutdown. */
    public fun submit(input: Input): Boolean =
        accepting.get() && inbox.trySend(Message.Deliver(input.copyParties())).isSuccess

    /** Reads the authoritative state and cursor without starting adapter work. */
    public fun snapshot(): RuntimeSnapshot = journal.snapshot()

    /** Observes a snapshot and subsequent frames, or replays strictly after [after]. */
    public fun observe(after: RuntimeCursor? = null): Flow<RuntimeObservation> = journal.observe(after)

    /** Reports an invitation and waits for the decision of its original admission attempt. */
    public suspend fun reportIncoming(input: Input.Incoming): Outcome<IncomingResult, CallError> {
        val reply = command(input) ?: return Outcome.Failure(CallError.BridgeUnavailable)
        return when (val receipt = reply.receipt as CommandReceipt.Incoming) {
            is CommandReceipt.Incoming.Resolved -> Outcome.Success(receipt.result)
            is CommandReceipt.Incoming.Pending -> {
                val result = requireNotNull(reply.admission).await()
                    ?: return Outcome.Failure(CallError.BridgeUnavailable)
                Outcome.Success(if (receipt.duplicate) IncomingResult.Duplicate(result) else result)
            }
        }
    }

    /** Acknowledges a placement settlement only if the reducer accepted its current attempt. */
    public suspend fun settlePlacement(attempt: Attempt, result: PlacementResult): Boolean =
        (command(Input.Placed(attempt, result))?.receipt as? CommandReceipt.Placement)?.accepted == true

    /** Receives an application event and returns its authoritative disposition or a typed failure. */
    public suspend fun receive(event: RemoteEvent): Outcome<ReceiveDisposition, CallError> =
        when (val receipt = command(Input.Receive(event))) {
            null -> Outcome.Failure(CallError.BridgeUnavailable)
            else -> (receipt.receipt as CommandReceipt.Received).outcome
        }

    /** Binds a remote identity and applies any buffered events before resolving. */
    public suspend fun bindRemote(callID: CallID, remoteID: RemoteCallID): Outcome<Unit, CallError> =
        when (val receipt = command(Input.BindRemote(callID, remoteID))) {
            null -> Outcome.Failure(CallError.BridgeUnavailable)
            else -> (receipt.receipt as CommandReceipt.Bound).outcome
        }

    private suspend fun command(input: Input): CommandReply? {
        val reply = CompletableDeferred<CommandReply?>()
        if (!accepting.get() || inbox.trySend(Message.Command(input.copyParties(), reply)).isFailure) return null
        return reply.await()
    }

    private fun Input.copyParties(): Input = when (this) {
        is Input.Start -> copy(parties = Collections.unmodifiableList(parties.toList()))
        is Input.Receive -> when (val value = event) {
            is RemoteEvent.PartiesChanged -> copy(event = value.copy(parties = Collections.unmodifiableList(value.parties.toList())))
            else -> this
        }
        else -> this
    }

    /** Cancels and joins all port work, settles pending native setup results and clears [state]. */
    public suspend fun close() {
        accepting.set(false)
        lifetime.cancelAndJoin()
    }

    private suspend fun shutdown() {
        accepting.set(false)
        withContext(NonCancellable) {
            val jobs = calls.values.map { it.job }
            jobs.forEach { it.cancel() }
            jobs.joinAll()
        }
        inbox.cancel()
        try {
            // Cancellation can interrupt delivery after the receiver has dequeued a notification.
            for (setup in startSetups.values) {
                deliver(requireNotNull(setup.result()), receiptsOnly = true)
            }
        } finally {
            calls.clear()
            timerJobs.clear()
            startSetups.clear()
            placementJobs.clear()
            admissions.values.forEach { it.complete(null) }
            admissions.clear()
            publish(State(current.value.configuration), null)
        }
    }

    private fun deliver(
        input: Input, receiptsOnly: Boolean = false, removalFailure: SystemFailure? = null,
    ): CommandReceipt? {
        val previous = current.value
        val now = Now(monotonic = monotonicClock.now(), utc = utcClock.now())
        val pendingAdapterWork = calls.filterValues { it.jobs.isNotEmpty() }.keys
        val transition = reduce(previous, input, now, pendingAdapterWork)
        val removal = transition.removal
        val events = if (receiptsOnly) emptyList() else buildList {
            if (removalFailure != null && removal != null) {
                add(RuntimeEvent.SystemRemovalFailed(++eventSequence, removal.attempt, removalFailure))
            }
            for (effect in transition.effects) {
                when (effect) {
                    is Effect.ClaimTimedOut -> add(RuntimeEvent.ClaimTimedOut(++eventSequence, effect))
                    is Effect.TonesPerformed -> add(RuntimeEvent.TonesPerformed(++eventSequence, effect))
                    else -> Unit
                }
            }
            transition.terminalCompletions.forEach { add(RuntimeEvent.TerminalCompleted(++eventSequence, it)) }
        }
        publish(transition.state, input, removal, events, transition.actionPerformed.takeUnless { receiptsOnly })
        if (input is Input.AnswerConfirmed && !receiptsOnly) {
            system.completeAnswer(input, (transition.receipt as CommandReceipt.Answered).outcome)
        }
        transition.effects.forEach { effect ->
            if (!receiptsOnly || effect is Effect.SettleAction || effect is Effect.RejectAction) {
                execute(effect, previous)
            }
        }
        transition.admission?.let { (attempt, decision) ->
            admissions.remove(attempt)?.complete(decision)
        }
        return transition.receipt
    }

    private fun execute(effect: Effect, previous: State) {
        when (effect) {
            is Effect.ReportIncoming -> {
                val call = projection(effect.attempt, previous)
                launch(effect.attempt, WorkKind.SESSION) {
                    val result = system.reportIncoming(call, effect) { submit(Input.Admitted(effect.attempt)) }
                    if (result is Outcome.Failure) submit(Input.AdmissionFailed(effect.attempt, result.error))
                }
            }
            is Effect.NativeStart -> {
                val call = projection(effect.attempt, previous)
                val setup = StartSetup()
                check(startSetups.put(effect.attempt, setup) == null)
                launch(effect.attempt, WorkKind.SESSION) {
                    runOutgoingSession(call, effect, setup)
                }
            }
            is Effect.RequestPlacement -> {
                val call = projection(effect.attempt, previous)
                placementJobs[effect.attempt] = launch(effect.attempt) {
                    submit(Input.Placed(effect.attempt, authority.placeCall(call, effect)))
                }
            }
            is Effect.RequestClaim -> launch(effect.attempt) {
                completeClaim(effect.attempt, authority.claim(effect))
            }
            is Effect.Reconcile -> launch(effect.attempt) {
                completeClaim(effect.attempt, authority.reconcile(effect))
            }
            is Effect.ClaimTimedOut, is Effect.TonesPerformed -> Unit
            is Effect.ReleasePermit -> launch(effect.attempt, WorkKind.CLEANUP) {
                authority.release(effect)
                submit(Input.PermitReleased(effect.attempt, effect.permit))
            }
            is Effect.PrepareMedia -> launch(effect.attempt) {
                submit(when (val result = media.prepare(effect)) {
                    is Outcome.Success -> Input.MediaPrepared(effect.attempt)
                    is Outcome.Failure -> Input.MediaFailed(effect.attempt, result.error)
                })
            }
            is Effect.CloseMedia -> {
                launch(effect.attempt, WorkKind.CLEANUP) {
                    media.close(effect)
                    submit(Input.MediaReleased(effect.attempt))
                }
                calls.getValue(effect.attempt.callID).jobs.forEach { (job, kind) ->
                    if (kind == WorkKind.OPERATION) job.cancel()
                }
            }
            is Effect.RequestRemoval -> {
                val call = projection(effect.attempt, previous)
                launch(effect.attempt, WorkKind.CLEANUP) {
                    when (val result = system.remove(call, effect)) {
                        is Outcome.Success -> submit(Input.SystemRemoved(effect.attempt))
                        is Outcome.Failure -> inbox.trySend(
                            Message.RemovalFailed(effect.attempt, result.error),
                        )
                    }
                }
            }
            is Effect.SetActive -> launch(effect.attempt) { system.setActive(effect) }
            is Effect.Apply -> launch(effect.attempt) {
                completeControl(effect.attempt, system.apply(effect))
            }
            is Effect.SendTones -> launch(effect.attempt) {
                completeControl(effect.attempt, media.sendTones(effect))
            }
            is Effect.SettleAction -> system.settle(effect)
            is Effect.RejectAction -> system.reject(effect)
            is Effect.CompleteEnd -> system.completeEnd(effect)
            is Effect.Publish -> presentation.publish(effect.call)
            is Effect.ArmTimer -> {
                timerJobs[effect.attempt] = launch(effect.attempt, WorkKind.TIMER) {
                    timers.await(effect.deadline)
                    submit(Input.TimerExpired(effect.attempt, effect.kind))
                }
            }
            is Effect.CancelTimer -> timerJobs.remove(effect.attempt)?.cancel()
        }
    }

    private suspend fun runOutgoingSession(call: Call, request: Effect.NativeStart, setup: StartSetup) {
        val job = requireNotNull(currentCoroutineContext()[Job])
        var failure = SystemFailure(
            system.platform, SystemOperation.START, detail = SystemFailureDetail.SESSION_ENDED_BEFORE_ADMISSION,
        )
        try {
            job.ensureActive()
            val result = system.startOutgoing(call, request) {
                if (setup.complete(Input.StartAdmitted(request.attempt), job)) {
                    inbox.trySend(Message.StartSetupResolved(request.attempt))
                }
            }
            if (result is Outcome.Failure) failure = result.error
        } catch (error: Exception) {
            if (error is CancellationException || setup.result() != null) throw error
        } finally {
            if (setup.complete(Input.StartFailed(request.attempt, failure))) {
                inbox.trySend(Message.StartSetupResolved(request.attempt))
            }
        }
    }

    private fun projection(attempt: Attempt, previous: State): Call =
        current.value.calls[attempt.callID] ?: previous.calls.getValue(attempt.callID)

    private fun publish(
        state: State, input: Input?, removal: RemovalCompletion? = null,
        events: List<RuntimeEvent> = emptyList(), action: ActionReceipt? = null,
    ) {
        journal.publish(state, input, removal, events, action) { frame ->
            when (frame) {
                is RuntimeFrame.StateRevision -> current.value = frame.state
                is RuntimeFrame.Event -> observations.tryEmit(frame.event)
                is RuntimeFrame.TerminalCompleted -> observations.tryEmit(frame.event)
                is RuntimeFrame.Cleanup, is RuntimeFrame.ActionPerformed -> Unit
            }
        }
    }

    private fun completeClaim(attempt: Attempt, result: Reconciliation) {
        submit(when (result) {
            is AnswerDecision.Allow -> Input.AuthorityAllowed(attempt, result.permit)
            is AnswerDecision.Refuse -> Input.AnswerRefused(attempt, result.reason)
            Reconciliation.Unknown -> Input.ReconciliationUnknown(attempt)
        })
    }

    private fun completeControl(attempt: Attempt, result: Outcome<Unit, CallError>) {
        submit(when (result) {
            is Outcome.Success -> Input.Applied(attempt)
            is Outcome.Failure -> Input.ApplyFailed(attempt, result.error)
        })
    }

    private fun launch(attempt: Attempt, kind: WorkKind = WorkKind.OPERATION, operation: suspend () -> Unit): Job {
        val call = calls.getOrPut(attempt.callID) {
            val job = Job(lifetime)
            CallWork(job, CoroutineScope(scope.coroutineContext + job))
        }
        // Start each port invocation in effect order, then let it suspend independently.
        val child = call.scope.launch(start = CoroutineStart.UNDISPATCHED) { operation() }
        call.jobs[child] = kind
        child.invokeOnCompletion { inbox.trySend(Message.Finished(attempt, child)) }
        return child
    }

    private suspend fun finish(message: Message.Finished) {
        val id = message.attempt.callID
        val call = calls.getValue(id)
        placementJobs.remove(message.attempt, message.job)
        if (call.jobs.remove(message.job) == WorkKind.TIMER) {
            timerJobs.remove(message.attempt, message.job)
        }
        val lifecycle = current.value.calls[id]?.lifecycle
        if (call.jobs.isEmpty() && (lifecycle == null || lifecycle is Lifecycle.Ended)) {
            calls.remove(id)
            call.job.complete()
            call.job.join()
            if (lifecycle is Lifecycle.Ended) deliver(Input.AdapterIdle)
        }
    }

    private class CallWork(val job: CompletableJob, val scope: CoroutineScope) {
        val jobs = mutableMapOf<Job, WorkKind>()
    }

    private class StartSetup {
        private var result: Input? = null

        fun complete(input: Input, session: Job? = null): Boolean = synchronized(this) {
            if (result != null || session?.isActive == false) return@synchronized false
            result = input
            true
        }

        fun result(): Input? = synchronized(this) { result }
    }

    private enum class WorkKind { OPERATION, SESSION, CLEANUP, TIMER }

    private data class CommandReply(
        val receipt: CommandReceipt, val admission: CompletableDeferred<IncomingResult.Decision?>?,
    )

    private sealed interface Message {
        data class Deliver(val input: Input) : Message
        data class Command(val input: Input, val reply: CompletableDeferred<CommandReply?>) : Message
        data class StartSetupResolved(val attempt: Attempt) : Message
        data class Finished(val attempt: Attempt, val job: Job) : Message
        data class RemovalFailed(val attempt: Attempt, val failure: SystemFailure) : Message
    }

    public companion object {
        /** Validates the configured Answer budget against the registered system port before starting. */
        public fun start(
            configuration: Configuration,
            scope: CoroutineScope,
            system: SystemPort,
            authority: AuthorityPort,
            media: MediaPort,
            presentation: PresentationPort,
            monotonicClock: MonotonicClock,
            utcClock: Clock = Clock.System,
            timers: TimerPort = CoroutineTimers(monotonicClock),
            replayCapacity: Int = 64,
        ): Outcome<CallRuntime, CallError> = when (val validation = configuration.budgets.answer.validateFor(system.answerDeadline)) {
            is Outcome.Failure -> validation
            is Outcome.Success -> Outcome.Success(
                CallRuntime(
                    configuration, scope, system, authority, media, presentation, monotonicClock, utcClock, timers,
                    replayCapacity,
                ),
            )
        }
    }
}
