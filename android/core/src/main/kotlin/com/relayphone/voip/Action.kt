package com.relayphone.voip

/** User requests; remote connection and termination are facts, not actions. */
public sealed interface Action {
    public data object Answer : Action
    public data object Join : Action
    public data object End : Action
    public data class Hold(public val held: Boolean) : Action
    public data class Mute(public val muted: Boolean) : Action
    public data class Video(public val enabled: Boolean) : Action
    public data class Tones(public val digits: DTMFSequence) : Action
}

/** Nonempty immutable DTMF sequence; no pause/wait or address parsing. */
@JvmInline
public value class DTMFSequence(public val value: String) {
    init {
        require(value.isNotEmpty() && value.all { it in "0123456789*#ABCD" }) { "Invalid DTMF sequence" }
    }
}

/** Explicit authority refusal, distinct from unavailable service and timeout. */
public sealed interface RefusalReason {
    public data object AnsweredElsewhere : RefusalReason
    public data object DeclinedElsewhere : RefusalReason
    public data object NotAllowed : RefusalReason
}
