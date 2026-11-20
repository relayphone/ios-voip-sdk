package com.relayphone.voip.expo

import com.relayphone.voip.*
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.runtime.SystemPort
import java.io.File
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
internal class CallBindingTest {
    private val fixtures = File(System.getProperty("spec.bridge"))
    private val commands = fixture("commands.json")
    private val invitations = commands.filter { it["operation"] == JsonPrimitive("reportIncoming") && it.text("kind") == "command" }
    private val end = commands.last { it["operation"] == JsonPrimitive("perform") && it.text("kind") == "command" }
    private val answer = message("command", "operation" to encode("perform"), "input" to buildJsonObject {
        put("id", end.obj("input").getValue("id"))
        put("action", message("answer"))
    }).toString()
    private val id = invitations.first().obj("input").read<CallID>("callID")

    @Test
    fun `push shares deduplication with foreground intake and keeps its original expiry`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        val push = PushEnvelope.decode(pushFixture, Instant.parse("2026-11-18T00:00:44.000Z"),
            Instant.fromEpochMilliseconds(0)) as PushEnvelope.Invitation
        val expired = push.copy(input = push.input.copy(ringDeadline = Instant.fromEpochMilliseconds(0)))
        assertEquals(IncomingRefusal.Expired, (binding.reportPush(expired) as IncomingResult.Refused).reason)
        assertEquals(0, telecom.reports)
        val outcomes = mutableListOf<JsonObject>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            binding.pushOutcomes.collect { outcomes.add(it) }
        }
        assertEquals(IncomingResult.Admitted(push.input.callID), binding.reportPush(push))
        val foreground = invitations.first()
        val foregroundInput = JsonObject(foreground.obj("input") + ("eventID" to encode(push.input.eventID)))
        val duplicate = binding.reply(JsonObject(foreground + ("input" to foregroundInput)).toString()).obj("value")
        assertEquals("duplicate", duplicate.text("kind"))
        assertEquals(push.input.callID.value, duplicate.obj("original").text("callID"))
        val extended = push.input.copy(ringDeadline = Instant.fromEpochMilliseconds(30_000))
        assertTrue(binding.reportPush(push.copy(input = extended)) is IncomingResult.Duplicate)
        val repeat = binding.reportPush(push.copy(input = extended.copy(eventID = EventID("fresh"))))
        assertTrue((repeat as IncomingResult.Refused).reason is IncomingRefusal.CallAlreadyExists)
        assertEquals(1, telecom.reports)
        runCurrent()
        assertEquals(listOf(push.input.eventID.value), outcomes.map { it.text("eventId") })
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals("unanswered", binding.state.snapshot().getValue("calls").jsonArray.single().jsonObject
            .obj("lifecycle").obj("reason").text("kind"))
    }

    @Test
    fun `push bridge replies and snapshot agree without exposing token material`() = runTest {
        val binding = binding(FakeSystem())
        val health = readFixture("valid/pushHealthUnknown.json").obj("value")
        binding.state.updatePush(health, "requiresPermission")
        val snapshot = BridgeWire.decode(binding.state.snapshot().toString(), "snapshot")
        assertEquals(health, snapshot.obj("pushHealth"))
        assertEquals(health, binding.reply("""{"kind":"command","operation":"push.health"}""").obj("value"))
        assertEquals(health.obj("registration"),
            binding.reply("""{"kind":"command","operation":"push.registration"}""").obj("value"))
        val fullScreen = snapshot.getValue("records").jsonArray.map { it.jsonObject.obj("value") }
            .single { it.text("feature") == "fullScreenIncoming" }
        assertEquals("requiresPermission", fullScreen.obj("availability").text("reason"))
    }

    @Test
    fun `native decisions match fixtures and local End is acknowledged only once`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        val frames = mutableListOf<JsonObject>()
        val receive: (String) -> Unit = { frames.add(BridgeWire.decode(it, "frame")) }
        val initial = binding.state.attach(receive)
        for (request in invitations) assertEquals(request, binding.commandReply(request.toString()))
        assertEquals(1, telecom.reports)

        val performed = binding.reply(answer).obj("value")
        assertEquals("performed", performed.text("kind"))
        val answerFrame = frames.single { it["receipt"]?.jsonObject?.obj("action")?.text("kind") == "answer" }
        assertEquals(answerFrame.obj("receipt"), performed.obj("receipt"))
        assertEquals("app", answerFrame.obj("receipt").text("origin"))
        assertTrue(performed.obj("cursor").read<Long>("sequence") >= answerFrame.obj("cursor").read<Long>("sequence"))

        val result = binding.reply(end.toString()).obj("value").obj("outcome")
        assertEquals(result, binding.reply(end.toString()).obj("value").obj("outcome"))
        val endFrame = frames.single { it["receipt"]?.jsonObject?.obj("action")?.text("kind") == "end" }
        assertEquals(result.obj("receipt").text("actionID"), endFrame.obj("receipt").text("actionID"))
        assertEquals((1L..frames.size.toLong()).toList(), frames.map { it.obj("cursor").read<Long>("sequence") })
        assertEquals(initial.obj("cursor").text("epoch"), frames.last().obj("cursor").text("epoch"))

        binding.state.detach(receive)
        binding.state.detach(receive)
        val beforeCleanup = frames.size
        val pending = binding.state.attach(receive)
        assertEquals(emptyList<CallID>(), pending.read<List<CallID>>("completed"))
        assertEquals("ended", pending.getValue("calls").jsonArray.single().jsonObject.obj("lifecycle").text("kind"))
        telecom.removal.complete(Unit)
        runCurrent()
        assertEquals(listOf("cleanup", "terminalCompleted"), frames.drop(beforeCleanup).map { it.text("kind") })
        assertEquals(listOf(id), binding.state.snapshot().read<List<CallID>>("completed"))
    }

    @Test
    fun `server and admission failures retain their types and Android diagnostic code`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        binding.commandReply(invitations.first().toString())
        val failed = commands.single { it["operation"] == JsonPrimitive("receive") && it.text("kind") == "command" && it.obj("input").text("kind") == "ended" }
        assertEquals("applied", binding.reply(failed.toString()).obj("value").text("kind"))
        val expected = commands.single { it["operation"] == JsonPrimitive("perform") &&
            it["result"]?.jsonObject?.get("value")?.jsonObject?.get("outcome")?.jsonObject?.get("kind") == JsonPrimitive("alreadyEnded") }
        assertEquals(expected.obj("result").obj("value").obj("outcome"), binding.reply(end.toString()).obj("value").obj("outcome"))

        val refusal = FakeSystem(SystemFailure(Platform.ANDROID, SystemOperation.ADMISSION, 42))
        val denied = binding(refusal).reply(invitations.first().toString())
        assertEquals(fixture("admissions.json").last().obj("result"), denied)
    }

    @Test
    fun `a journal gap publishes a frame covered by the authoritative replacement snapshot`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        binding.commandReply(invitations.first().toString())
        var recovered: JsonObject? = null
        val attached = binding.state.attach {
            val frame = BridgeWire.decode(it, "frame")
            recovered = binding.state.snapshot().also { assertEquals(frame.obj("cursor"), it.obj("cursor")) }
        }
        repeat(80) { assertTrue(telecom.submit(Input.AdapterIdle)) }
        runCurrent()
        val snapshot = requireNotNull(recovered)
        assertNotEquals(attached.obj("cursor").text("epoch"), snapshot.obj("cursor").text("epoch"))
        assertEquals(attached["calls"], snapshot["calls"])
    }

    private fun TestScope.binding(telecom: FakeSystem) = CallBinding(
        backgroundScope, invitations.first().obj("input").read("line"),
        MonotonicClock { Instant.fromEpochMilliseconds(testScheduler.currentTime) },
        NativeCallMedia.Registration(null, emptyList(), null),
    ) { submit ->
        telecom.submit = submit
        CallSystem(telecom, telecom::answer)
    }

    private suspend fun CallBinding.reply(request: String): JsonObject =
        BridgeWire.decode(command(request, negotiated = true) { _, _ -> error("Unexpected permission request") }, "reply")
            .obj("result")

    private suspend fun CallBinding.commandReply(request: String): JsonObject {
        val command = BridgeWire.decode(request, "command")
        val expected = commands[commands.indexOf(command) + 1].obj("result")
        assertEquals(expected, reply(request))
        return command
    }

    private fun fixture(name: String) = Wire.json.parseToJsonElement(fixtures.resolve(name).readText()).jsonArray
        .map { it.jsonObject }

    private class FakeSystem(private val admissionFailure: SystemFailure? = null) : SystemPort {
        override val platform = Platform.ANDROID
        override val answerDeadline = 5.seconds
        val removal = CompletableDeferred<Unit>()
        private val session = CompletableDeferred<Unit>()
        lateinit var submit: (Input) -> Boolean
        var reports = 0
        private val answer = CompletableDeferred<Outcome<Unit, CallError>>()
        private val action = ActionID("answer-a")

        suspend fun answer(id: CallID): Outcome<ActionReceipt, CallError> {
            val request = Action.Answer(id)
            check(submit(Input.Request(request, action)))
            return when (val outcome = answer.await()) {
                is Outcome.Success -> Outcome.Success(ActionReceipt(action, request, ActionOrigin.APP))
                is Outcome.Failure -> outcome
            }
        }

        override suspend fun reportIncoming(
            call: Call, request: Effect.ReportIncoming, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            reports++
            if (admissionFailure != null) return Outcome.Failure(admissionFailure)
            admitted()
            session.await()
            return Outcome.Success(Unit)
        }

        override suspend fun remove(call: Call, request: Effect.RequestRemoval): Outcome<Unit, SystemFailure> {
            removal.await()
            session.complete(Unit)
            return Outcome.Success(Unit)
        }

        override fun settle(result: Effect.SettleAction) {
            check(submit(Input.AnswerConfirmed(result.callID, result.actionID)))
        }

        override fun completeAnswer(confirmation: Input.AnswerConfirmed, result: Outcome<Unit, CallError>) {
            answer.complete(result)
        }

        override fun reject(result: Effect.RejectAction) {
            if (result.actionID == action) answer.complete(Outcome.Failure(result.error))
        }

        override fun completeEnd(result: Effect.CompleteEnd) = Unit
        override suspend fun startOutgoing(call: Call, request: Effect.NativeStart, admitted: () -> Unit) = error("Unexpected Start")
        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> = error("Unexpected control")
        override suspend fun setActive(request: Effect.SetActive) = Unit
    }
}
