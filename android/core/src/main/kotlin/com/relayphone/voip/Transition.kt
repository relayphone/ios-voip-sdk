package com.relayphone.voip

import java.util.Collections
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

/** An application event that may arrive before its canonical call or remote alias is known. */
@Serializable
public sealed interface RemoteEvent {
    public val eventID: EventID
    public val target: EndTarget

    @Serializable @SerialName("connected")
    public data class Connected(override val eventID: EventID, override val target: EndTarget) : RemoteEvent

    @Serializable @SerialName("ended")
    public data class Ended(
        override val eventID: EventID, override val target: EndTarget, public val reason: EndReason,
    ) : RemoteEvent {
        init { requireRemoteEnd(reason) }
    }

    @Serializable @SerialName("partiesChanged")
    public data class PartiesChanged(
        override val eventID: EventID, override val target: EndTarget, public val parties: List<Party>,
    ) : RemoteEvent {
        init { require(parties.isNotEmpty()) }
    }

    @Serializable @SerialName("videoRequested")
    public data class VideoRequested(
        override val eventID: EventID, override val target: EndTarget, public val enabled: Boolean,
    ) : RemoteEvent
}

private fun requireRemoteEnd(reason: EndReason) {
    require(reason != EndReason.LocalDeclined && reason != EndReason.LocalEnded && reason !is EndReason.Filtered)
}

/** The reducer's disposition of a delivered application event. */
@Serializable
public enum class ReceiveDisposition {
    @SerialName("applied") APPLIED,
    @SerialName("buffered") BUFFERED,
    @SerialName("duplicate") DUPLICATE,
}

/** Result of reporting an invitation. A retry returns the first admission decision. */
public sealed interface IncomingResult {
    public val callID: CallID
    public sealed interface Decision : IncomingResult
    public data class Admitted(override val callID: CallID) : Decision
    public data class Refused(override val callID: CallID, public val reason: IncomingRefusal) : Decision
    public data class Duplicate(public val original: Decision) : IncomingResult {
        override val callID: CallID get() = original.callID
    }
}

/** A typed reason why an invitation did not reach ringing. */
public sealed interface IncomingRefusal {
    public data object Expired : IncomingRefusal
    public data object EventAlreadyUsed : IncomingRefusal
    public data class CallAlreadyExists(public val state: LifecycleKind) : IncomingRefusal
    public data class Ended(public val reason: EndReason) : IncomingRefusal
    public data class Previewed(public val reason: PreviewReason) : IncomingRefusal
    public data class SystemFailed(public val failure: SystemFailure) : IncomingRefusal
}

/** The placement authority's settlement for one attempt. */
public sealed interface PlacementResult {
    public data class Placed(public val remoteID: RemoteCallID? = null) : PlacementResult
    public data class Refused(public val reason: RefusalReason) : PlacementResult
    public data class Failed(public val cause: PlacementFailure) : PlacementResult
}

/** Immediate command decisions, evaluated on the same state as the transition. */
public sealed interface CommandReceipt {
    public data class Received(public val outcome: Outcome<ReceiveDisposition, CallError>) : CommandReceipt
    public data class Bound(public val outcome: Outcome<Unit, CallError>) : CommandReceipt
    public data class Answered(public val outcome: Outcome<Unit, CallError>) : CommandReceipt
    public sealed interface Incoming : CommandReceipt {
        /** Await a native admission decision for this attempt. */
        public data class Pending(public val attempt: Attempt, public val duplicate: Boolean) : Incoming
        public data class Resolved(public val result: IncomingResult) : Incoming
    }
    /** Whether a settlement matched a live placement attempt within its deadline. */
    public data class Placement(public val accepted: Boolean) : CommandReceipt
}

