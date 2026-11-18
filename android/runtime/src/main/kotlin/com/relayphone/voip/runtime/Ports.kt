package com.relayphone.voip.runtime

import com.relayphone.voip.AttemptID
import com.relayphone.voip.Call
import com.relayphone.voip.CallError
import com.relayphone.voip.Effect
import com.relayphone.voip.Outcome
import com.relayphone.voip.RefusalReason
import com.relayphone.voip.SystemFailure
import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.coroutines.delay

/**
 * Platform sessions and action receipts. Receipt methods resolve pending work without suspending.
 *
 * All runtime ports start undispatched on the runtime coroutine and must return or suspend promptly.
 * Switch to a separate dispatcher before any blocking work, Binder calls or I/O.
 */
public interface SystemPort {
    /** Effective allowance for a system Answer callback, including any adapter reserve. */
    public val answerDeadline: Duration

    /** Runs the incoming session. Invoke [admitted] on entry. Return an admission failure if setup was rejected before entry. */
    public suspend fun reportIncoming(
        call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
    ): Outcome<Unit, SystemFailure>

    /** Runs the outgoing session and settles Start on admission. Return a start failure if setup was rejected before admission. */
    public suspend fun startOutgoing(call: Call, request: Effect.NativeStart): Outcome<Unit, SystemFailure>

    /** Reports observed platform removal or a typed failure. */
    public suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure>

    /** Applies a platform control, returning only once the request has resolved. */
    public suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError>

    /** Requests active after the reducer has accepted authoritative connection. */
    public suspend fun setActive(request: Effect.SetActive)

    /** Fulfills the existing action receipt. */
    public fun settle(result: Effect.SettleAction)

    /** Rejects the existing action receipt with the supplied domain error. */
    public fun reject(result: Effect.RejectAction)

    /** Returns the original End result to the requesting receipt. */
    public fun completeEnd(result: Effect.CompleteEnd)
}

/** The current result of reconciling a pending Answer claim. */
public sealed interface Reconciliation {
    /** The authority could not establish ownership. */
    public data object Unknown : Reconciliation
}

/** A claim result may also settle reconciliation for the same action. */
public sealed interface AnswerDecision : Reconciliation {
    /** Ownership was granted with a permit that the runtime may later release. */
    public data class Allow(public val permit: AttemptID) : AnswerDecision

    /** Ownership was refused for a recognized domain reason. */
    public data class Refuse(public val reason: RefusalReason) : AnswerDecision
}

/** Native placement and Answer authority. All results belong to the supplied generation. */
public interface AuthorityPort {
    /** Resolves application placement without waiting for the remote party to connect. */
    public suspend fun place(call: Call, request: Effect.RequestPlacement): Outcome<Unit, CallError.PlacementFailed>

    /** Claims Answer for this receipt. Cancellation must release any permit the port cannot return. */
    public suspend fun claim(request: Effect.RequestClaim): AnswerDecision

    /** Reconciles the same Answer receipt within its remaining budget. */
    public suspend fun reconcile(request: Effect.Reconcile): Reconciliation

    /** Releases the permit identified by the original claim or reconciliation generation. */
    public suspend fun release(request: Effect.ReleasePermit)
}

/** Media work remains independent of platform admission and removal. */
public interface MediaPort {
    /** Prepares media for the supplied generation. */
    public suspend fun prepare(request: Effect.PrepareMedia): Outcome<Unit, CallError.MediaFailed>

    /** Closes the media gates on entry and returns after owned resources are released. */
    public suspend fun close(request: Effect.CloseMedia)

    /** Confirms local tone transport completion. */
    public suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError>
}

/** Accepts a call projection immediately. Platform presentation observations arrive separately. */
public fun interface PresentationPort {
    /** Queues the supplied projection for presentation without suspending the runtime. */
    public fun publish(call: Call)
}

/** Monotonic elapsed time represented as instants against a fixed, process-local epoch. */
public fun interface MonotonicClock {
    /** Returns elapsed time from the monotonic source, such as Android's elapsed realtime. */
    public fun now(): Instant
}

/** Waits for a deadline in the runtime's [MonotonicClock] time domain. */
public fun interface TimerPort {
    /** Returns at or after [deadline]; cancellation disarms the wait. */
    public suspend fun await(deadline: Instant)
}

/** Coroutine timers that recheck elapsed time on wake. */
public class CoroutineTimers(private val clock: MonotonicClock) : TimerPort {
    override suspend fun await(deadline: Instant) {
        while (true) {
            val remaining = deadline - clock.now()
            if (remaining <= Duration.ZERO) return
            delay(remaining)
        }
    }
}
