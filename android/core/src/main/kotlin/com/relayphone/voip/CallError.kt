package com.relayphone.voip

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Expected operation failure with a typed cause and no native error text. */
@Serializable
public sealed interface CallError {
    @Serializable @SerialName("unknownCall") public data class UnknownCall(public val callID: CallID) : CallError
    @Serializable @SerialName("invalidTransition") public data class InvalidTransition(public val state: LifecycleKind) : CallError
    @Serializable @SerialName("unsupported") public data class Unsupported(public val feature: Feature) : CallError
    @Serializable @SerialName("permissionRequired") public data class PermissionRequired(public val permission: MediaPermission) : CallError
    @Serializable @SerialName("refused") public data class Refused(public val reason: RefusalReason) : CallError
    @Serializable @SerialName("authorityUnavailable") public data class AuthorityUnavailable(public val cause: AuthorityFailure) : CallError
    @Serializable @SerialName("claimTimedOut") public data class ClaimTimedOut(public val actionID: ActionID) : CallError
    @Serializable @SerialName("placementFailed") public data class PlacementFailed(public val cause: PlacementFailure) : CallError
    @Serializable @SerialName("deadlineExceeded") public data class DeadlineExceeded(public val stage: TimedStage) : CallError
    @Serializable @SerialName("mediaFailed") public data class MediaFailed(public val stage: MediaStage, public val cause: MediaFailure) : CallError
    @Serializable @SerialName("remoteIdentityConflict") public data class RemoteIdentityConflict(public val remoteID: RemoteCallID) : CallError
    @Serializable @SerialName("invalidConfiguration") public data class InvalidConfiguration(public val field: ConfigurationField) : CallError
    @Serializable @SerialName("systemFailed") public data class SystemFailed(public val cause: SystemFailure) : CallError
    @Serializable @SerialName("bridgeUnavailable") public data object BridgeUnavailable : CallError
}

/** Requested behavior that an adapter may not support. */
@Serializable
public enum class Feature {
    @SerialName("hold") HOLD, @SerialName("video") VIDEO, @SerialName("tones") TONES,
    @SerialName("preview") PREVIEW, @SerialName("merge") MERGE,
}
/** Permission required for capture. */
@Serializable
public enum class MediaPermission { @SerialName("microphone") MICROPHONE, @SerialName("camera") CAMERA }
/** Native authority failure before a decision. */
@Serializable
public enum class AuthorityFailure {
    @SerialName("credentialsUnavailable") CREDENTIALS_UNAVAILABLE,
    @SerialName("network") NETWORK, @SerialName("invalidResponse") INVALID_RESPONSE,
}
/** Placement failure before native dialing. */
@Serializable
public enum class PlacementFailure { @SerialName("cancelled") CANCELLED, @SerialName("handlerFailed") HANDLER_FAILED }
/** Deadline category independent of observer timing. */
@Serializable
public enum class TimedStage {
    @SerialName("placement") PLACEMENT, @SerialName("claim") CLAIM, @SerialName("reconciliation") RECONCILIATION,
    @SerialName("mediaPreparation") MEDIA_PREPARATION, @SerialName("audioActivation") AUDIO_ACTIVATION,
    @SerialName("connection") CONNECTION, @SerialName("reconnection") RECONNECTION,
    @SerialName("systemAction") SYSTEM_ACTION, @SerialName("noAnswer") NO_ANSWER,
}
/** Media operation that failed. */
@Serializable
public enum class MediaStage { @SerialName("prepare") PREPARE, @SerialName("activate") ACTIVATE, @SerialName("release") RELEASE }
/** Machine-readable media failure. */
@Serializable
public enum class MediaFailure { @SerialName("transport") TRANSPORT, @SerialName("permission") PERMISSION, @SerialName("timeout") TIMEOUT }
/** Configuration field whose policy cannot be applied. */
@Serializable
public enum class ConfigurationField {
    @SerialName("answer") ANSWER_BUDGET, @SerialName("placement") PLACEMENT,
    @SerialName("incomingRing") INCOMING_RING, @SerialName("outgoingNoAnswer") OUTGOING_NO_ANSWER,
    @SerialName("mediaPreparation") MEDIA_PREPARATION, @SerialName("audioActivation") AUDIO_ACTIVATION,
    @SerialName("audioRecovery") AUDIO_RECOVERY, @SerialName("connection") CONNECTION, @SerialName("reconnection") RECONNECTION,
}

/** Platform diagnostic with an optional original numeric code. */
@Serializable
public data class SystemFailure(
    public val platform: Platform,
    @SerialName("kind") public val operation: SystemOperation,
    @SerialName("code") public val nativeCode: Int? = null,
)
@Serializable
public enum class Platform { @SerialName("android") ANDROID, @SerialName("ios") IOS }
@Serializable
public enum class SystemOperation {
    @SerialName("admission") ADMISSION, @SerialName("action") ACTION, @SerialName("removal") REMOVAL,
    @SerialName("reset") RESET, @SerialName("audio") AUDIO,
}
