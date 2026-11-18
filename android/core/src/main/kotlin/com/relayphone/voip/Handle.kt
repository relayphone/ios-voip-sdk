package com.relayphone.voip

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Explicit address semantics. Opaque addresses are never reinterpreted. */
@Serializable
public sealed interface Handle {
    @Serializable @SerialName("phone")
    public data class Phone(public val e164: String) : Handle {
        init { require(Regex("\\+[1-9][0-9]{1,14}").matches(e164)) { "Expected E.164 phone number" } }
    }

    @Serializable @SerialName("email")
    public data class Email(public val address: String) : Handle {
        init {
            requireText(address)
            require(address.indexOf('@') in 1 until address.lastIndex && address.count { it == '@' } == 1)
            require(address.none(Char::isWireSpace))
        }
    }

    @Serializable @SerialName("opaque")
    public data class Opaque(public val value: String) : Handle {
        init {
            requireText(value)
            require(value.any { !it.isWireSpace() })
        }
    }
}

/** Calling identity and display label. Lines share participation capacity. */
@Serializable
public data class CallingLine(
    public val accountID: AccountID,
    @SerialName("id") public val lineID: LineID,
    public val label: String,
) {
    init { requireText(label) }
}

/** Display identity and handle of a party. */
@Serializable
public data class Party(public val id: PartyID, public val handle: Handle, public val displayName: String) {
    init { requireText(displayName) }
}
