package com.relayphone.voip.runtime

import com.relayphone.voip.Attempt
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.CallID
import com.relayphone.voip.Configuration
import com.relayphone.voip.Effect
import com.relayphone.voip.Input
import com.relayphone.voip.Lifecycle
import com.relayphone.voip.Now
import com.relayphone.voip.Outcome
import com.relayphone.voip.State
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemFailureDetail
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.reduce
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Clock
import kotlinx.coroutines.CancellationException
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
) {
    private val lifetime = Job(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + lifetime)
    private val inbox = Channel<Message>(Channel.UNLIMITED)
    private val accepting = AtomicBoolean(true)
    private val calls = mutableMapOf<CallID, CallWork>()
    private val timerJobs = mutableMapOf<Attempt, Job>()
    private val startSetups = mutableMapOf<Attempt, StartSetup>()
    private val current = MutableStateFlow(State(configuration))
    private var eventSequence = 0L
    private val observations = MutableSharedFlow<RuntimeEvent>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Latest domain state, independent of notification visibility and audio routing. */
    public val state: StateFlow<State> = current.asStateFlow()

    /**
     * Live observations with a bounded buffer. Use the first event as a baseline. A gap between
     * subsequent sequence numbers means observations were dropped and the reader should reload [state].
     */
    public val events: SharedFlow<RuntimeEvent> = observations.asSharedFlow()

    init {
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                for (message in inbox) {
                    when (message) {
                        is Message.Deliver -> deliver(message.input)
                        is Message.StartSetupResolved -> deliver(requireNotNull(startSetups.remove(message.attempt)?.result()))
                        is Message.Finished -> finish(message)
                        is Message.RemovalFailed -> {
                            deliver(Input.SystemRemovalFailed(message.attempt))
                            observe { sequence -> RuntimeEvent.SystemRemovalFailed(sequence, message.attempt, message.failure) }
                        }
                    }
                }
            } finally {
                shutdown()
            }
        }
    }

    /** Queues input from any port or caller. Returns false after shutdown. */
    public fun submit(input: Input): Boolean = accepting.get() && inbox.trySend(Message.Deliver(input)).isSuccess

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
            current.value = State(current.value.configuration)
        }
    }

    private fun deliver(input: Input, receiptsOnly: Boolean = false) {
        val previous = current.value
        val now = Now(monotonic = monotonicClock.now(), utc = utcClock.now())
        val transition = reduce(previous, input, now)
        current.value = transition.state
        transition.effects.forEach { effect ->
            if (!receiptsOnly || effect is Effect.SettleAction || effect is Effect.RejectAction) {
                execute(effect, previous)
            }
        }
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
                launch(effect.attempt) {
                    val error = (authority.place(call, effect) as? Outcome.Failure)?.error
                    submit(Input.Placed(effect.attempt, error))
                }
            }
            is Effect.RequestClaim -> launch(effect.attempt) {
                completeClaim(effect.attempt, authority.claim(effect))
            }
            is Effect.Reconcile -> launch(effect.attempt) {
                completeClaim(effect.attempt, authority.reconcile(effect))
            }
            is Effect.ClaimTimedOut -> observe { RuntimeEvent.ClaimTimedOut(it, effect) }
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
            is Effect.TonesPerformed -> observe { RuntimeEvent.TonesPerformed(it, effect) }
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

    private inline fun observe(event: (Long) -> RuntimeEvent) {
        observations.tryEmit(event(++eventSequence))
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
        if (call.jobs.remove(message.job) == WorkKind.TIMER) {
            timerJobs.remove(message.attempt, message.job)
        }
        val lifecycle = current.value.calls[id]?.lifecycle
        if (call.jobs.isEmpty() && (lifecycle == null || lifecycle is Lifecycle.Ended)) {
            calls.remove(id)
            call.job.complete()
            call.job.join()
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

    private sealed interface Message {
        data class Deliver(val input: Input) : Message
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
        ): Outcome<CallRuntime, CallError> = when (val validation = configuration.budgets.answer.validateFor(system.answerDeadline)) {
            is Outcome.Failure -> validation
            is Outcome.Success -> Outcome.Success(
                CallRuntime(configuration, scope, system, authority, media, presentation, monotonicClock, utcClock, timers),
            )
        }
    }
}
