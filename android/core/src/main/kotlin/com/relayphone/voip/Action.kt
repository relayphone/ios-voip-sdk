package com.relayphone.voip

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** A call-scoped request. Remote facts enter the reducer separately. */
@Serializable
public sealed interface Action {
    public val callID: CallID

    @Serializable @SerialName("start")
    public data class Start(override val callID: CallID, public val line: CallingLine, public val party: Party) : Action
    @Serializable @SerialName("answer")
    public data class Answer(override val callID: CallID) : Action
    @Serializable @SerialName("join")
    public data class Join(override val callID: CallID) : Action
    @Serializable @SerialName("end")
    public data class End(override val callID: CallID) : Action
    @Serializable @SerialName("hold")
    public data class Hold(override val callID: CallID, public val held: Boolean) : Action
    @Serializable @SerialName("mute")
    public data class Mute(override val callID: CallID, public val muted: Boolean) : Action
    @Serializable @SerialName("video")
    public data class Video(override val callID: CallID, public val enabled: Boolean) : Action
    @Serializable @SerialName("tones")
    public data class Tones(
        override val callID: CallID,
        @Serializable(with = ToneSerializer::class) public val digits: DTMFSequence,
    ) : Action
}

/** Nonempty immutable DTMF sequence of the twelve keypad digits. */
@JvmInline
public value class DTMFSequence(public val value: String) {
    init {
        require(value.isNotEmpty() && value.all { it in "0123456789*#" }) { "Invalid DTMF sequence" }
    }
}

/** Explicit authority refusal, distinct from unavailable service and timeout. */
@Serializable
public sealed interface RefusalReason {
    @Serializable @SerialName("answeredElsewhere") public data object AnsweredElsewhere : RefusalReason
    @Serializable @SerialName("declinedElsewhere") public data object DeclinedElsewhere : RefusalReason
    @Serializable @SerialName("notAllowed") public data object NotAllowed : RefusalReason
}
