package com.relayphone.voip.testing

import com.relayphone.voip.AnswerBudget
import com.relayphone.voip.CallID
import com.relayphone.voip.Outcome
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class DependencyTest {
    @Test
    @OptIn(ExperimentalCoroutinesApi::class)
    fun `testing module consumes core with deterministic coroutine time`() = runTest {
        val result = async {
            delay(AnswerBudget().claim)
            Outcome.Success(CallID("call-1"))
        }
        assertEquals(Outcome.Success(CallID("call-1")), result.await())
        assertEquals(2500.milliseconds.inWholeMilliseconds, testScheduler.currentTime)
        assertEquals(Outcome.Success(Unit), AnswerBudget().validateFor(5.seconds))
    }

    @Test
    fun `serialization runtime can consume the core value class from another module`() {
        val id = CallID("case-sensitive:AbC")
        assertEquals(id, Json.decodeFromString<CallID>(Json.encodeToString(id)))
    }
}
