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
    require(value.isNotBlank()) { "Identity must not be blank" }
    require(value.none(Char::isISOControl)) { "Identity must not contain control characters" }
}
