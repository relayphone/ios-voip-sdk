package com.relayphone.voip.expo

import com.relayphone.voip.Wire
import kotlinx.serialization.json.*

internal object BridgeWire {
    private val documents = listOf("bridge.schema.json", "model.schema.json", "v1/model.schema.json").associate { name ->
        val source = checkNotNull(javaClass.getResourceAsStream("/voip/$name")).bufferedReader().use { it.readText() }
        val document = Wire.json.parseToJsonElement(source).jsonObject
        document.text("\$id") to document
    }
    private val bridge = documents.values.first()

    fun decode(source: String, definition: String? = null): JsonObject {
        val value = Wire.json.parseToJsonElement(source).jsonObject
        require(matches(value, definition?.let { bridge.obj("\$defs").obj(it) } ?: bridge, bridge)) {
            "Invalid call bridge message"
        }
        return value
    }

    fun negotiate(source: String): Boolean {
        val versions = decode(source, "negotiate").getValue("versions").jsonArray
        require(versions.distinct().size == versions.size)
        return JsonPrimitive(1) in versions
    }

    fun pushEnvelope(value: JsonObject): JsonObject {
        val root = documents.values.last()
        require(matches(value, root, root)) { "Invalid push envelope" }
        return value.obj("value")
    }

    private fun matches(value: JsonElement, rule: JsonObject, root: JsonObject): Boolean {
        rule["\$ref"]?.jsonPrimitive?.content?.let { reference ->
            val (document, key) = reference.split("#/\$defs/", limit = 2)
            val target = if (document.isEmpty()) root else documents.getValue(document)
            if (!matches(value, target.obj("\$defs").obj(key), target)) return false
        }
        rule["const"]?.let { if (it != value) return false }
        rule["enum"]?.jsonArray?.let { if (value !in it) return false }
        rule["oneOf"]?.jsonArray?.let { if (it.count { option -> matches(value, option.jsonObject, root) } != 1) return false }
        return when (rule["type"]?.jsonPrimitive?.content) {
            "object" -> value is JsonObject && (rule["required"]?.jsonArray.orEmpty()).all { it.jsonPrimitive.content in value } &&
                value.all { (key, child) ->
                    val field = rule["properties"]?.jsonObject?.get(key)
                    if (field == null) rule["additionalProperties"] != JsonPrimitive(false)
                    else matches(child, field.jsonObject, root)
                }
            "array" -> value is JsonArray && value.size >= rule.int("minItems", 0) &&
                (rule["items"]?.jsonObject?.let { item -> value.all { matches(it, item, root) } } ?: true)
            "string" -> value is JsonPrimitive && value.isString && value.content.let { string ->
                string.codePointCount(0, string.length) in rule.int("minLength", 0)..rule.int("maxLength", Int.MAX_VALUE) &&
                    (rule["pattern"]?.jsonPrimitive?.content?.let { Regex(it).containsMatchIn(string) } ?: true)
            }
            "integer" -> value is JsonPrimitive && !value.isString && value.longOrNull?.let {
                it in (rule["minimum"]?.jsonPrimitive?.long ?: -MAX_SAFE)..(rule["maximum"]?.jsonPrimitive?.long ?: MAX_SAFE)
            } == true
            "boolean" -> value is JsonPrimitive && !value.isString && value.booleanOrNull != null
            null -> true
            else -> error("Unsupported bridge schema type")
        }
    }

    private fun JsonObject.int(key: String, default: Int) = get(key)?.jsonPrimitive?.int ?: default
    private const val MAX_SAFE = 9_007_199_254_740_991L
}

internal fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.content
internal fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject
internal inline fun <reified T> JsonObject.read(key: String): T = Wire.json.decodeFromJsonElement(getValue(key))
internal inline fun <reified T> encode(value: T): JsonElement = Wire.json.encodeToJsonElement(value)
internal fun message(kind: String, vararg fields: Pair<String, JsonElement>) =
    JsonObject(mapOf("kind" to JsonPrimitive(kind), *fields))
