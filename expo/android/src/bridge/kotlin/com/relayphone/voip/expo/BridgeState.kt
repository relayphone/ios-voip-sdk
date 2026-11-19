package com.relayphone.voip.expo

import com.relayphone.voip.*
import com.relayphone.voip.runtime.*
import java.util.UUID
import kotlinx.serialization.json.*

internal class BridgeState(private val owner: Owner, private val authority: Boolean) {
    private var epoch = UUID.randomUUID().toString()
    private var sequence = 0L
    private var scope: State? = null
    private var initialized = false
    private var sender: ((String) -> Unit)? = null
    private var pushHealth: JsonObject? = null
    private var pushCapabilities = emptyList<JsonObject>()

    private val records = buildJsonArray {
        for (feature in listOf("hold", "video", "tones", "preview", "prejoin", "merge", "audioRoutes", "nativeAnswerAuthority")) {
            val availability = if (feature == "nativeAnswerAuthority" && authority)
                message("available")
            else message("unavailable", "reason" to JsonPrimitive(if (feature == "nativeAnswerAuthority") "disabledByPolicy" else "notImplemented"))
            add(model(1, "capability", buildJsonObject {
                put("feature", feature)
                put("availability", availability)
            }))
        }
    }

    @Synchronized
    fun detach(send: (String) -> Unit) {
        if (sender === send) sender = null
    }

    @Synchronized
    fun attach(send: (String) -> Unit): JsonObject {
        check(sender !== send)
        sender = send
        return snapshot()
    }

    @Synchronized
    fun snapshot(): JsonObject = buildJsonObject {
        put("cursor", cursor())
        val state = scope
        put("calls", buildJsonArray {
            if (state != null) {
                val calls = state.calls
                val terminals = state.terminalCallOrder.toSet()
                calls.filterKeys { it !in terminals }.values.forEach { add(call(it)) }
                terminals.forEach { add(call(calls.getValue(it))) }
            }
        })
        put("completed", encode(scope?.completedTerminalCalls.orEmpty()))
        pushHealth?.let { put("pushHealth", it) }
        put("records", JsonArray(records + pushCapabilities))
    }

    @Synchronized
    fun push(operation: String): JsonObject =
        if (operation == "push.registration") pushHealth?.obj("registration") ?: message("unknown")
        else pushHealth ?: message("unknown")

    @Synchronized
    fun updatePush(health: JsonObject, fullScreenBlock: String?) {
        val capabilities = listOf(capability("push", null),
            capability("fullScreenIncoming", fullScreenBlock))
        if (pushHealth != health) {
            pushHealth = health
            emit("record", "record" to model(1, "pushHealth", health))
        }
        if (pushCapabilities != capabilities) {
            pushCapabilities = capabilities
            capabilities.forEach { emit("record", "record" to it) }
        }
    }

    @Synchronized
    fun cursor(): JsonObject = buildJsonObject {
        put("epoch", epoch)
        put("sequence", sequence)
    }

    @Synchronized
    fun accept(observation: RuntimeObservation) {
        when (observation) {
            RuntimeObservation.ResyncRequired -> Unit
            is RuntimeObservation.Snapshot -> {
                val recovering = initialized || observation.snapshot.cursor.sequence != 0L
                initialized = true
                scope = observation.snapshot.state
                if (recovering) {
                    reset()
                    // A frame in the new epoch prompts the attached store to hydrate from this snapshot.
                    emit("record", "record" to records.first())
                }
            }
            is RuntimeFrame.StateRevision -> {
                val old = scope?.calls.orEmpty()
                scope = observation.state
                val next = observation.state.calls
                for ((id, call) in next) {
                    if (old[id] == call) continue
                    val record = "record" to model(0, "call", call(call))
                    val action = when (val input = observation.input) {
                        is Input.Request -> input.id.takeIf { input.action.callID == id }
                        is Input.AnswerConfirmed -> input.actionID.takeIf { input.callID == id }
                        else -> null
                    }
                    if (action == null) emit("record", record)
                    else emit("record", record, "correlation" to buildJsonObject {
                        put("callID", encode(id))
                        put("actionID", encode(action))
                    })
                }
                for (id in old.keys - next.keys - observation.completing) emit("callRemoved", "callID" to encode(id))
            }
            is RuntimeFrame.Cleanup -> emit("cleanup", "callID" to encode(observation.completion.attempt.callID),
                "outcome" to JsonPrimitive(if (observation.completion.removed) "removed" else "failed"))
            is RuntimeFrame.TerminalCompleted -> {
                val id = observation.event.callID
                emit("terminalCompleted", "callID" to encode(id))
                if (id !in scope?.calls.orEmpty()) emit("callRemoved", "callID" to encode(id))
            }
            is RuntimeFrame.ActionPerformed -> emit("actionPerformed", "receipt" to encode(observation.receipt))
            is RuntimeFrame.Event -> Unit
        }
    }

    private fun call(call: Call) = encode(call.copy(media = call.media.copy(owner = owner)))

    private fun emit(kind: String, vararg fields: Pair<String, JsonElement>) {
        if (sequence == 9_007_199_254_740_991L) reset()
        sequence++
        sender?.invoke(message(kind, "cursor" to cursor(), *fields).toString())
    }

    private fun reset() {
        epoch = UUID.randomUUID().toString()
        sequence = 0
    }
}

private fun model(version: Int, kind: String, value: JsonElement) =
    message(kind, "version" to JsonPrimitive(version), "value" to value)

private fun capability(feature: String, block: String?) = model(1, "capability", buildJsonObject {
    put("feature", feature)
    put("availability", if (block == null) message("available")
        else message("unavailable", "reason" to JsonPrimitive(block)))
})
