package com.relayphone.voip

import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory

class IdentityTest {
    @TestFactory
    fun `all identity namespaces validate without rewriting opaque values`(): List<DynamicTest> =
        listOf<Pair<String, (String) -> Any>>(
            "call" to ::CallID, "remote" to ::RemoteCallID, "account" to ::AccountID,
            "line" to ::LineID, "event" to ::EventID, "action" to ::ActionID, "attempt" to ::AttemptID,
        ).map { (name, create) ->
            DynamicTest.dynamicTest(name) {
                val raw = " tenant/呼び出し:AbC-001 "
                assertEquals(create(raw), create(raw))
                assertNotEquals(create(raw), create(raw.trim()))
                listOf("", " ", "\t", "a\nb", "a\u0000b", "a\u007fb").forEach { invalid ->
                    assertThrows(IllegalArgumentException::class.java) { create(invalid) }
                }
            }
        }

    @Test
    fun `canonical identity and service alias remain distinct namespaces`() {
        assertNotEquals(CallID("same") as Any, RemoteCallID("same") as Any)
        assertEquals("same", CallID("same").value)
        assertEquals("same", RemoteCallID("same").value)
    }

    @Test
    fun `serialization preserves IDs and invokes constructor validation`() {
        val encoded = "\"service:AbC/呼び出し\""
        val id = Json.decodeFromString<CallID>(encoded)
        assertEquals("service:AbC/呼び出し", id.value)
        assertEquals(encoded, Json.encodeToString(id))
        assertThrows(IllegalArgumentException::class.java) { Json.decodeFromString<CallID>("\"\"") }
        assertThrows(IllegalArgumentException::class.java) { Json.decodeFromString<ActionID>("\"a\\nb\"") }
    }
}
