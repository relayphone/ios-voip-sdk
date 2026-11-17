package com.relayphone.voip

import kotlin.time.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Call progress, independent of media and the hold, mute and video controls. */
@Serializable
public sealed interface Lifecycle {
    @Serializable @SerialName("reporting") public data object Reporting : Lifecycle
    @Serializable @SerialName("ringing") public data object Ringing : Lifecycle
    @Serializable @SerialName("placing") public data object Placing : Lifecycle
    @Serializable @SerialName("dialing") public data object Dialing : Lifecycle
    @Serializable @SerialName("connecting") public data object Connecting : Lifecycle
    @Serializable @SerialName("previewing") public data class Previewing(public val reason: PreviewReason) : Lifecycle
    @Serializable @SerialName("connected") public data class Connected(@Serializable(with = TimestampSerializer::class) public val connectedAt: Instant) : Lifecycle
    @Serializable @SerialName("reconnecting") public data class Reconnecting(@Serializable(with = TimestampSerializer::class) public val connectedAt: Instant) : Lifecycle
    @Serializable @SerialName("ending") public data class Ending(public val reason: EndReason) : Lifecycle
    @Serializable @SerialName("ended") public data class Ended(public val reason: EndReason, @Serializable(with = TimestampSerializer::class) public val endedAt: Instant) : Lifecycle
}

/** Lifecycle discriminant used by invalid-transition errors. */
@Serializable
public enum class LifecycleKind {
    @SerialName("reporting") REPORTING,
    @SerialName("ringing") RINGING,
    @SerialName("placing") PLACING,
    @SerialName("dialing") DIALING,
    @SerialName("connecting") CONNECTING,
    @SerialName("previewing") PREVIEWING,
    @SerialName("connected") CONNECTED,
    @SerialName("reconnecting") RECONNECTING,
    @SerialName("ending") ENDING,
    @SerialName("ended") ENDED,
}

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

/** A preview follows a call without ringing or taking part. */
@Serializable
public sealed interface PreviewReason {
    @Serializable @SerialName("filtered") public data class Filtered(public val cause: FilterCause) : PreviewReason
    @Serializable @SerialName("answeredElsewhere") public data object AnsweredElsewhere : PreviewReason
    @Serializable @SerialName("policy") public data object Policy : PreviewReason
}

/** Terminal intent. Failed and filtered ends retain their typed cause. */
@Serializable
public sealed interface EndReason {
    @Serializable @SerialName("localDeclined") public data object LocalDeclined : EndReason
    @Serializable @SerialName("localEnded") public data object LocalEnded : EndReason
    @Serializable @SerialName("remoteEnded") public data object RemoteEnded : EndReason
    @Serializable @SerialName("unanswered") public data object Unanswered : EndReason
    @Serializable @SerialName("answeredElsewhere") public data object AnsweredElsewhere : EndReason
    @Serializable @SerialName("declinedElsewhere") public data object DeclinedElsewhere : EndReason
    @Serializable @SerialName("filtered") public data class Filtered(public val cause: FilterCause) : EndReason
    @Serializable @SerialName("failed") public data class Failed(public val error: CallError) : EndReason {
        init { require(error !is CallError.Refused || error.reason == RefusalReason.NotAllowed) }
    }
}

/** Platform-neutral filtering reason. */
@Serializable
public enum class FilterCause {
    @SerialName("doNotDisturb") DO_NOT_DISTURB, @SerialName("blockList") BLOCK_LIST, @SerialName("unknown") UNKNOWN,
}
