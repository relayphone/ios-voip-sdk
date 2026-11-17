package com.relayphone.voip

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class HandleTest {
    @Test
    fun `phone accepts only international E164 syntax`() {
        listOf("+12", "+14155552671", "+123456789012345").forEach {
            assertEquals(it, Handle.Phone(it).e164)
        }
        listOf("", "+1", "+012", "+1234567890123456", "14155552671", "+1 4155552671", "+１２", "sip:123").forEach {
            assertThrows(IllegalArgumentException::class.java) { Handle.Phone(it) }
        }
    }

    @Test
    fun `email validates an address and preserves its spelling`() {
        val address = "Alice+Calls@Example.COM"
        assertEquals(address, Handle.Email(address).address)
        listOf("", "alice", "@example.com", "alice@", "a@@b", "a b@c", "a@b\n").forEach {
            assertThrows(IllegalArgumentException::class.java) { Handle.Email(it) }
        }
    }

    @Test
    fun `opaque handles retain SIP addresses and short codes without reinterpretation`() {
        listOf("sip:Alice@Example.com;transport=tls", "112", "*123#", "+14155552671").forEach {
            assertEquals(it, Handle.Opaque(it).value)
        }
        listOf("", " ", "a\u0000b").forEach {
            assertThrows(IllegalArgumentException::class.java) { Handle.Opaque(it) }
        }
    }

    @Test
    fun `calling lines retain separate account and line identities with display labels`() {
        val line = CallingLine(AccountID("account"), LineID("work"), "Work ☎")
        assertEquals("account", line.accountID.value)
        assertEquals("work", line.lineID.value)
        assertEquals("Work ☎", line.label)
        assertEquals(line, line.copy())
    }
}
