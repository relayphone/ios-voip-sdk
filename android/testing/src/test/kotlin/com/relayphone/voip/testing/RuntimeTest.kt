package com.relayphone.voip.testing

import com.relayphone.voip.*
import com.relayphone.voip.runtime.*
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RuntimeTest {
    @Test
    fun `admission comes from session entry and shutdown joins suspended sessions`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        try {
            runtime.invite(id)
            runtime.invite(other)
            runCurrent()
            assertEquals(mapOf(id to Lifecycle.Reporting, other to Lifecycle.Reporting), runtime.lifecycles())
            ports.admissions.getValue(other).invoke()
            runCurrent()
            assertEquals(mapOf(id to Lifecycle.Reporting, other to Lifecycle.Ringing), runtime.lifecycles())
            assertTrue(ports.sessions.values.none { it.isCompleted })
            assertTrue(ports.retired.isEmpty())

            val closing = launch { runtime.close() }
            runCurrent()
            assertFalse(closing.isCompleted)
            assertFalse(runtime.submit(Input.Admitted(Attempt(id, 1))))
            advanceTimeBy(1)
            runCurrent()
            assertTrue(closing.isCompleted)
            assertEquals(setOf(id, other), ports.retired)
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `virtual timer starts ordered teardown and removal and release complete independently`() = runTest {
        listOf(true, false).forEach { mediaFirst ->
            val ports = Ports()
            val runtime = start(ports)
            try {
                runtime.invite(id)
                runCurrent()
                ports.admissions.getValue(id).invoke()
                runCurrent()
                val deadline = configuration.budgets.incomingRing.inWholeMilliseconds
                advanceTimeBy(deadline - 1)
                runCurrent()
                assertTrue(ports.cleanup.isEmpty())
                advanceTimeBy(1)
                runCurrent()
                assertEquals(listOf("media", "system"), ports.cleanup)
                assertEquals(Lifecycle.Ending(EndReason.Unanswered), runtime.lifecycles().getValue(id))
                assertFalse(id in runtime.state.value.systemRemoved)

                if (mediaFirst) {
                    ports.mediaRelease.complete(Unit)
                    runCurrent()
                    assertTrue(runtime.lifecycles().getValue(id) is Lifecycle.Ended)
                    assertFalse(id in runtime.state.value.systemRemoved)
                    ports.systemRemoval.complete(Outcome.Success(Unit))
                } else {
                    ports.systemRemoval.complete(Outcome.Success(Unit))
                    runCurrent()
                    assertTrue(id in runtime.state.value.systemRemoved)
                    assertTrue(runtime.lifecycles().getValue(id) is Lifecycle.Ending)
                    ports.mediaRelease.complete(Unit)
                }
                advanceTimeBy(1)
                runCurrent()
                assertTrue(runtime.lifecycles().getValue(id) is Lifecycle.Ended)
                assertTrue(id in runtime.state.value.systemRemoved)
                assertEquals(setOf(id), ports.retired)
            } finally {
                runtime.close()
            }
        }
    }

    @Test
    fun `failed removal preserves its diagnostic without confirming removal`() = runTest {
        val ports = Ports()
        val runtime = start(ports, policy = shortRetention)
        try {
            val failure = async(start = CoroutineStart.UNDISPATCHED) {
                runtime.events.filterIsInstance<RuntimeEvent.SystemRemovalFailed>().first()
            }
            runtime.invite(id)
            runCurrent()
            ports.admissions.getValue(id).invoke()
            runtime.endFromServer(id)
            runCurrent()
            ports.mediaRelease.complete(Unit)
            advanceTimeBy(1_000)
            runtime.endFromServer(other)
            runCurrent()
            assertEquals(EndReason.RemoteEnded, (runtime.lifecycles().getValue(id) as Lifecycle.Ended).reason)
            assertFalse(id in runtime.state.value.systemRemoved)
            val diagnostic = SystemFailure(Platform.ANDROID, SystemOperation.REMOVAL, nativeCode = 3)
            ports.systemRemoval.complete(Outcome.Failure(diagnostic))
            runCurrent()
            assertTrue(failure.isCompleted)
            assertEquals(diagnostic, failure.await().failure)
            assertFalse(id in runtime.state.value.calls)
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `authority release completion retires the retained permit owner`() = runTest {
        val permit = AttemptID("permit")
        val ports = Ports(answerPermit = permit)
        val runtime = start(ports, policy = shortRetention)
        try {
            runtime.invite(id)
            runCurrent()
            ports.admissions.getValue(id).invoke()
            val answer = ActionID("answer")
            check(runtime.submit(Input.Request(Action.Answer(id), answer)))
            runCurrent()
            assertEquals(listOf(answer), ports.settlements)

            ports.mediaRelease.complete(Unit)
            ports.systemRemoval.complete(Outcome.Success(Unit))
            runtime.endFromServer(id)
            runCurrent()
            assertEquals(permit, ports.releaseRequest.getCompleted().permit)

            advanceTimeBy(1_000)
            runtime.endFromServer(other)
            runCurrent()
            assertTrue(runtime.lifecycles().getValue(id) is Lifecycle.Ended)
            ports.permitReleased.complete(Unit)
            runCurrent()
            assertFalse(id in runtime.state.value.calls)
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `UTC jumping backwards during ringing leaves the no-answer deadline unchanged`() = runTest {
        val ports = Ports()
        val epoch = Instant.parse("2026-11-18T12:00:00Z")
        var correction = Duration.ZERO
        val utc = object : Clock {
            override fun now(): Instant = epoch + testScheduler.currentTime.milliseconds + correction
        }
        val runtime = start(ports, utc)
        try {
            val remaining = 20.seconds
            runtime.invite(id, expiresAt = utc.now() + remaining)
            runCurrent()
            ports.admissions.getValue(id).invoke()
            runCurrent()
            advanceTimeBy(10_000)
            correction -= 1.hours
            advanceTimeBy(9_999)
            runCurrent()
            assertEquals(Lifecycle.Ringing, runtime.lifecycles().getValue(id))
            assertTrue(ports.cleanup.isEmpty())

            advanceTimeBy(1)
            runCurrent()
            assertEquals(Lifecycle.Ending(EndReason.Unanswered), runtime.lifecycles().getValue(id))
            ports.mediaRelease.complete(Unit)
            ports.systemRemoval.complete(Outcome.Success(Unit))
            runCurrent()
            assertEquals(Lifecycle.Ended(EndReason.Unanswered, utc.now()), runtime.lifecycles().getValue(id))
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `a slow event reader sees a sequence gap when the buffer overflows`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        val seen = mutableListOf<Long>()
        val resumeReader = CompletableDeferred<Unit>()
        val reader = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            runtime.events.collect { event ->
                seen += event.sequence
                resumeReader.await()
            }
        }
        try {
            ports.mediaRelease.complete(Unit)
            ports.systemRemoval.complete(Outcome.Failure(SystemFailure(Platform.ANDROID, SystemOperation.REMOVAL)))
            runtime.invite(id)
            runCurrent()
            ports.admissions.getValue(id).invoke()
            runtime.endFromServer(id)
            runCurrent()
            assertEquals(listOf(1L), seen)

            val burst = List(80) { CallID("overflow-$it") }
            burst.forEach { runtime.invite(it) }
            runCurrent()
            burst.forEach { callID ->
                ports.admissions.getValue(callID).invoke()
                runtime.endFromServer(callID)
            }
            runCurrent()
            assertEquals(listOf(1L), seen)

            resumeReader.complete(Unit)
            runCurrent()
            val retained = seen.drop(1)
            assertTrue(retained.first() > 2)
            assertEquals(1L + burst.size, retained.last())
            assertTrue(retained.zipWithNext().all { (before, after) -> after == before + 1 })
            assertEquals(burst.size + 1, runtime.state.value.calls.size)
            assertTrue(runtime.lifecycles().values.all { it is Lifecycle.Ended })
        } finally {
            reader.cancel()
            runtime.close()
        }
    }

    @Test
    fun `startup rejects an Answer budget above the system port allowance`() = runTest {
        val ports = Ports(answerDeadline = 4.seconds)
        val result = CallRuntime.start(configuration, backgroundScope, ports, ports, ports, ports, monotonicClock())
        assertEquals(Outcome.Failure(CallError.InvalidConfiguration(ConfigurationField.ANSWER_BUDGET)), result)
        assertTrue(ports.sessions.isEmpty())
    }

    private fun TestScope.start(ports: Ports, utc: Clock = Clock.System, policy: Configuration = configuration): CallRuntime =
        (CallRuntime.start(policy, backgroundScope, ports, ports, ports, ports, monotonicClock(), utc)
            as Outcome.Success).value

    private fun TestScope.monotonicClock(): MonotonicClock =
        MonotonicClock { Instant.fromEpochMilliseconds(testScheduler.currentTime) }

    private class Ports(
        override val answerDeadline: Duration = 5.seconds,
        private val answerPermit: AttemptID? = null,
    ) : SystemPort, AuthorityPort, MediaPort, PresentationPort {
        val admissions = mutableMapOf<CallID, () -> Unit>()
        val sessions = mutableMapOf<CallID, CompletableDeferred<Unit>>()
        val retired = mutableSetOf<CallID>()
        val cleanup = mutableListOf<String>()
        val mediaRelease = CompletableDeferred<Unit>()
        val systemRemoval = CompletableDeferred<Outcome<Unit, SystemFailure>>()
        val settlements = mutableListOf<ActionID>()
        val releaseRequest = CompletableDeferred<Effect.ReleasePermit>()
        val permitReleased = CompletableDeferred<Unit>()

        override suspend fun reportIncoming(call: Call, request: Effect.ReportIncoming, admitted: () -> Unit) {
            val done = CompletableDeferred<Unit>()
            sessions[call.id] = done
            admissions[call.id] = admitted
            try {
                done.await()
            } finally {
                withContext(NonCancellable) { delay(1) }
                retired += call.id
            }
        }

        override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
            cleanup += "system"
            return systemRemoval.await().also { sessions.getValue(call.id).complete(Unit) }
        }

        override suspend fun close(request: Effect.CloseMedia) {
            cleanup += "media"
            mediaRelease.await()
        }

        override suspend fun startOutgoing(call: Call, request: Effect.NativeStart): Unit = error("Unexpected Start")
        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> = error("Unexpected control")
        override suspend fun setActive(request: Effect.SetActive): Unit = error("Unexpected activation")
        override fun settle(result: Effect.SettleAction) {
            settlements += result.actionID
        }
        override fun reject(result: Effect.RejectAction): Unit = error("Unexpected rejection")
        override fun completeEnd(result: Effect.CompleteEnd): Unit = error("Unexpected local End")
        override suspend fun place(call: Call, request: Effect.RequestPlacement): Outcome<Unit, CallError.PlacementFailed> =
            error("Unexpected placement")
        override suspend fun claim(request: Effect.RequestClaim): AnswerDecision =
            AnswerDecision.Allow(checkNotNull(answerPermit))
        override suspend fun reconcile(request: Effect.Reconcile): Reconciliation = error("Unexpected reconciliation")
        override suspend fun release(request: Effect.ReleasePermit) {
            check(releaseRequest.complete(request))
            permitReleased.await()
        }
        override suspend fun prepare(request: Effect.PrepareMedia): Outcome<Unit, CallError.MediaFailed> = Outcome.Success(Unit)
        override suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError> = error("Unexpected tones")
        override fun publish(call: Call) {}
    }

    private companion object {
        val id = CallID("incoming")
        val other = CallID("other")
        val line = CallingLine(AccountID("account"), LineID("personal"), "Personal")
        val party = Party(PartyID("alice"), Handle.Opaque("sip:alice@example.test"), "Alice")
        val configuration = Configuration(Budgets(), OutgoingMedia.WHEN_PROVIDED, ConnectionAuthority.APPLICATION, 1, true)
        val shortRetention = configuration.copy(budgets = Budgets().withRetention(RetentionBudget(lifetime = 1.seconds)))

        fun CallRuntime.lifecycles(): Map<CallID, Lifecycle> = state.value.calls.mapValues { it.value.lifecycle }
        fun CallRuntime.invite(id: CallID, expiresAt: Instant? = null) {
            check(submit(Input.Incoming(id, EventID(id.value), line, party, expiresAt)))
        }

        fun CallRuntime.endFromServer(id: CallID) {
            check(submit(Input.RemoteEnd(EndTarget.Canonical(id), EventID("end-${id.value}"), EndReason.RemoteEnded)))
        }
    }
}
