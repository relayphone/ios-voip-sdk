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
import com.relayphone.voip.reduce
import kotlin.time.Clock
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

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
    private val calls = mutableMapOf<CallID, CallWork>()
    private val timerJobs = mutableMapOf<Attempt, Job>()
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
        scope.launch {
            try {
                for (message in inbox) {
                    when (message) {
                        is Message.Deliver -> deliver(message.input)
                        is Message.Finished -> finish(message)
                        is Message.RemovalFailed -> {
                            deliver(Input.SystemRemovalFailed(message.attempt))
                            observe { sequence -> RuntimeEvent.SystemRemovalFailed(sequence, message.attempt, message.failure) }
                        }
                    }
                }
            } finally {
                calls.clear()
                timerJobs.clear()
            }
        }.invokeOnCompletion { inbox.cancel() }
    }

    /** Queues input from any port or caller. Returns false after shutdown. */
    public fun submit(input: Input): Boolean = inbox.trySend(Message.Deliver(input)).isSuccess

    /** Cancels the runtime and joins all port work and call scopes. */
    public suspend fun close() {
        inbox.cancel()
        lifetime.cancelAndJoin()
    }

    private fun deliver(input: Input) {
        val previous = current.value
        val now = Now(monotonic = monotonicClock.now(), utc = utcClock.now())
        val transition = reduce(previous, input, now)
        current.value = transition.state
        transition.effects.forEach { effect -> execute(effect, previous) }
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
                launch(effect.attempt, WorkKind.SESSION) {
                    val result = system.startOutgoing(call, effect)
                    if (result is Outcome.Failure) submit(Input.StartFailed(effect.attempt, result.error))
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

    private enum class WorkKind { OPERATION, SESSION, CLEANUP, TIMER }

    private sealed interface Message {
        data class Deliver(val input: Input) : Message
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
