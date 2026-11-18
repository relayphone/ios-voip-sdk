package com.relayphone.voip.testing

import com.relayphone.voip.*
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable
internal data class Journey(val version: Int, val id: String, val configuration: Configuration, val steps: List<Step>) {
    init {
        require(version == 0)
        require(steps.size >= 2 && steps.any { it is Step.Expect })
    }
}

@Serializable
internal sealed interface Step {
    @Serializable @SerialName("input") data class Inject(val input: Control) : Step
    @Serializable @SerialName("expect") data class Expect(val expectation: Expectation) : Step
}

@Serializable
internal sealed interface Control {
    @Serializable @SerialName("process") data class Process(val running: Boolean, val javascriptAttached: Boolean) : Control
    @Serializable @SerialName("incoming") data class Incoming(
        val callID: CallID, val eventID: EventID, val line: CallingLine,
        val party: Party, val deferAdmission: Boolean = false,
    ) : Control
    @Serializable @SerialName("authority") data class Authority(
        val callID: CallID, val claim: Decision, val reconciliation: Decision,
    ) : Control {
        init { require(claim != Decision.Unknown && reconciliation != Decision.Timeout) }
    }
    @Serializable @SerialName("action") data class Request(
        val origin: Origin, val action: Action, val deferConfirmation: Boolean = false,
    ) : Control {
        init { require(!deferConfirmation || action is Action.Hold) }
    }
    @Serializable @SerialName("placed") data class Placed(val callID: CallID) : Control
    @Serializable @SerialName("admitted") data class Admitted(val callID: CallID) : Control
    @Serializable @SerialName("admissionFailed") data class AdmissionFailed(val callID: CallID, val failure: SystemFailure) : Control {
        init { require(failure.operation == SystemOperation.ADMISSION) }
    }
    @Serializable @SerialName("latePermit") data class LatePermit(val callID: CallID) : Control
    @Serializable @SerialName("holdApplied") data class HoldApplied(val callID: CallID) : Control
    @Serializable @SerialName("provideMedia") data class ProvideMedia(val callID: CallID) : Control
    @Serializable @SerialName("bindRemote") data class BindRemote(val callID: CallID, val remoteID: RemoteCallID) : Control
    @Serializable @SerialName("connected") data class Connected(val callID: CallID, val eventID: EventID) : Control
    @Serializable @SerialName("remoteEnd") data class RemoteEnd(
        val target: EndTarget, val eventID: EventID, val reason: EndReason,
    ) : Control
    @Serializable @SerialName("advance") data class Advance(val milliseconds: Long) : Control {
        init { require(milliseconds in 1..9_007_199_254_740_991) }
    }
}

@Serializable internal enum class Origin { @SerialName("app") APP, @SerialName("system") SYSTEM }
@Serializable internal sealed interface Decision {
    @Serializable @SerialName("allow") data object Allow : Decision
    @Serializable @SerialName("refuse") data class Refuse(val reason: RefusalReason) : Decision
    @Serializable @SerialName("timeout") data object Timeout : Decision
    @Serializable @SerialName("unknown") data object Unknown : Decision
}

@Serializable internal sealed interface Expectation {
    @Serializable @SerialName("call") data class Snapshot(
        val callID: CallID, val lifecycle: JsonObject, val lineID: LineID? = null,
        val remoteID: RemoteCallID? = null, val held: Boolean? = null, val muted: Boolean? = null,
    ) : Expectation
    @Serializable @SerialName("count") data class Count(val callID: CallID, val metric: Metric, val value: Int) : Expectation
    @Serializable @SerialName("participating") data class Participating(val callIDs: List<CallID>) : Expectation
    @Serializable @SerialName("systemEnd") data class SystemEnd(val callID: CallID, val cause: SystemEndCause) : Expectation
    @Serializable @SerialName("error") data class Error(
        val callID: CallID, val error: String, val reason: RefusalReason? = null,
    ) : Expectation
    @Serializable @SerialName("endResult") data class End(val callID: CallID, val result: EndResult) : Expectation
}

@Serializable internal enum class Metric {
    @SerialName("claims") CLAIMS, @SerialName("reconciliations") RECONCILIATIONS,
    @SerialName("settlements") SETTLEMENTS, @SerialName("publications") PUBLICATIONS,
    @SerialName("activations") ACTIVATIONS, @SerialName("reports") REPORTS, @SerialName("placements") PLACEMENTS,
    @SerialName("performedEnds") PERFORMED_ENDS, @SerialName("releases") RELEASES,
    @SerialName("claimTimeouts") CLAIM_TIMEOUTS, @SerialName("permitReleases") PERMIT_RELEASES,
    @SerialName("ringingPublications") RINGING_PUBLICATIONS, @SerialName("holdRequests") HOLD_REQUESTS,
}
@Serializable internal enum class SystemEndCause {
    @SerialName("local") LOCAL, @SerialName("remote") REMOTE, @SerialName("missed") MISSED, @SerialName("rejected") REJECTED,
}
