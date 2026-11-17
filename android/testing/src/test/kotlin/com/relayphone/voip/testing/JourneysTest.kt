package com.relayphone.voip.testing

import com.relayphone.voip.Wire
import java.nio.file.Path
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.nameWithoutExtension
import kotlin.io.path.readText
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.TestFactory

class JourneysTest {
    @TestFactory
    fun `shared journeys execute with virtual time`(): List<DynamicTest> {
        val files = Path.of(System.getProperty("spec.journeys")).listDirectoryEntries("*.json").sorted()
        val ids = files.map { it.nameWithoutExtension }.toSet()
        check(ids.containsAll(requiredJourneys)) { "Missing v0 journeys: ${requiredJourneys - ids}" }
        pendingJourneys.filterKeys { it !in ids }.forEach { (id, reason) -> println("Pending ${id}: ${reason}") }
        return files.map { file ->
            DynamicTest.dynamicTest(file.nameWithoutExtension) {
                val journey = Wire.json.decodeFromString<Journey>(file.readText())
                check(journey.id == file.nameWithoutExtension)
                runTest {
                    val driver = JourneyDriver(this, journey.configuration)
                    try {
                        journey.steps.forEachIndexed { index, step ->
                            try {
                                when (step) {
                                    is Step.Inject -> driver.apply(step.input)
                                    is Step.Expect -> driver.verify(step.expectation)
                                }
                            } catch (failure: Exception) {
                                throw AssertionError("${journey.id}, step ${index + 1}: $step", failure)
                            } catch (failure: AssertionError) {
                                throw AssertionError("${journey.id}, step ${index + 1}: $step", failure)
                            }
                        }
                    } finally {
                        driver.close()
                    }
                }
            }
        }
    }

    private companion object {
        val requiredJourneys = setOf(
            "answer-not-allowed", "answer-refusal-preview", "answer-refusal", "answered-elsewhere",
            "claim-timeout-reconcile", "cross-line-waiting", "incoming-killed-answer",
            "local-server-end-race", "no-answer-direction", "outgoing-deferred-binding",
        )
        val pendingJourneys = mapOf(
            "end-after-server-end" to "Requires the shared EndResult journey",
            "end-before-admission" to "Requires the shared deferred-admission journey",
            "hold-request-confirm" to "Requires the shared two-phase Hold journey",
            "late-answer-permit" to "Requires the shared late-permit journey",
        )
    }
}
