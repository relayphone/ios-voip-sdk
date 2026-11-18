package com.relayphone.voip

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Required
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/** One absolute answer allowance; each stage spends it rather than starting a new total. */
@Serializable
public data class AnswerBudget(
    @Required @Serializable(with = MillisecondsSerializer::class) public val total: Duration = 4500.milliseconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val claim: Duration = 2500.milliseconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val reconciliation: Duration = 500.milliseconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val settlementReserve: Duration = 500.milliseconds,
) {
    init {
        listOf(total, claim, reconciliation, settlementReserve).forEach(::requireMilliseconds)
        require(claim <= total - settlementReserve) { "Claim leaves no settlement reserve" }
        require(reconciliation < total - settlementReserve - claim) { "Answer needs time for media preparation" }
    }

    /** Reject startup configuration that would extend the adapter's effective action deadline. */
    public fun validateFor(effectiveDeadline: Duration): Outcome<Unit, CallError> =
        if (effectiveDeadline.isFinite() && effectiveDeadline > Duration.ZERO && total <= effectiveDeadline) {
            Outcome.Success(Unit)
        } else {
            Outcome.Failure(CallError.InvalidConfiguration(ConfigurationField.ANSWER_BUDGET))
        }
}

/** Separate ringing and dialing lifetimes; a service expiry can only shorten them. */
public data class InvitationBudget(
    public val incomingRing: Duration = 45.seconds,
    public val outgoingNoAnswer: Duration = 45.seconds,
) {
    init {
        requirePositiveFinite(incomingRing)
        requirePositiveFinite(outgoingNoAnswer)
    }

    /** Remaining incoming lifetime, zero when the service invitation has already expired. */
    public fun incomingRemaining(serverRemaining: Duration): Duration = bounded(incomingRing, serverRemaining)

    /** Remaining outgoing lifetime, zero when the service dial attempt has already expired. */
    public fun outgoingRemaining(serverRemaining: Duration): Duration = bounded(outgoingNoAnswer, serverRemaining)
}

/** Preparation starts when media work begins; deferred placement alone does not start it. */
public data class MediaPreparationBudget(public val timeout: Duration = 5.seconds) {
    init { requirePositiveFinite(timeout) }

    /** Preparation cannot borrow time from an enclosing action. */
    public fun remaining(actionRemaining: Duration): Duration = bounded(timeout, actionRemaining)
}

/** Independent connection and transport recovery policies, anchored to their own attempts. */
public data class ConnectionBudget(
    public val connection: Duration = 30.seconds,
    public val reconnection: Duration = 15.seconds,
) {
    init {
        requirePositiveFinite(connection)
        requirePositiveFinite(reconnection)
    }
}

/** Retention is limited by both elapsed time and record count. */
@Serializable
public data class RetentionBudget(
    @Required @Serializable(with = MillisecondsSerializer::class) public val lifetime: Duration = 120.seconds,
    @Required public val terminalRecords: Int = 256,
) {
    init {
        requireMilliseconds(lifetime)
        require(terminalRecords > 0) { "Terminal record bound must be positive" }
    }
}

private fun requirePositiveFinite(value: Duration) {
    require(value.isFinite() && value > Duration.ZERO) { "Budget must be positive and finite" }
}

private fun bounded(policy: Duration, remaining: Duration): Duration =
    minOf(policy, remaining.coerceAtLeast(Duration.ZERO))

/** Version-zero deadline policies expressed in native durations. */
@Serializable
public data class Budgets(
    @Required public val answer: AnswerBudget = AnswerBudget(),
    @Required @Serializable(with = MillisecondsSerializer::class) public val placement: Duration = 10.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val incomingRing: Duration = 45.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val outgoingNoAnswer: Duration = 45.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val mediaPreparation: Duration = 5.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val audioActivation: Duration = 10.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val audioRecovery: Duration = 5.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val connection: Duration = 30.seconds,
    @Required @Serializable(with = MillisecondsSerializer::class) public val reconnection: Duration = 15.seconds,
    @SerialName("retention") private val retentionPolicy: RetentionBudget? = null,
) {
    init {
        listOf(placement, incomingRing, outgoingNoAnswer, mediaPreparation, audioActivation,
            audioRecovery, connection, reconnection).forEach(::requireMilliseconds)
    }

    /** Omitted wire policies use the default bounds. */
    @Transient public val retention: RetentionBudget = retentionPolicy ?: RetentionBudget()

    /** Sets the retention policy and includes it when encoding the wire model. */
    public fun withRetention(retention: RetentionBudget): Budgets = copy(retentionPolicy = retention)
}

private fun requireMilliseconds(value: Duration) {
    require(value.inWholeMilliseconds in 1..9_007_199_254_740_991 &&
        value == value.inWholeMilliseconds.milliseconds) { "Expected positive safe integer milliseconds" }
}

internal object MillisecondsSerializer : KSerializer<Duration> {
    override val descriptor = PrimitiveSerialDescriptor("Milliseconds", PrimitiveKind.LONG)
    override fun serialize(encoder: Encoder, value: Duration) {
        requireMilliseconds(value)
        encoder.encodeLong(value.inWholeMilliseconds)
    }
    override fun deserialize(decoder: Decoder): Duration = decoder.decodeLong().milliseconds.also(::requireMilliseconds)
}
