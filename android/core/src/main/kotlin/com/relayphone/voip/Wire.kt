package com.relayphone.voip

import java.time.format.DateTimeFormatterBuilder
import kotlin.time.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A v0 call snapshot. Media and controls progress independently of lifecycle. */
@Serializable
public data class Call(
    public val id: CallID,
    public val line: CallingLine,
    public val direction: Direction,
    public val parties: List<Party>,
    public val lifecycle: Lifecycle,
    public val held: Boolean,
    public val muted: Boolean,
    public val video: Boolean,
    public val media: Media,
    public val remoteID: RemoteCallID? = null,
) {
    init {
        require(parties.isNotEmpty())
        require(direction != Direction.OUTGOING || lifecycle !is Lifecycle.Previewing &&
            lifecycle != Lifecycle.Reporting && lifecycle != Lifecycle.Ringing)
        require(direction != Direction.INCOMING || lifecycle != Lifecycle.Dialing)
    }
}

@Serializable public enum class Direction { @SerialName("incoming") INCOMING, @SerialName("outgoing") OUTGOING }
@Serializable public enum class Owner { @SerialName("native") NATIVE, @SerialName("application") APPLICATION }
@Serializable public enum class Preparation {
    @SerialName("unprovided") UNPROVIDED, @SerialName("preparing") PREPARING,
    @SerialName("prepared") PREPARED, @SerialName("released") RELEASED,
}
@Serializable public enum class Audio { @SerialName("inactive") INACTIVE, @SerialName("active") ACTIVE }
@Serializable public enum class Transport {
    @SerialName("disconnected") DISCONNECTED, @SerialName("connecting") CONNECTING,
    @SerialName("connected") CONNECTED, @SerialName("reconnecting") RECONNECTING,
}
@Serializable public data class Media(
    public val owner: Owner,
    public val preparation: Preparation,
    public val audio: Audio,
    public val transport: Transport,
)

@Serializable
public sealed interface Model {
    public val version: Int

    @Serializable @SerialName("call") public data class CallValue(override val version: Int, public val value: Call) : Model
    @Serializable @SerialName("action") public data class ActionValue(override val version: Int, public val value: Action) : Model
    @Serializable @SerialName("endReason") public data class EndValue(override val version: Int, public val value: EndReason) : Model
    @Serializable @SerialName("error") public data class ErrorValue(override val version: Int, public val value: CallError) : Model
    @Serializable @SerialName("budgets") public data class BudgetValue(override val version: Int, public val value: Budgets) : Model
    @Serializable @SerialName("endResult") public data class EndResultValue(override val version: Int, public val value: EndResult) : Model
}

/** Strict portable v0 JSON. Canonical output sorts keys and preserves array order. */
public object Wire {
    public val json: Json = Json { classDiscriminator = "kind" }

    public fun decode(source: String): Model {
        val input = normalizeNumbers(json.parseToJsonElement(source))
        val model = json.decodeFromJsonElement(Model.serializer(), input)
        if (model.version != 0 || input != json.encodeToJsonElement(Model.serializer(), model)) {
            throw SerializationException("Expected a version-zero model with only canonical field values")
        }
        return model
    }

    public fun encode(model: Model): String {
        require(model.version == 0)
        return escapeIsolatedSurrogates(canonical(json.encodeToJsonElement(Model.serializer(), model)))
    }

    private fun canonical(value: JsonElement): String = when (value) {
        is JsonArray -> value.joinToString(",", "[", "]", transform = ::canonical)
        is JsonObject -> value.entries.sortedBy { it.key }.joinToString(",", "{", "}") { (key, child) ->
            json.encodeToString(key) + ":" + canonical(child)
        }
        else -> value.toString()
    }

    private fun normalizeNumbers(value: JsonElement): JsonElement = when (value) {
        is JsonArray -> JsonArray(value.map(::normalizeNumbers))
        is JsonObject -> JsonObject(value.mapValues { (_, child) -> normalizeNumbers(child) })
        is JsonPrimitive -> {
            val integer = if (value.isString) null else value.content.toBigDecimalOrNull()?.let {
                try { it.longValueExact() } catch (_: ArithmeticException) { null }
            }
            if (integer == null) value else JsonPrimitive(integer)
        }
    }

    private fun escapeIsolatedSurrogates(text: String): String = buildString(text.length) {
        text.forEachIndexed { index, char ->
            val isolated = char.isHighSurrogate() && text.getOrNull(index + 1)?.isLowSurrogate() != true ||
                char.isLowSurrogate() && text.getOrNull(index - 1)?.isHighSurrogate() != true
            if (isolated) append("\\u").append(char.code.toString(16).padStart(4, '0')) else append(char)
        }
    }
}

internal object ToneSerializer : KSerializer<DTMFSequence> {
    private val digits = ListSerializer(String.serializer())
    override val descriptor = digits.descriptor
    override fun serialize(encoder: Encoder, value: DTMFSequence) =
        encoder.encodeSerializableValue(digits, value.value.map(Char::toString))
    override fun deserialize(decoder: Decoder): DTMFSequence =
        DTMFSequence(decoder.decodeSerializableValue(digits).onEach { require(it.length == 1) }.joinToString(""))
}

internal object TimestampSerializer : KSerializer<Instant> {
    private val formatter = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
    override val descriptor = PrimitiveSerialDescriptor("UtcMilliseconds", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(format(value))
    override fun deserialize(decoder: Decoder): Instant {
        val text = decoder.decodeString()
        val instant = Instant.parse(text)
        require(text.length == 24 && text == format(instant)) { "Expected UTC millisecond timestamp" }
        return instant
    }

    private fun format(value: Instant): String =
        formatter.format(java.time.Instant.ofEpochSecond(value.epochSeconds, value.nanosecondsOfSecond.toLong()))
}
