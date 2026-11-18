package com.relayphone.voip

import kotlin.time.Duration
import kotlin.time.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Policies selected before calls are admitted. */
@Serializable
public data class Configuration(
    public val budgets: Budgets,
    public val outgoingMedia: OutgoingMedia,
    public val connectionAuthority: ConnectionAuthority,
    public val maximumParticipatingCalls: Int,
    public val previewAnsweredElsewhere: Boolean,
) {
    init { require(maximumParticipatingCalls == 1) }
}

@Serializable public enum class OutgoingMedia {
    @SerialName("whenProvided") WHEN_PROVIDED, @SerialName("duringPlacement") DURING_PLACEMENT,
}
@Serializable public enum class ConnectionAuthority {
    @SerialName("application") APPLICATION, @SerialName("nativeMedia") NATIVE_MEDIA,
}

/** Correlation carried by an asynchronous operation or an engine timer. */
public data class Attempt(public val callID: CallID, public val generation: Long)
public enum class TimerKind { PLACEMENT, NO_ANSWER, CLAIM, RECONCILIATION, ANSWER, PREPARATION, CONNECTION, RECONNECTION }

/** Clock samples for one input. Only UTC is suitable for published timestamps. */
public data class Now(public val monotonic: Instant, public val utc: Instant)

/** End receipts are produced once and reused for duplicate End requests. */
@Serializable
public sealed interface EndResult {
    @Serializable @SerialName("ended") public data class Ended(public val receipt: EndReceipt) : EndResult
    @Serializable @SerialName("alreadyEnded") public data class AlreadyEnded(public val reason: EndReason) : EndResult
}

@Serializable
public data class EndReceipt(public val callID: CallID, public val actionID: ActionID, public val reason: EndReason) {
    init { require(reason == EndReason.LocalDeclined || reason == EndReason.LocalEnded) }
}

@Serializable
public sealed interface EndTarget {
    @Serializable @SerialName("call") public data class Canonical(@SerialName("id") public val id: CallID) : EndTarget
    @Serializable @SerialName("remote") public data class Alias(@SerialName("id") public val id: RemoteCallID) : EndTarget
}

/** Inputs carry port confirmations and explicit authority. A request alone changes no control state. */
public sealed interface Input {
    /** A new invitation with an optional UTC expiry supplied by the service. */
    public data class Incoming(
        public val callID: CallID, public val eventID: EventID, public val line: CallingLine,
        public val party: Party, public val expiresAt: Instant? = null,
    ) : Input
    public data class Admitted(public val attempt: Attempt) : Input
    public data class Request(
        public val action: Action, public val id: ActionID, public val supported: Boolean = false,
        public val effectiveDeadline: Duration? = null,
    ) : Input
    public data class Placed(public val attempt: Attempt, public val error: CallError.PlacementFailed? = null) : Input
    public data class AuthorityAllowed(public val attempt: Attempt, public val permit: AttemptID) : Input
    public data class AnswerRefused(public val attempt: Attempt, public val reason: RefusalReason) : Input
    public data class ReconciliationUnknown(public val attempt: Attempt) : Input
    public data class ProvideMedia(public val id: CallID) : Input
    public data class MediaPrepared(public val attempt: Attempt) : Input
    public data class MediaFailed(public val attempt: Attempt, public val error: CallError.MediaFailed) : Input
    public data class Connected(public val callID: CallID, public val eventID: EventID, public val source: ConnectionAuthority) : Input
    public data class BindRemote(public val callID: CallID, public val remoteID: RemoteCallID) : Input
    public data class RemoteEnd(public val target: EndTarget, public val eventID: EventID, public val reason: EndReason) : Input {
        init { require(reason !in listOf(EndReason.LocalDeclined, EndReason.LocalEnded) && reason !is EndReason.Filtered) }
    }
    public data class Applied(public val attempt: Attempt) : Input
    public data class ApplyFailed(public val attempt: Attempt, public val error: CallError) : Input
    public data class TimerExpired(public val attempt: Attempt, public val kind: TimerKind) : Input
    public data class TransportLost(public val attempt: Attempt) : Input
    public data class TransportRecovered(public val attempt: Attempt) : Input
    public data class MediaReleased(public val attempt: Attempt) : Input
    public data class SystemRemoved(public val attempt: Attempt) : Input
    /** The adapter finished its removal attempt without confirming removal. */
    public data class SystemRemovalFailed(public val attempt: Attempt) : Input
    /** The authority finished releasing a permit previously owned by the call. */
    public data class PermitReleased(public val attempt: Attempt, public val permit: AttemptID) : Input
    public data class FrameworkReset(public val failure: SystemFailure) : Input
}

