package com.relayphone.voip

import kotlin.time.Instant

/** Call progress, independent of hold, mute, video and media preparation. */
public sealed interface Lifecycle {
    public data object Reporting : Lifecycle
    public data object Ringing : Lifecycle
    public data object Placing : Lifecycle
    public data object Dialing : Lifecycle
    public data object Connecting : Lifecycle
    public data class Previewing(public val reason: PreviewReason) : Lifecycle
    public data class Connected(public val connectedAt: Instant) : Lifecycle
    public data class Reconnecting(public val connectedAt: Instant) : Lifecycle
    public data class Ending(public val reason: EndReason) : Lifecycle
    public data class Ended(public val reason: EndReason, public val endedAt: Instant) : Lifecycle
}

/** Lifecycle discriminant used by invalid-transition errors. */
public enum class LifecycleKind {
    REPORTING, RINGING, PLACING, DIALING, CONNECTING, PREVIEWING, CONNECTED, RECONNECTING, ENDING, ENDED,
}

/** Exhaustive projection without collapsing lifecycle payloads. */
public val Lifecycle.kind: LifecycleKind
    get() = when (this) {
        Lifecycle.Reporting -> LifecycleKind.REPORTING
        Lifecycle.Ringing -> LifecycleKind.RINGING
        Lifecycle.Placing -> LifecycleKind.PLACING
        Lifecycle.Dialing -> LifecycleKind.DIALING
        Lifecycle.Connecting -> LifecycleKind.CONNECTING
        is Lifecycle.Previewing -> LifecycleKind.PREVIEWING
        is Lifecycle.Connected -> LifecycleKind.CONNECTED
        is Lifecycle.Reconnecting -> LifecycleKind.RECONNECTING
        is Lifecycle.Ending -> LifecycleKind.ENDING
        is Lifecycle.Ended -> LifecycleKind.ENDED
    }

/** A preview is distinct from ringing and can be joined through placement. */
public sealed interface PreviewReason {
    public data class Filtered(public val cause: FilterCause) : PreviewReason
    public data object AnsweredElsewhere : PreviewReason
    public data object Policy : PreviewReason
}

/** Terminal intent; failed and filtered ends always retain their typed cause. */
public sealed interface EndReason {
    public data object LocalDeclined : EndReason
    public data object LocalEnded : EndReason
    public data object RemoteEnded : EndReason
    public data object Unanswered : EndReason
    public data object AnsweredElsewhere : EndReason
    public data object DeclinedElsewhere : EndReason
    public data class Filtered(public val cause: FilterCause) : EndReason
    public data class Failed(public val error: CallError) : EndReason
}

/** Observed filtering cause; unknown is never inferred to be a platform Focus state. */
public enum class FilterCause { FOCUS, BLOCKED, POLICY, UNKNOWN }
