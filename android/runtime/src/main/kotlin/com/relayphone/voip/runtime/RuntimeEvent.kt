package com.relayphone.voip.runtime

import com.relayphone.voip.Attempt
import com.relayphone.voip.Effect
import com.relayphone.voip.SystemFailure

/** Transient observations. Action completion has its own receipt in [SystemPort]. */
public sealed interface RuntimeEvent {
    /** Position in this runtime's observation stream, starting at one. */
    public val sequence: Long

    /** Claim timed out before reconciliation resolved ownership. */
    public data class ClaimTimedOut(
        override val sequence: Long, public val effect: Effect.ClaimTimedOut,
    ) : RuntimeEvent

    /** The transport confirmed a local tones request. */
    public data class TonesPerformed(
        override val sequence: Long, public val effect: Effect.TonesPerformed,
    ) : RuntimeEvent

    /** The adapter finished a removal attempt without confirming platform removal. */
    public data class SystemRemovalFailed(
        override val sequence: Long, public val attempt: Attempt, public val failure: SystemFailure,
    ) : RuntimeEvent
}