/** Ordered work for the engine. Effect deadlines use the reducer's monotonic time domain. */
public sealed interface Effect {
    public data class ReportIncoming(public val attempt: Attempt) : Effect
    public data class RequestPlacement(public val attempt: Attempt, public val actionID: ActionID) : Effect
    public data class NativeStart(public val attempt: Attempt, public val actionID: ActionID) : Effect
    public data class RequestClaim(public val attempt: Attempt, public val actionID: ActionID) : Effect
    public data class ClaimTimedOut(public val attempt: Attempt, public val error: CallError.ClaimTimedOut) : Effect
    public data class Reconcile(public val attempt: Attempt, public val actionID: ActionID) : Effect
    public data class ReleasePermit(public val permit: AttemptID, public val attempt: Attempt) : Effect
    public data class PrepareMedia(public val attempt: Attempt) : Effect
    public data class CloseMedia(public val attempt: Attempt, public val mediaAttempt: Attempt?) : Effect
    public data class RequestRemoval(public val attempt: Attempt, public val reason: EndReason) : Effect
    public data class SetActive(public val attempt: Attempt) : Effect
    public data class Apply(public val attempt: Attempt, public val actionID: ActionID, public val action: Action) : Effect
    public data class SendTones(public val attempt: Attempt, public val action: Action.Tones) : Effect
    public data class TonesPerformed(public val callID: CallID, public val actionID: ActionID, public val digits: DTMFSequence) : Effect
    public data class SettleAction(public val callID: CallID, public val actionID: ActionID, public val deadline: Instant? = null) : Effect
    public data class RejectAction(public val callID: CallID, public val actionID: ActionID?, public val error: CallError) : Effect
    public data class CompleteEnd(public val callID: CallID, public val actionID: ActionID, public val result: EndResult) : Effect
    public data class Publish(public val call: Call) : Effect
    public data class ArmTimer(public val attempt: Attempt, public val kind: TimerKind, public val deadline: Instant) : Effect
    public data class CancelTimer(public val attempt: Attempt, public val kind: TimerKind) : Effect
}

/** Reducer state. Only confirmed call projections and participating calls are exposed. */
public class State internal constructor(
    public val configuration: Configuration,
    internal val records: Map<CallID, Record>,
    internal val events: Map<EventID, SeenEvent>,
    internal val releasedPermits: Map<PermitKey, Instant>,
    internal val actionIDs: Map<ActionID, Instant>,
    internal val generation: Long,
) {
    public constructor(configuration: Configuration) : this(configuration, emptyMap(), emptyMap(), emptyMap(), emptyMap(), 0)
    public val calls: Map<CallID, Call> get() = records.mapValues { it.value.call }
    public val participating: Set<CallID> get() = records.filterValues(Record::participating).keys
    public val systemRemoved: Set<CallID> get() = records.filterValues(Record::systemRemoved).keys
}

public data class Transition(public val state: State, public val effects: List<Effect>)

internal data class Pending(val attempt: Attempt, val id: ActionID, val deadline: Instant)
internal data class Control(val action: Action, val attempt: Attempt, val id: ActionID)
internal data class SeenEvent(val at: Instant, val order: Long, val end: Input.RemoteEnd? = null)
internal data class PermitKey(val callID: CallID, val id: AttemptID)
internal data class PermitRelease(val attempt: Attempt, val permit: AttemptID)
internal data class Armed(val attempt: Attempt, val deadline: Instant)
internal data class Record(
    val call: Call,
    val admission: Attempt? = null,
    val invitationDeadline: Instant? = null,
    val retainedEnd: SeenEvent? = null,
    val placement: Pending? = null,
    val joinAttempt: Attempt? = null,
    val previousPreview: PreviewReason? = null,
    val answer: Pending? = null,
    val reconciliation: Attempt? = null,
    val permit: AttemptID? = null,
    val permitAttempt: Attempt? = null,
    val mediaAttempt: Attempt? = null,
    val bufferedConnection: Boolean = false,
    val connectedAt: Instant? = null,
    val controls: List<Control> = emptyList(),
    val cleanup: Attempt? = null,
    val mediaReleases: Set<Attempt> = emptySet(),
    val removal: Attempt? = null,
    val removals: Set<Attempt> = emptySet(),
    val releasingPermit: PermitRelease? = null,
    val terminalAt: Instant? = null,
    val localEnd: ActionID? = null,
    val systemRemoved: Boolean = false,
    val timers: Map<TimerKind, Armed> = emptyMap(),
) {
    val participating: Boolean get() =
        answer != null || !call.held && call.lifecycle.kind in setOf(
            LifecycleKind.PLACING, LifecycleKind.DIALING, LifecycleKind.CONNECTING,
            LifecycleKind.CONNECTED, LifecycleKind.RECONNECTING,
        )
}
