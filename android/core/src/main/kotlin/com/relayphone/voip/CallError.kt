package com.relayphone.voip

/** Expected operation failure; callers inspect typed cases rather than native error messages. */
public sealed interface CallError {
    public data class UnknownCall(public val callID: CallID) : CallError
    public data class InvalidTransition(public val state: LifecycleKind) : CallError
    public data class Unsupported(public val feature: Feature) : CallError
    public data class PermissionRequired(public val permission: MediaPermission) : CallError
    public data class Refused(public val reason: RefusalReason) : CallError
    public data class AuthorityUnavailable(public val cause: AuthorityFailure) : CallError
    public data class ClaimTimedOut(public val actionID: ActionID) : CallError
    public data class PlacementFailed(public val cause: PlacementFailure) : CallError
    public data class DeadlineExceeded(public val stage: TimedStage) : CallError
    public data class MediaFailed(public val stage: MediaStage, public val cause: MediaFailure) : CallError
    public data class RemoteIdentityConflict(public val remoteID: RemoteCallID) : CallError
    public data class InvalidConfiguration(public val field: ConfigurationField) : CallError
    public data class SystemFailed(public val cause: SystemFailure) : CallError
    public data object BridgeUnavailable : CallError
}

/** Requested behavior that may be unsupported by an adapter. */
public enum class Feature { HOLD, MUTE, TONES, VIDEO, PREVIEW_JOIN, MIXING }
/** Permission required before a media capture operation. */
public enum class MediaPermission { MICROPHONE, CAMERA }
/** Native authorization failure without a service refusal. */
public enum class AuthorityFailure { UNAVAILABLE, CREDENTIAL_UNAVAILABLE, INVALID_RESPONSE, NETWORK }
/** Placement authority failure without an admitted remote call. */
public enum class PlacementFailure { UNAVAILABLE, INVALID_RESPONSE, CANCELLED }
/** Deadline category, independent of observation allowances. */
public enum class TimedStage { CLAIM, RECONCILIATION, SETTLEMENT, PLACEMENT, MEDIA_PREPARATION, CONNECTION, RECONNECTION }
/** Media operation that failed. */
public enum class MediaStage { PREPARATION, ACTIVATION, TRANSPORT, RELEASE }
/** Typed media failure without credential or provider-message payloads. */
public enum class MediaFailure { UNAVAILABLE, INVALID_CREDENTIALS, TRANSPORT, CANCELLED }
/** Configuration field whose policy cannot be applied. */
public enum class ConfigurationField { ANSWER_BUDGET, INVITATION_BUDGET, MEDIA_BUDGET, CONNECTION_BUDGET, RETENTION_BUDGET }

/** Platform-tagged diagnostics; codes are data and never select domain control flow. */
public sealed interface SystemFailure {
    public data class Android(public val operation: SystemOperation, public val nativeCode: Int? = null) : SystemFailure
    public data class IOS(public val operation: SystemOperation, public val nativeCode: Int? = null) : SystemFailure
}
/** Boundary at which a system adapter failed. */
public enum class SystemOperation { ADMISSION, ANSWER, START, HOLD, MUTE, TONES, VIDEO, REMOVAL, RESET }
