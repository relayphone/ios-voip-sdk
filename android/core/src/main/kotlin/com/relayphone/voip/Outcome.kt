package com.relayphone.voip

/** Exhaustive result for expected failures, without exception-based control flow. */
public sealed interface Outcome<out Value, out Error> {
    /** Successful operation carrying its value. */
    public data class Success<out Value>(public val value: Value) : Outcome<Value, Nothing>

    /** Failed operation carrying a typed error. */
    public data class Failure<out Error>(public val error: Error) : Outcome<Nothing, Error>
}
