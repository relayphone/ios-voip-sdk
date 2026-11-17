package com.relayphone.voip

import java.nio.file.Path
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestFactory

class WireFixturesTest {
    @Test
    fun `retention may be omitted or explicitly encode the default`() {
        val default = RetentionBudget()
        val implicit = Wire.encode(Model.BudgetValue(0, Budgets()))
        val explicit = Wire.encode(Model.BudgetValue(0, Budgets().withRetention(default)))
        assertEquals(default, (Wire.decode(implicit) as Model.BudgetValue).value.retention)
        assertEquals(default, (Wire.decode(explicit) as Model.BudgetValue).value.retention)
        assertEquals(implicit, Wire.encode(Wire.decode(implicit)))
        assertEquals(explicit, Wire.encode(Wire.decode(explicit)))
        val invalid = explicit.replace("\"terminalRecords\":256", "\"terminalRecords\":0")
        assertThrows(IllegalArgumentException::class.java) { Wire.decode(invalid) }
    }

    @Test
    fun `canonical encoding preserves isolated code units and normalizes integer formats`() {
        val source = """{"version":0e0,"kind":"action","value":{"kind":"answer","callID":"a\ud800b🏷"}}"""
        val canonical = """{"kind":"action","value":{"callID":"a\ud800b🏷","kind":"answer"},"version":0}"""
        assertEquals(canonical, Wire.encode(Wire.decode(source)))
    }

    @TestFactory
    fun `valid fixtures round trip to canonical JSON`(): List<DynamicTest> =
        fixtures("valid").map { file ->
            DynamicTest.dynamicTest(file.name) {
                val source = file.readText()
                val model = Wire.decode(source)
                assertEquals(canonical(Wire.json.parseToJsonElement(source)).toString(), Wire.encode(model))
                assertEquals(model, Wire.decode(Wire.encode(model)))
            }
        }

    @TestFactory
    fun `invalid fixtures are rejected`(): List<DynamicTest> = fixtures("invalid").map { file ->
        DynamicTest.dynamicTest(file.name) {
            val source = file.readText()
            assertThrows(IllegalArgumentException::class.java) { Wire.decode(source) }
        }
    }

    private fun fixtures(kind: String): List<Path> =
        Path.of(System.getProperty("spec.fixtures"), kind).listDirectoryEntries("*.json").sorted().also {
            check(it.isNotEmpty()) { "No shared ${kind} model fixtures" }
        }

    private fun canonical(value: JsonElement): JsonElement = when (value) {
        is JsonObject -> JsonObject(value.toSortedMap().mapValues { (_, child) -> canonical(child) })
        is JsonArray -> JsonArray(value.map(::canonical))
        else -> value
    }
}
