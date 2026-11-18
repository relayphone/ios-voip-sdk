package com.relayphone.voip

import kotlinx.serialization.Serializable

/** Canonical application identity, preserved across devices and remote alias binding. */
@Serializable
@JvmInline
public value class CallID(public val value: String) {
    init { requireIdentity(value) }
}

/** Optional service alias; it never replaces a [CallID]. */
@Serializable
@JvmInline
public value class RemoteCallID(public val value: String) {
    init { requireIdentity(value) }
}

/** Account owning a calling line. */
@Serializable
@JvmInline
public value class AccountID(public val value: String) {
    init { requireIdentity(value) }
}

/** Application identity of a calling line. */
@Serializable
@JvmInline
public value class LineID(public val value: String) {
    init { requireIdentity(value) }
}

/** Server event identity used to distinguish redelivery. */
@Serializable
@JvmInline
public value class EventID(public val value: String) {
    init { requireIdentity(value) }
}

/** Identity of one user intent, shared by callback echoes. */
@Serializable
@JvmInline
public value class ActionID(public val value: String) {
    init { requireIdentity(value) }
}

/** Identity of one asynchronous attempt, distinct from the user intent. */
@Serializable
@JvmInline
public value class AttemptID(public val value: String) {
    init { requireIdentity(value) }
}

private fun requireIdentity(value: String) {
    requireText(value)
    require(!value.first().isWireSpace() && !value.last().isWireSpace()) { "Identity must not have edge whitespace" }
    require(value.none(Char::isISOControl)) { "Identity must not contain control characters" }
}

/** App identity of a party, independent of its handle. */
@Serializable
@JvmInline
public value class PartyID(public val value: String) {
    init { requireIdentity(value) }
}

internal fun requireText(value: String) {
    require(value.codePointCount(0, value.length) in 1..256) { "Expected 1–256 code points" }
}

internal fun Char.isWireSpace(): Boolean =
    this in '\u0009'..'\u000D' || this in '\u2000'..'\u200A' ||
        this in " \u00A0\u1680\u2028\u2029\u202F\u205F\u3000\uFEFF"
