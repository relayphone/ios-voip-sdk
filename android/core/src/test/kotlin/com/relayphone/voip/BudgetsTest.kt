package com.relayphone.voip

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.nanoseconds
import kotlin.time.Duration.Companion.seconds
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BudgetsTest {
    @Test
    fun `answer defaults leave time for required preparation and settlement`() {
        val budget = AnswerBudget()
        assertEquals(4500.milliseconds, budget.total)
        assertEquals(2500.milliseconds, budget.claim)
        assertEquals(500.milliseconds, budget.reconciliation)
        assertEquals(500.milliseconds, budget.settlementReserve)
        assertEquals(1000.milliseconds, budget.total - budget.claim - budget.reconciliation - budget.settlementReserve)
        assertEquals(Outcome.Success(Unit), budget.validateFor(5.seconds))
        assertEquals(Outcome.Success(Unit), budget.validateFor(budget.total))
        assertEquals(
            Outcome.Failure(CallError.InvalidConfiguration(ConfigurationField.ANSWER_BUDGET)),
            budget.validateFor(budget.total - 1.nanoseconds),
        )
    }

    @Test
    fun `answer rejects nonfinite nonpositive and impossible stage budgets`() {
        val budget = AnswerBudget()
        listOf(Duration.ZERO, (-1).nanoseconds, Duration.INFINITE, -Duration.INFINITE).forEach { invalid ->
            listOf<() -> AnswerBudget>(
                { budget.copy(total = invalid) }, { budget.copy(claim = invalid) },
                { budget.copy(reconciliation = invalid) }, { budget.copy(settlementReserve = invalid) },
            ).forEach { construct -> assertThrows(IllegalArgumentException::class.java) { construct() } }
            assertInstanceOf(Outcome.Failure::class.java, budget.validateFor(invalid))
        }
        assertThrows(IllegalArgumentException::class.java) { budget.copy(total = 3499.milliseconds) }
        assertThrows(IllegalArgumentException::class.java) { budget.copy(claim = 4.seconds) }
        assertThrows(IllegalArgumentException::class.java) { budget.copy(reconciliation = 2.seconds) }
        assertThrows(IllegalArgumentException::class.java) { budget.copy(settlementReserve = 5.seconds) }
        assertEquals(3500.milliseconds, budget.copy(total = 3500.milliseconds).total)
        val large = (Long.MAX_VALUE / 3).milliseconds
        assertTrue(large.isFinite())
        assertThrows(IllegalArgumentException::class.java) {
            AnswerBudget(total = large, claim = large, reconciliation = large, settlementReserve = large)
        }
    }

    @Test
    fun `invitation and media budgets shorten to enclosing expiry without extension`() {
        val invitation = InvitationBudget()
        assertEquals(45.seconds, invitation.incomingRing)
        assertEquals(45.seconds, invitation.outgoingNoAnswer)
        assertEquals(2.seconds, invitation.incomingRemaining(2.seconds))
        assertEquals(45.seconds, invitation.outgoingRemaining(60.seconds))
        assertEquals(Duration.ZERO, invitation.incomingRemaining((-1).seconds))
        assertEquals(Duration.ZERO, invitation.outgoingRemaining(Duration.ZERO))
        assertEquals(45.seconds, invitation.incomingRemaining(Duration.INFINITE))
        val media = MediaPreparationBudget()
        assertEquals(5.seconds, media.timeout)
        assertEquals(1.nanoseconds, media.remaining(1.nanoseconds))
        assertEquals(5.seconds, media.remaining(10.seconds))
        assertEquals(Duration.ZERO, media.remaining((-1).nanoseconds))
    }

    @Test
    fun `connection and retention defaults keep independent time and count bounds`() {
        val connection = ConnectionBudget()
        assertEquals(30.seconds, connection.connection)
        assertEquals(15.seconds, connection.reconnection)
        val retention = RetentionBudget()
        assertEquals(120.seconds, retention.lifetime)
        assertEquals(256, retention.terminalRecords)
        assertThrows(IllegalArgumentException::class.java) { retention.copy(terminalRecords = 0) }
        assertThrows(IllegalArgumentException::class.java) { retention.copy(terminalRecords = -1) }
    }

    @Test
    fun `every policy rejects invalid durations including copy operations`() {
        listOf(Duration.ZERO, (-1).seconds, Duration.INFINITE, -Duration.INFINITE).forEach { invalid ->
            listOf<() -> Any>(
                { InvitationBudget(incomingRing = invalid) }, { InvitationBudget().copy(outgoingNoAnswer = invalid) },
                { MediaPreparationBudget(invalid) }, { ConnectionBudget(connection = invalid) },
                { ConnectionBudget().copy(reconnection = invalid) }, { RetentionBudget(lifetime = invalid) },
            ).forEach { construct -> assertThrows(IllegalArgumentException::class.java) { construct() } }
        }
    }
}
