package com.relayphone.voip

/** Explicit address semantics; opaque addresses are never interpreted as phone numbers. */
public sealed interface Handle {
    /** International phone number with a leading plus and at most fifteen digits. */
    public data class Phone(public val e164: String) : Handle {
        init { require(Regex("\\+[1-9][0-9]{1,14}").matches(e164)) { "Expected E.164 phone number" } }
    }

    /** Email address preserved without case folding or normalization. */
    public data class Email(public val address: String) : Handle {
        init {
            require(address.count { it == '@' } == 1) { "Expected email address" }
            require(address.substringBefore('@').isNotEmpty() && address.substringAfter('@').isNotEmpty())
            require(address.none { it.isWhitespace() || it.isISOControl() })
        }
    }

    /** Uninterpreted app address, including SIP URIs and short codes. */
    public data class Opaque(public val value: String) : Handle {
        init {
            require(value.isNotBlank()) { "Opaque handle must not be blank" }
            require(value.none(Char::isISOControl))
        }
    }
}

/** Calling identity and display label; lines share the runtime's admission capacity. */
public data class CallingLine(
    public val accountID: AccountID,
    public val lineID: LineID,
    public val label: String,
)
