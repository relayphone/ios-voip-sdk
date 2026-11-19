package com.relayphone.voip.expo

import com.relayphone.voip.Wire
import java.io.File
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

internal class BridgeWireTest {
    private val fixtures = File(System.getProperty("spec.bridge")).parentFile

    @Test
    fun `the Android bridge round trips all valid messages`() {
        for (file in fixtures.resolve("valid").listFiles().orEmpty()) {
            for (message in Wire.json.parseToJsonElement(file.readText()).jsonArray) {
                assertEquals(message, BridgeWire.decode(message.toString()), file.name)
            }
        }
    }

    @Test
    fun `the Android bridge rejects all invalid messages`() {
        for (file in fixtures.resolve("invalid").listFiles().orEmpty()) {
            for (message in Wire.json.parseToJsonElement(file.readText()).jsonArray) {
                assertThrows(IllegalArgumentException::class.java) { BridgeWire.decode(message.toString()) }
            }
        }
    }

    @Test
    fun `negotiation accepts only a nonempty offer of distinct versions`() {
        val offers = Wire.json.parseToJsonElement(fixtures.resolve("valid/negotiation.json").readText()).jsonArray
            .filter { it.jsonObject.text("kind") == "negotiate" }
        assertTrue(BridgeWire.negotiate(offers.first().toString()))
        assertFalse(BridgeWire.negotiate(offers.last().toString()))
        assertThrows(IllegalArgumentException::class.java) {
            BridgeWire.negotiate("""{"kind":"negotiate","versions":[1,1]}""")
        }
    }
}