/** Inputs carry port confirmations and explicit authority. A request alone changes no control state. */
public sealed interface Input {
    /** A new invitation with an optional UTC expiry supplied by the service. */
    public data class Incoming(
        public val callID: CallID, public val eventID: EventID, public val line: CallingLine,
        public val party: Party, public val expiresAt: Instant? = null,
    ) : Input
    public data class Admitted(public val attempt: Attempt) : Input
    /** The incoming platform setup resolved without opening a session. */
    public data class AdmissionFailed(public val attempt: Attempt, public val failure: SystemFailure) : Input {
        init { require(failure.operation == SystemOperation.ADMISSION) }
    }
    /** The platform opened the outgoing session for this attempt. */
    public data class StartAdmitted(public val attempt: Attempt) : Input
    /** The outgoing platform setup resolved without opening a session. */
    public data class StartFailed(public val attempt: Attempt, public val failure: SystemFailure) : Input {
        init { require(failure.operation == SystemOperation.START) }
    }
    public data class Request(
        public val action: Action, public val id: ActionID, public val supported: Boolean = false,
        public val effectiveDeadline: Duration? = null,
        public val origin: ActionOrigin = ActionOrigin.APP,
    ) : Input
    /** Starts an outgoing call with the supplied initial participants and video intent. */
    public data class Start(
        public val callID: CallID, public val line: CallingLine, public val parties: List<Party>,
        public val video: Boolean, public val id: ActionID, public val effectiveDeadline: Duration? = null,
        public val origin: ActionOrigin = ActionOrigin.APP,
    ) : Input {
        init { require(parties.isNotEmpty()) }
    }
    public data class Placed(
        public val attempt: Attempt, public val result: PlacementResult = PlacementResult.Placed(),
    ) : Input
    /** Reports a preview join failing after its placement has already been accepted. */
    public data class JoinPlacementLost(public val attempt: Attempt, public val error: CallError.PlacementFailed) : Input
    public data class AuthorityAllowed(public val attempt: Attempt, public val permit: AttemptID) : Input
    public data class AnswerRefused(public val attempt: Attempt, public val reason: RefusalReason) : Input
    /** Telecom settled the same Answer after the reducer authorized it. */
    public data class AnswerConfirmed(public val callID: CallID, public val actionID: ActionID) : Input
    public data class ReconciliationUnknown(public val attempt: Attempt) : Input
    public data class ProvideMedia(public val id: CallID) : Input
    public data class MediaPrepared(public val attempt: Attempt) : Input
    public data class MediaFailed(public val attempt: Attempt, public val error: CallError.MediaFailed) : Input
    public data class Connected(public val callID: CallID, public val eventID: EventID, public val source: ConnectionAuthority) : Input
    public data class BindRemote(public val callID: CallID, public val remoteID: RemoteCallID) : Input
    public data class Receive(public val event: RemoteEvent) : Input
    public data class RemoteEnd(public val target: EndTarget, public val eventID: EventID, public val reason: EndReason) : Input {
        init { requireRemoteEnd(reason) }
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
    /** Rechecks terminal retention after runtime-owned adapter work has finished. */
    public data object AdapterIdle : Input
}

/** Ordered work for the engine. Effect deadlines use the reducer's monotonic time domain. */
public sealed interface Effect {
    public data class ReportIncoming(public val attempt: Attempt) : Effect
    public data class RequestPlacement(
        public val attempt: Attempt, public val actionID: ActionID, public val deadline: Instant,
    ) : Effect
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
    completedTerminalCalls: Set<CallID>,
) {
    public constructor(configuration: Configuration) :
        this(configuration, emptyMap(), emptyMap(), emptyMap(), emptyMap(), 0, emptySet())
    public val calls: Map<CallID, Call> get() = records.mapValues { it.value.call }
    /** Retained ended calls whose adapter work has completed. */
    public val completedTerminalCalls: Set<CallID> = Collections.unmodifiableSet(completedTerminalCalls)
    /** Retained terminal call IDs ordered by first terminal intent. */
    public val terminalCallOrder: List<CallID>
        get() = records.values.filter { it.terminalAt != null }.sortedWith(terminalOrder).map { it.call.id }
    public val participating: Set<CallID> get() = records.filterValues(Record::participating).keys
    public val systemRemoved: Set<CallID> get() = records.filterValues { it.removalEvidence == RemovalEvidence.REMOVED }.keys
    /** Calls whose platform setup failed before there was a session to remove. */
    public val systemRemovalNotApplicable: Set<CallID>
        get() = records.filterValues { it.removalEvidence == RemovalEvidence.NOT_APPLICABLE }.keys
}

public data class Transition(
    public val state: State, public val effects: List<Effect>, public val receipt: CommandReceipt? = null,
    /** Newly completed calls, including any that expired from retention in this transition. */
    public val terminalCompletions: List<CallID> = emptyList(),
    /** Final decision for the native operation started by an incoming command. */
    public val admission: AdmissionCompletion? = null,
    /** Platform removal result for a still-owned removal attempt. */
    public val removal: RemovalCompletion? = null,
    /** The call action confirmed by this transition, if any. */
    public val actionPerformed: ActionReceipt? = null,
)

public data class AdmissionCompletion(public val attempt: Attempt, public val decision: IncomingResult.Decision)
public data class RemovalCompletion(public val attempt: Attempt, public val removed: Boolean)

internal data class Pending(
    val attempt: Attempt, val receipt: ActionReceipt, val deadline: Instant,
) {
    val id: ActionID get() = receipt.actionID
}
internal data class Control(val receipt: ActionReceipt, val attempt: Attempt) {
    val action: Action get() = receipt.action
    val id: ActionID get() = receipt.actionID
}
internal data class SeenEvent(
    val at: Instant, val order: Long, val pending: RemoteEvent? = null,
    val incoming: IncomingResult.Decision? = null,
) {
    val end: RemoteEvent.Ended? get() = pending as? RemoteEvent.Ended
}
internal data class PermitKey(val callID: CallID, val id: AttemptID)
internal data class PermitRelease(val attempt: Attempt, val permit: AttemptID)
internal data class Armed(val attempt: Attempt, val deadline: Instant)
internal enum class RemovalEvidence { UNCONFIRMED, REMOVED, NOT_APPLICABLE }
internal enum class OutgoingProgress { CONNECTED, PROVIDE_MEDIA }
internal val terminalOrder: Comparator<Record> = compareBy({ it.terminalAt }, { it.cleanup?.generation })

internal data class Record(
    val call: Call,
    val admission: Attempt? = null,
    val invitationEvent: EventID? = null,
    val invitationDeadline: Instant? = null,
    val retainedEnd: SeenEvent? = null,
    val placement: Pending? = null,
    val nativeStart: Effect.NativeStart? = null,
    val startingAction: ActionReceipt? = null,
    val outgoingProgress: List<OutgoingProgress> = emptyList(),
    val joinAttempt: Attempt? = null,
    val previousPreview: PreviewReason? = null,
    val answer: Pending? = null,
    val confirmingAnswer: Pending? = null,
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
    val removalEvidence: RemovalEvidence = RemovalEvidence.UNCONFIRMED,
    val timers: Map<TimerKind, Armed> = emptyMap(),
) {
    val participating: Boolean get() =
        answer != null || !call.held && call.lifecycle.kind in setOf(
            LifecycleKind.PLACING, LifecycleKind.DIALING, LifecycleKind.CONNECTING,
            LifecycleKind.CONNECTED, LifecycleKind.RECONNECTING,
        )
}
