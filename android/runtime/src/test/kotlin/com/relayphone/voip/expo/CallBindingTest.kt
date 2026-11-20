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
import kotlinx.coroutines.async
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
    private val placementReceiver = PlacementReceiver {}
    private val invitations = commands.filter { it["operation"] == JsonPrimitive("reportIncoming") && it.text("kind") == "command" }
    private val end = commands.last { it["operation"] == JsonPrimitive("perform") && it.text("kind") == "command" }
    private val answer = message("command", "operation" to encode("perform"), "input" to buildJsonObject {
        put("id", end.obj("input").getValue("id"))
        put("action", message("answer"))
    }).toString()
    private val id = invitations.first().obj("input").read<CallID>("callID")
    private val start = commands.first()
    private val outgoing = fixture("android-outgoing.json")
    private val placementFixtures = fixture("placement.json")

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

    @Test
    fun `start confirms admission after atomic placement and reports connect hold resume and remote end`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        val frames = mutableListOf<JsonObject>()
        val controls = mutableListOf<JsonObject>()
        val receiver = PlacementReceiver { controls.add(BridgeWire.decode(it)) }
        binding.state.attach { frames.add(BridgeWire.decode(it, "frame")) }
        assertEquals(placementFixtures[1].obj("result"), binding.reply(placementFixtures[0].toString(), receiver))

        val starting = async { binding.reply(start.toString(), receiver) }
        runCurrent()
        val requested = controls.single()
        val placement = placementFixtures[2]
        assertEquals(placement.obj("request"), requested.obj("request"))
        assertEquals(placement["generation"], requested["generation"])
        assertEquals(10_000L, requested.read<Long>("remainingMs"))
        assertEquals(outgoing[1].obj("result"), binding.reply(outgoing[0].toString(), receiver))
        assertEquals("placing", binding.lifecycle("outbound-a"))
        assertEquals("unprovided", binding.call("outbound-a").obj("media").text("preparation"))
        val settling = settlement(requested, "remote-a")
        assertEquals(message("accepted"), binding.reply(settling, receiver).obj("value"))
        assertEquals(message("stale"), binding.reply(settling, receiver).obj("value"))
        runCurrent()
        assertEquals("dialing", binding.lifecycle("outbound-a"))
        assertEquals("prepared", binding.call("outbound-a").obj("media").text("preparation"))
        assertFalse(starting.isCompleted)
        val connected = commands.first { it["operation"] == JsonPrimitive("receive") }
        binding.commandReply(connected.toString())
        assertEquals("dialing", binding.lifecycle("outbound-a"))
        telecom.startAdmission.complete(Unit)
        assertPerformed(commands[1], starting.await(), frames)
        runCurrent()
        assertEquals("connected", binding.lifecycle("outbound-a"))
        assertEquals("remote-a", binding.call("outbound-a").text("remoteID"))

        for (index in listOf(2, 4)) {
            assertPerformed(outgoing[index + 1], binding.reply(outgoing[index].toString(), receiver), frames)
            assertEquals(outgoing[index].obj("input").obj("action").read<Boolean>("held"), binding.call("outbound-a").read<Boolean>("held"))
        }
        assertEquals(listOf(true, false), telecom.holds)
        val remoteEnd = """{"kind":"command","operation":"receive","input":{"kind":"ended","eventID":"remote-end","target":{"kind":"remote","id":"remote-a"},"reason":{"kind":"remoteEnded"}}}"""
        assertEquals(message("applied"), binding.reply(remoteEnd).obj("value"))
        assertEquals("ended", binding.lifecycle("outbound-a"))
        assertEquals("remoteEnded", binding.call("outbound-a").obj("lifecycle").obj("reason").text("kind"))
        assertEquals(3, frames.count { it.text("kind") == "actionPerformed" })
    }

    @Test
    fun `native admission refusal rejects start and discards early connection`() = runTest {
        val telecom = FakeSystem(startFailure = SystemFailure(Platform.ANDROID, SystemOperation.START, 42))
        val binding = binding(telecom)
        val controls = mutableListOf<JsonObject>()
        val receiver = PlacementReceiver { controls.add(BridgeWire.decode(it)) }
        binding.reply(placementFixtures[0].toString(), receiver)
        val starting = async { binding.reply(start.toString(), receiver) }
        runCurrent()
        val connected = commands.first { it["operation"] == JsonPrimitive("receive") }
        assertEquals(message("buffered"), binding.reply(connected.toString()).obj("value"))
        assertEquals(message("accepted"), binding.reply(settlement(controls.single(), "remote-a"), receiver).obj("value"))
        telecom.startAdmission.complete(Unit)
        assertEquals(outgoing.last().obj("result"), starting.await())
        runCurrent()
        assertEquals("ended", binding.lifecycle("outbound-a"))
    }

    @Test
    fun `replacement, expiry and a missing handler reject only the matching start`() = runTest {
        val telecom = FakeSystem()
        val binding = binding(telecom)
        val controls = mutableListOf<JsonObject>()
        val receiver = PlacementReceiver { controls.add(BridgeWire.decode(it)) }
        binding.reply(placementFixtures[0].toString(), receiver)
        val first = async { binding.reply(start.toString(), receiver) }
        runCurrent()
        val replaced = controls.single()
        binding.reply(placementFixtures[3].toString(), receiver)
        assertEquals("replaced", controls.last().text("reason"))
        assertEquals("cancelled", first.await().obj("error").text("cause"))
        assertEquals(message("stale"), binding.reply(settlement(replaced, "remote-a"), receiver).obj("value"))

        val next = async { binding.reply(start.toString().replace("outbound-a", "next"), receiver) }
        runCurrent()
        val expired = controls.last()
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals("deadlineExceeded", controls.last().text("reason"))
        assertEquals("placement", next.await().obj("error").text("stage"))
        assertEquals(message("stale"), binding.reply(settlement(expired, "remote-a"), receiver).obj("value"))

        binding.detachPlacement(receiver)
        val noHandler = binding.reply(start.toString().replace("outbound-a", "without-handler"), receiver)
        assertEquals("deadlineExceeded", noHandler.obj("error").text("kind"))
        assertEquals(0, telecom.starts)
    }

    private fun CallBinding.call(id: String): JsonObject =
        state.snapshot().getValue("calls").jsonArray.map { it.jsonObject }.single { it.text("id") == id }

    private fun CallBinding.lifecycle(id: String) = call(id).obj("lifecycle").text("kind")

    private fun settlement(request: JsonObject, remoteID: String): String {
        val template = placementFixtures.first { it["operation"] == JsonPrimitive("placement.settle") }
        val input = template.obj("input")
        return JsonObject(template + ("input" to JsonObject(input + mapOf(
            "generation" to request.getValue("generation"), "actionID" to request.getValue("actionID"),
            "result" to buildJsonObject { put("ok", true); put("value", message("placed", "remoteID" to encode(remoteID))) },
        )))).toString()
    }

    private fun assertPerformed(fixture: JsonObject, actual: JsonObject, frames: List<JsonObject>) {
        val expected = fixture.obj("result").obj("value").obj("receipt")
        val confirmation = actual.obj("value")
        val receipt = confirmation.obj("receipt")
        assertEquals(expected - "actionID", receipt - "actionID")
        val frame = frames.single { it["receipt"] == receipt }
        assertTrue(confirmation.obj("cursor").read<Long>("sequence") >= frame.obj("cursor").read<Long>("sequence"))
    }

    private fun TestScope.binding(telecom: FakeSystem) = CallBinding(
        backgroundScope, invitations.first().obj("input").read("line"),
        MonotonicClock { Instant.fromEpochMilliseconds(testScheduler.currentTime) },
        NativeCallMedia.Registration(null, emptyList(), null),
    ) { submit ->
        telecom.submit = submit
        CallSystem(telecom, telecom::answer)
    }

    private suspend fun CallBinding.reply(request: String, receiver: PlacementReceiver = placementReceiver): JsonObject =
        BridgeWire.decode(command(request, true, receiver) { _, _ -> error("Unexpected permission request") }, "reply")
            .obj("result")

    private suspend fun CallBinding.commandReply(request: String): JsonObject {
        val command = BridgeWire.decode(request, "command")
        val expected = commands[commands.indexOf(command) + 1].obj("result")
        assertEquals(expected, reply(request))
        return command
    }

    private fun fixture(name: String) = Wire.json.parseToJsonElement(fixtures.resolve(name).readText()).jsonArray
        .map { it.jsonObject }

    private class FakeSystem(
        private val admissionFailure: SystemFailure? = null, private val startFailure: SystemFailure? = null,
    ) : SystemPort {
        override val platform = Platform.ANDROID
        override val answerDeadline = 5.seconds
        val removal = CompletableDeferred<Unit>()
        val startAdmission = CompletableDeferred<Unit>()
        val holds = mutableListOf<Boolean>()
        private val session = CompletableDeferred<Unit>()
        lateinit var submit: (Input) -> Boolean
        var reports = 0
        var starts = 0
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
            if (call.direction == Direction.INCOMING) removal.await()
            session.complete(Unit)
            return Outcome.Success(Unit)
        }

        override fun settle(result: Effect.SettleAction) {
            if (result.actionID == action) check(submit(Input.AnswerConfirmed(result.callID, result.actionID)))
        }

        override fun completeAnswer(confirmation: Input.AnswerConfirmed, result: Outcome<Unit, CallError>) {
            answer.complete(result)
        }

        override fun reject(result: Effect.RejectAction) {
            if (result.actionID == action) answer.complete(Outcome.Failure(result.error))
        }

        override fun completeEnd(result: Effect.CompleteEnd) = Unit
        override suspend fun startOutgoing(
            call: Call, request: Effect.NativeStart, admitted: () -> Unit,
        ): Outcome<Unit, SystemFailure> {
            starts++
            startAdmission.await()
            if (startFailure != null) return Outcome.Failure(startFailure)
            admitted()
            session.await()
            return Outcome.Success(Unit)
        }

        override suspend fun apply(request: Effect.Apply): Outcome<Unit, CallError> {
            holds.add((request.action as Action.Hold).held)
            return Outcome.Success(Unit)
        }
        override suspend fun setActive(request: Effect.SetActive) = Unit
    }
}
