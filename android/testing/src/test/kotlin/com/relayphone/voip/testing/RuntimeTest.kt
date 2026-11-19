package com.relayphone.voip.testing

import com.relayphone.voip.*
import com.relayphone.voip.runtime.*
import java.io.File
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
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RuntimeTest {
    @Test
    fun `bridge command fixtures resolve from the runtime and preserve Start participants and video`() = runTest {
        val pairs = bridgeFixture("commands").chunked(2)
        val (startCommand, started) = pairs.first { (command) -> command.text("operation") == "start" }
        val input = startCommand.getValue("input").jsonObject
        val id = CallID(input.text("id"))
        val parties = Wire.json.decodeFromJsonElement<List<Party>>(input.getValue("parties"))
        val multiple = parties + party.copy(id = PartyID("another"), displayName = "Another")
        val action = ActionID(started.getValue("result").jsonObject.getValue("value").jsonObject
            .getValue("receipt").jsonObject.text("actionID"))
        val ports = Ports(outgoing = { admitted ->
            admitted()
            awaitCancellation()
        }, activate = {})
        val runtime = start(ports)
        try {
            check(runtime.submit(Input.Start(id, line.copy(lineID = LineID(input.text("lineID"))), multiple, true, action)))
            runCurrent()
            check(runtime.submit(Input.ProvideMedia(id)))
            runCurrent()
            assertEquals(listOf(action), ports.settlements)
            assertEquals(multiple, runtime.state.value.calls.getValue(id).parties)
            assertTrue(runtime.state.value.calls.getValue(id).video)

            for ((command, reply) in pairs) {
                val operation = command.text("operation")
                val result = reply.getValue("result").jsonObject
                when (operation) {
                    "bindRemote" -> {
                        val binding = command.getValue("input").jsonObject
                        val target = CallID(binding.text("id"))
                        val alias = RemoteCallID(binding.text("remoteID"))
                        when (val actual = runtime.bindRemote(target, alias)) {
                            is Outcome.Success -> {
                                assertEquals(JsonNull, result["value"])
                                assertEquals(alias, runtime.state.value.calls.getValue(target).remoteID)
                                assertEquals(actual, runtime.bindRemote(target, alias))
                                val other = RemoteCallID("other-alias")
                                assertEquals(Outcome.Failure(CallError.RemoteIdentityConflict(other)), runtime.bindRemote(target, other))
                            }
                            is Outcome.Failure -> assertEquals(result["error"], Wire.json.encodeToJsonElement(actual.error))
                        }
                    }
                    "receive" -> {
                        val event = Wire.json.decodeFromJsonElement<RemoteEvent>(command.getValue("input"))
                        if (event !is RemoteEvent.Connected) continue
                        val actual = runtime.receive(event) as Outcome.Success
                        assertEquals(result.getValue("value").jsonObject["kind"], Wire.json.encodeToJsonElement(actual.value))
                        assertTrue(runtime.state.value.calls.getValue(id).lifecycle is Lifecycle.Connected)
                    }
                }
            }
        } finally {
            runtime.close()
        }
        assertEquals(Outcome.Failure(CallError.BridgeUnavailable), runtime.bindRemote(id, RemoteCallID("closed")))
    }

    @Test
    fun `receive buffers by alias and applies each event once in arrival order`() = runTest {
        val transcript = bridgeFixture("commands")
        val connected = transcript.first { it["operation"]?.jsonPrimitive?.content == "receive" }.getValue("input")
        val event = Wire.json.decodeFromJsonElement<RemoteEvent>(connected) as RemoteEvent.Connected
        val placement = CompletableDeferred<Unit>()
        val ports = Ports(outgoing = { admitted ->
            admitted()
            awaitCancellation()
        }, activate = {}, placement = placement)
        val runtime = start(ports)
        val alias = (event.target as EndTarget.Alias).id
        val parties = mutableListOf(party.copy(displayName = "New name"))
        try {
            assertEquals(Outcome.Success(ReceiveDisposition.BUFFERED), runtime.receive(event))
            assertEquals(Outcome.Success(ReceiveDisposition.DUPLICATE), runtime.receive(event))
            assertEquals(Outcome.Success(ReceiveDisposition.BUFFERED),
                runtime.receive(RemoteEvent.PartiesChanged(EventID("parties"), event.target, parties)))
            parties.clear()
            assertEquals(Outcome.Success(ReceiveDisposition.BUFFERED),
                runtime.receive(RemoteEvent.PartiesChanged(EventID("parties-last"), event.target, listOf(party))))
            assertEquals(Outcome.Failure(CallError.Unsupported(Feature.VIDEO)),
                runtime.receive(RemoteEvent.VideoRequested(EventID("video"), event.target, false)))
            check(runtime.submit(Input.Start(id, line, listOf(party), true, ActionID("start"))))
            runCurrent()
            assertEquals(Outcome.Success(Unit), runtime.bindRemote(id, alias))
            assertEquals(Lifecycle.Placing, runtime.state.value.calls.getValue(id).lifecycle)
            placement.complete(Unit)
            runCurrent()
            check(runtime.submit(Input.ProvideMedia(id)))
            runCurrent()
            val call = runtime.state.value.calls.getValue(id)
            assertTrue(call.lifecycle is Lifecycle.Connected)
            assertEquals(listOf(party), call.parties)
            assertTrue(call.video)
            assertEquals(Outcome.Success(ReceiveDisposition.DUPLICATE), runtime.receive(event))
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `a buffered End prevents placement and produces no Telecom removal`() = runTest {
        val ports = Ports(outgoing = { error("Unexpected native Start") })
        val runtime = start(ports)
        try {
            val event = RemoteEvent.Ended(EventID("early-end"), EndTarget.Canonical(id), EndReason.RemoteEnded)
            assertEquals(Outcome.Success(ReceiveDisposition.BUFFERED), runtime.receive(event))
            val action = ActionID("start")
            ports.mediaRelease.complete(Unit)
            check(runtime.submit(Input.Start(id, line, listOf(party), false, action)))
            runCurrent()
            assertEquals(listOf(Effect.RejectAction(id, action, CallError.InvalidTransition(LifecycleKind.ENDING))),
                ports.rejections)
            assertEquals(EndReason.RemoteEnded, (runtime.lifecycles().getValue(id) as Lifecycle.Ended).reason)
            assertEquals(listOf("media"), ports.cleanup)
            assertEquals(setOf(id), runtime.state.value.systemRemovalNotApplicable)
            assertEquals(setOf(id), runtime.state.value.completedTerminalCalls)
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `bridge observations distinguish ended calls from completed adapter cleanup`() = runTest {
        val fixture = bridgeFixture("observations")
        val snapshot = fixture.first()
        val calls = Wire.json.decodeFromJsonElement<List<Call>>(snapshot.getValue("calls"))
        val (oldest, younger) = calls
        val utc = object : Clock {
            override fun now(): Instant = (oldest.lifecycle as Lifecycle.Ended).endedAt + testScheduler.currentTime.milliseconds
        }
        val ports = Ports()
        val youngerRemoval = CompletableDeferred<Outcome<Unit, SystemFailure>>()
        ports.removalByCall[younger.id] = youngerRemoval
        val runtime = start(ports, utc)
        val completed = mutableListOf<CallID>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            runtime.events.filterIsInstance<RuntimeEvent.TerminalCompleted>().collect { completed += it.callID }
        }
        try {
            ports.mediaRelease.complete(Unit)
            for (call in calls.reversed()) {
                check(runtime.submit(Input.Incoming(call.id, EventID("invite-${call.id.value}"), call.line, call.parties.single())))
                runCurrent()
                ports.admissions.getValue(call.id).invoke()
                runCurrent()
            }
            for (call in calls) {
                runtime.endFromServer(call.id)
                runCurrent()
                if (call == oldest) {
                    advanceTimeBy(1_000)
                    runCurrent()
                }
            }
            youngerRemoval.complete(Outcome.Success(Unit))
            advanceTimeBy(2)
            runCurrent()
            val state = runtime.state.value
            assertEquals(calls, state.terminalCallOrder.map(state.calls::getValue))
            val expected = snapshot.getValue("completed").jsonArray.map { CallID(it.jsonPrimitive.content) }
            assertEquals(expected.toSet(), runtime.state.value.completedTerminalCalls)
            assertEquals(expected, completed)

            ports.systemRemoval.complete(Outcome.Success(Unit))
            runCurrent()
            assertEquals(setOf(oldest.id, younger.id), runtime.state.value.systemRemoved)
            assertEquals(expected, completed)
            advanceTimeBy(1)
            runCurrent()
            val late = fixture.first { it["kind"]?.jsonPrimitive?.content == "terminalCompleted" }
            assertEquals(expected + CallID(late.text("callID")), completed)
            assertEquals(completed.toSet(), runtime.state.value.completedTerminalCalls)
        } finally {
            runtime.close()
        }
    }

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
    fun `a report rejection ends only its call and leaves no platform removal work`() = runTest {
        val ports = Ports()
        val runtime = start(ports)
        try {
            runtime.invite(id)
            runtime.invite(other)
            runCurrent()
            ports.admissions.getValue(other).invoke()
            runCurrent()
            val failure = SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION, nativeCode = 37)
            ports.sessions.getValue(id).complete(Outcome.Failure(failure))
            advanceTimeBy(1)
            runCurrent()

            val reason = EndReason.Failed(CallError.SystemFailed(failure))
            assertEquals(mapOf(id to Lifecycle.Ending(reason), other to Lifecycle.Ringing), runtime.lifecycles())
            assertEquals(listOf("media"), ports.cleanup)
            assertEquals(setOf(id), runtime.state.value.systemRemovalNotApplicable)
            assertTrue(runtime.state.value.systemRemoved.isEmpty())
            assertFalse(ports.sessions.getValue(other).isCompleted)

            ports.mediaRelease.complete(Unit)
            runCurrent()
            assertEquals(reason, (runtime.lifecycles().getValue(id) as Lifecycle.Ended).reason)
            assertEquals(Lifecycle.Ringing, runtime.lifecycles().getValue(other))
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `native start rejection reaches the matching Start receipt`() = runTest {
        val failure = SystemFailure(Platform.ANDROID, SystemOperation.START, nativeCode = 38)
        val ports = Ports(outgoing = { Outcome.Failure(failure) })
        val runtime = start(ports)
        try {
            val action = ActionID("start")
            check(runtime.submit(Input.Request(Action.Start(id, line, party), action)))
            runCurrent()

            val error = CallError.SystemFailed(failure)
            assertEquals(listOf(Effect.RejectAction(id, action, error)), ports.rejections)
            assertEquals(Lifecycle.Ending(EndReason.Failed(error)), runtime.lifecycles().getValue(id))
            assertEquals(setOf(id), runtime.state.value.systemRemovalNotApplicable)
            assertEquals(listOf("media"), ports.cleanup)
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `native Start success without admission rejects and prunes its record`() = runTest {
        verifyUnadmittedStart { Outcome.Success(Unit) }
    }

    @Test
    fun `native Start exception before admission rejects and prunes its record`() = runTest {
        verifyUnadmittedStart { throw IllegalStateException("session aborted") }
    }

    @Test
    fun `native Start cancellation before admission rejects and prunes its record`() = runTest {
        verifyUnadmittedStart { admitted ->
            currentCoroutineContext().cancel()
            try {
                awaitCancellation()
            } finally {
                admitted()
            }
        }
    }

    @Test
    fun `runtime shutdown rejects a suspended Start once and discards its record`() = runTest {
        val ports = Ports(outgoing = { admitted ->
            try {
                awaitCancellation()
            } finally {
                admitted()
            }
        })
        val runtime = start(ports)
        val action = ActionID("start")
        try {
            check(runtime.submit(Input.Request(Action.Start(id, line, party), action)))
            runCurrent()
            assertEquals(Lifecycle.Dialing, runtime.lifecycles().getValue(id))
            assertTrue(ports.rejections.isEmpty())

            runtime.close()
            assertEquals(listOf(Effect.RejectAction(id, action, unadmittedError)), ports.rejections)
            assertTrue(ports.settlements.isEmpty())
            assertTrue(runtime.state.value.calls.isEmpty())
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `runtime shutdown preserves admission already reported by the session`() = runTest {
        val admission = CompletableDeferred<() -> Unit>()
        val ports = Ports(outgoing = { admitted ->
            admission.complete(admitted)
            awaitCancellation()
        })
        val runtime = start(ports)
        val action = ActionID("start")
        try {
            check(runtime.submit(Input.Request(Action.Start(id, line, party), action)))
            runCurrent()
            val admitted = admission.await()
            admitted()
            admitted()
            // Shut down before the runtime consumes the admission notification.
            runtime.close()
            assertEquals(listOf(action), ports.settlements)
            assertTrue(ports.rejections.isEmpty())
            assertTrue(runtime.state.value.calls.isEmpty())
        } finally {
            runtime.close()
        }
    }

    @Test
    fun `a cancelled Start releases an ended record retained beyond its expiry`() = runTest {
        val session = CompletableDeferred<Unit>()
        val ports = Ports(outgoing = {
            session.await()
            Outcome.Success(Unit)
        })
        val runtime = start(ports, policy = shortRetention)
        val action = ActionID("start")
        try {
            ports.mediaRelease.complete(Unit)
            check(runtime.submit(Input.Request(Action.Start(id, line, party), action)))
            runCurrent()
            runtime.endFromServer(id)
            advanceTimeBy(1_000)
            runtime.endFromServer(other)
            runCurrent()
            assertEquals(EndReason.RemoteEnded, (runtime.lifecycles().getValue(id) as Lifecycle.Ended).reason)

            session.cancel()
            runCurrent()
            assertFalse(id in runtime.state.value.calls)
            val rejection = Effect.RejectAction(id, action, CallError.InvalidTransition(LifecycleKind.ENDING))
            assertEquals(listOf(rejection), ports.rejections)
            assertEquals(listOf("media"), ports.cleanup)
        } finally {
            runtime.close()
        }
    }

    private suspend fun TestScope.verifyUnadmittedStart(
        outgoing: suspend (() -> Unit) -> Outcome<Unit, SystemFailure>,
    ) {
        val ports = Ports(outgoing = outgoing)
        val runtime = start(ports, policy = shortRetention)
        val action = ActionID("start")
        try {
            ports.mediaRelease.complete(Unit)
            check(runtime.submit(Input.Request(Action.Start(id, line, party), action)))
            runCurrent()
            assertEquals(listOf(Effect.RejectAction(id, action, unadmittedError)), ports.rejections)
            assertTrue(ports.settlements.isEmpty())
            assertEquals(EndReason.Failed(unadmittedError), (runtime.lifecycles().getValue(id) as Lifecycle.Ended).reason)
            assertEquals(setOf(id), runtime.state.value.systemRemovalNotApplicable)
            assertEquals(listOf("media"), ports.cleanup)

            advanceTimeBy(1_000)
            runtime.endFromServer(other)
            runCurrent()
            assertFalse(id in runtime.state.value.calls)
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
            assertTrue(id in runtime.state.value.calls)
            advanceTimeBy(1)
            runCurrent()
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
        private val outgoing: (suspend (() -> Unit) -> Outcome<Unit, SystemFailure>)? = null,
        private val activate: () -> Unit = { error("Unexpected activation") },
        private val placement: CompletableDeferred<Unit>? = null,
    ) : SystemPort, AuthorityPort, MediaPort, PresentationPort {
        override val platform = Platform.ANDROID
        val admissions = mutableMapOf<CallID, () -> Unit>()
        val sessions = mutableMapOf<CallID, CompletableDeferred<Outcome<Unit, SystemFailure>>>()
        val retired = mutableSetOf<CallID>()
        val cleanup = mutableListOf<String>()
        val mediaRelease = CompletableDeferred<Unit>()
        val systemRemoval = CompletableDeferred<Outcome<Unit, SystemFailure>>()
        val removalByCall = mutableMapOf<CallID, CompletableDeferred<Outcome<Unit, SystemFailure>>>()
        val settlements = mutableListOf<ActionID>()
        val rejections = mutableListOf<Effect.RejectAction>()
        val releaseRequest = CompletableDeferred<Effect.ReleasePermit>()
        val permitReleased = CompletableDeferred<Unit>()

        override suspend fun reportIncoming(
            call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            val done = CompletableDeferred<Outcome<Unit, SystemFailure>>()
            sessions[call.id] = done
            admissions[call.id] = admitted
            try {
                return done.await()
            } finally {
                withContext(NonCancellable) { delay(1) }
                retired += call.id
            }
        }

        override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
            cleanup += "system"
            return (removalByCall[call.id] ?: systemRemoval).await()
                .also { sessions.getValue(call.id).complete(Outcome.Success(Unit)) }
        }

        override suspend fun close(request: Effect.CloseMedia) {
            cleanup += "media"
            mediaRelease.await()
        }

        override suspend fun startOutgoing(
            call: Call, request: Effect.NativeStart, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> = checkNotNull(outgoing) { "Unexpected Start" }(admitted)
        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> = error("Unexpected control")
        override suspend fun setActive(request: Effect.SetActive) = activate()
        override fun settle(result: Effect.SettleAction) {
            settlements += result.actionID
        }
        override fun reject(result: Effect.RejectAction) {
            check(outgoing != null) { "Unexpected rejection" }
            rejections += result
        }
        override fun completeEnd(result: Effect.CompleteEnd): Unit = error("Unexpected local End")
        override suspend fun place(call: Call, request: Effect.RequestPlacement): Outcome<Unit, CallError.PlacementFailed> {
            check(outgoing != null) { "Unexpected placement" }
            placement?.await()
            return Outcome.Success(Unit)
        }
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
        fun bridgeFixture(name: String): List<JsonObject> =
            Wire.json.parseToJsonElement(File(System.getProperty("spec.bridge"), "valid/$name.json").readText())
                .jsonArray.map { it.jsonObject }

        fun JsonObject.text(field: String): String = getValue(field).jsonPrimitive.content

        val id = CallID("incoming")
        val other = CallID("other")
        val line = CallingLine(AccountID("account"), LineID("personal"), "Personal")
        val party = Party(PartyID("alice"), Handle.Opaque("sip:alice@example.test"), "Alice")
        val configuration = Configuration(Budgets(), OutgoingMedia.WHEN_PROVIDED, ConnectionAuthority.APPLICATION, 1, true)
        val shortRetention = configuration.copy(budgets = Budgets().withRetention(RetentionBudget(lifetime = 1.seconds)))
        val unadmittedError = CallError.SystemFailed(SystemFailure(
            Platform.ANDROID, SystemOperation.START, detail = SystemFailureDetail.SESSION_ENDED_BEFORE_ADMISSION,
        ))

        fun CallRuntime.lifecycles(): Map<CallID, Lifecycle> = state.value.calls.mapValues { it.value.lifecycle }
        fun CallRuntime.invite(id: CallID, expiresAt: Instant? = null) {
            check(submit(Input.Incoming(id, EventID(id.value), line, party, expiresAt)))
        }

        fun CallRuntime.endFromServer(id: CallID) {
            check(submit(Input.RemoteEnd(EndTarget.Canonical(id), EventID("end-${id.value}"), EndReason.RemoteEnded)))
        }
    }
}
