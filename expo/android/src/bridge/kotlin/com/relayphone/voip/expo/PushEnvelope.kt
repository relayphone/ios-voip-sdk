package com.relayphone.voip.expo

import com.relayphone.voip.EventID
import com.relayphone.voip.Input
import com.relayphone.voip.Wire
import java.time.format.DateTimeFormatterBuilder
import kotlin.time.Instant
import kotlinx.serialization.json.*

internal sealed interface PushEnvelope {
    data object Unrelated : PushEnvelope
    data object Invalid : PushEnvelope
    data object Ineligible : PushEnvelope
    data class Invitation(val input: Input.Incoming, val credentialRef: String?) : PushEnvelope

    companion object {
        private val timestampFormat = DateTimeFormatterBuilder().appendInstant(3).toFormatter()

        fun decode(data: Map<String, String>, receivedAt: Instant, elapsed: Instant): PushEnvelope {
            if (data["kind"] != "pushEnvelope") return Unrelated
            return try {
                require(data.keys == setOf("kind", "version", "value") && data["version"] == "1")
                val payload = BridgeWire.pushEnvelope(buildJsonObject {
                    put("version", 1)
                    put("kind", "pushEnvelope")
                    put("value", Wire.json.parseToJsonElement(data.getValue("value")))
                })
                val issued = timestamp(payload.text("issuedAt"))
                val expires = timestamp(payload.text("expiresAt"))
                require(issued < expires)
                val credential = payload["credentialRef"]?.jsonPrimitive?.content?.also { EventID(it) }
                val invite = payload.obj("invitation")
                val input = Input.Incoming(invite.read("callID"), invite.read("eventID"),
                    invite.read("line"), invite.read("party"), ringDeadline = elapsed + (expires - receivedAt))
                if (receivedAt < issued || receivedAt >= expires) Ineligible else Invitation(input, credential)
            } catch (_: IllegalArgumentException) {
                Invalid
            }
        }

        private fun timestamp(value: String): Instant {
            val instant = Instant.parse(value)
            require(timestampFormat.format(java.time.Instant.ofEpochMilli(instant.toEpochMilliseconds())) == value)
            return instant
        }
    }
}
