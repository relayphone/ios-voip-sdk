package com.relayphone.voip.expo

import com.relayphone.voip.*
import com.relayphone.voip.runtime.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*

internal class CallBinding(
    scope: CoroutineScope,
    private val line: CallingLine?,
    clock: MonotonicClock,
    private val registration: NativeCallMedia.Registration,
    presentation: PresentationPort = PresentationPort {},
    connect: suspend ((Input) -> Boolean) -> CallSystem,
) : AuthorityPort {
    val state = BridgeState(if (registration.media == null) Owner.APPLICATION else Owner.NATIVE, registration.authority != null)
    val pushOutcomes = MutableSharedFlow<JsonObject>(extraBufferCapacity = 16)
    private val placement = PlacementChannel(clock) { runtime?.snapshot()?.state }
    private val ends = mutableMapOf<ActionID, CompletableDeferred<Outcome<EndResult, CallError>>>()
    private val processed = MutableStateFlow<RuntimeCursor?>(null)
    @Volatile private var runtime: CallRuntime? = null
    private val ready = scope.async {
        val telecom = connect { runtime?.submit(it) ?: false }
        val system = object : SystemPort by telecom.port {
            override fun reject(result: Effect.RejectAction) {
                telecom.port.reject(result)
                ends[result.actionID]?.complete(Outcome.Failure(result.error))
            }

            override fun completeEnd(result: Effect.CompleteEnd) {
                telecom.port.completeEnd(result)
                ends[result.actionID]?.complete(Outcome.Success(result.result))
            }
        }
        val result = CallRuntime.start(Configuration(Budgets(), OutgoingMedia.DURING_PLACEMENT, ConnectionAuthority.APPLICATION,
            1, false), scope, system, this@CallBinding, registration.media ?: DefaultMedia, presentation, clock)
        val calls = (result as Outcome.Success).value
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            calls.observe().collect { observation ->
                state.accept(observation)
                when (observation) {
                    is RuntimeFrame -> processed.value = observation.cursor
                    is RuntimeObservation.Snapshot -> processed.value = observation.snapshot.cursor
                    RuntimeObservation.ResyncRequired -> Unit
                }
            }
        }
        runtime = calls
        registration.observers.forEach { it(calls) }
        calls to telecom
    }

    override suspend fun placeCall(call: Call, request: Effect.RequestPlacement): PlacementResult =
        placement.request(call, request)

    override suspend fun claim(request: Effect.RequestClaim): AnswerDecision =
        registration.authority?.claim(request) ?: AnswerDecision.Allow(AttemptID(UUID.randomUUID().toString()))
    override suspend fun reconcile(request: Effect.Reconcile): Reconciliation =
        registration.authority?.reconcile(request) ?: Reconciliation.Unknown
    override suspend fun release(request: Effect.ReleasePermit) { registration.authority?.release(request) }

    fun detachPlacement(receiver: PlacementReceiver) = placement.detach(receiver)

    suspend fun command(
        source: String, negotiated: Boolean, receiver: PlacementReceiver,
        permission: suspend (MediaPermission, Boolean) -> Reply,
    ): String {
        val command = BridgeWire.decode(source, "command")
        val operation = command.text("operation")
        val input = command["input"]?.jsonObject ?: JsonObject(emptyMap())
        val result = when {
            !negotiated -> failed(CallError.BridgeUnavailable)
            operation == "push.health" || operation == "push.registration" -> ok(state.push(operation))
            operation == "permissions.read" || operation == "permissions.request" -> {
                val kind = if (input.text("kind") == "microphone") MediaPermission.MICROPHONE else MediaPermission.CAMERA
                permission(kind, operation == "permissions.request")
            }
            operation == "placement.attach" -> {
                placement.attach(receiver, input.read("generation"), input.read("attached"))
                ok(JsonNull)
            }
            else -> callCommand(operation, input, receiver)
        }
        return envelope("reply", result, "operation" to JsonPrimitive(operation)).toString()
    }

    suspend fun reportPush(push: PushEnvelope.Invitation): IncomingResult? {
        val (calls) = ready.await()
        val result = (calls.reportIncoming(push.input) as? Outcome.Success)?.value
        if (result is IncomingResult.Refused &&
            (result.reason is IncomingRefusal.CallAlreadyExists || result.reason == IncomingRefusal.EventAlreadyUsed)
        ) return result
        if (result is IncomingResult.Decision) {
            if (result is IncomingResult.Admitted)
                NativeCallMedia.recordCredential(result.callID, push.credentialRef)
            settledCursor(calls)
            pushOutcomes.tryEmit(buildJsonObject {
                put("eventId", encode(push.input.eventID))
                put("serverCallId", encode(push.input.callID))
                put("outcome", incoming(result))
            })
        }
        return result
    }

    suspend fun notificationAction(id: CallID, answer: Boolean): Boolean {
        val (calls, telecom) = ready.await()
        if (answer) return telecom.notificationAnswer(id) is Outcome.Success
        return calls.submit(Input.Request(Action.End(id), ActionID(UUID.randomUUID().toString()), origin = ActionOrigin.SYSTEM))
    }

    private suspend fun callCommand(operation: String, input: JsonObject, receiver: PlacementReceiver): Reply {
        val (calls, telecom) = try {
            ready.await()
        } catch (_: SecurityException) {
            val kind = if (operation == "start") SystemOperation.START else SystemOperation.ADMISSION
            return failed(CallError.SystemFailed(SystemFailure(Platform.ANDROID, kind)))
        }
        return when (operation) {
            "start" -> {
                if (input.read<Boolean>("video")) return failed(CallError.Unsupported(Feature.VIDEO))
                if (line == null || input.read<LineID>("lineID") != line.lineID) {
                    return failed(CallError.InvalidConfiguration(ConfigurationField.PLACEMENT))
                }
                performed(calls, calls.startOutgoing(input.read("id"), line, input.read("parties")))
            }
            "placement.settle" -> {
                val accepted = placement.settle(calls, receiver, input)
                ok(message(if (accepted) "accepted" else "stale"))
            }
            "perform" -> {
                val id = input.read<CallID>("id")
                val action = input.obj("action")
                when (action.text("kind")) {
                    "answer" -> performed(calls, telecom.answer(id))
                    "end" -> end(calls, id)
                    "hold" -> performed(calls, calls.setHeld(id, action.read("held")))
                    "mute" -> failed(CallError.Unsupported(Feature.MUTE))
                    "join" -> failed(CallError.Unsupported(Feature.PREVIEW))
                    "video" -> failed(CallError.Unsupported(Feature.VIDEO))
                    "tones" -> failed(CallError.Unsupported(Feature.TONES))
                    else -> failed(CallError.BridgeUnavailable)
                }
            }
            "receive" -> calls.receive(Wire.json.decodeFromJsonElement<RemoteEvent>(input))
                .reply { settledCursor(calls); message(encode(it).jsonPrimitive.content) }
            "bindRemote" -> calls.bindRemote(input.read("id"), input.read("remoteID")).reply { settledCursor(calls); JsonNull }
            "reportIncoming" -> {
                if (line == null || input.read<CallingLine>("line") != line) {
                    return failed(CallError.InvalidConfiguration(ConfigurationField.PLACEMENT))
                }
                calls.reportIncoming(Input.Incoming(input.read("callID"), input.read("eventID"), line, input.read("party")))
                    .reply { settledCursor(calls); incoming(it) }
            }
            else -> error("Unknown bridge operation")
        }
    }

    private suspend fun performed(calls: CallRuntime, result: Outcome<ActionReceipt, CallError>): Reply =
        result.reply { message("performed", "receipt" to encode(it), "cursor" to settledCursor(calls)) }

    private suspend fun end(calls: CallRuntime, id: CallID): Reply {
        val actionID = ActionID(UUID.randomUUID().toString())
        val result = CompletableDeferred<Outcome<EndResult, CallError>>()
        ends[actionID] = result
        return try {
            if (!calls.submit(Input.Request(Action.End(id), actionID))) return failed(CallError.BridgeUnavailable)
            result.await().reply { message("end", "cursor" to settledCursor(calls), "outcome" to encode(it)) }
        } finally {
            ends.remove(actionID)
        }
    }

    private suspend fun settledCursor(calls: CallRuntime): JsonObject {
        val head = calls.snapshot().cursor
        processed.first {
            it != null && it.epoch == calls.snapshot().cursor.epoch &&
                (it.epoch != head.epoch || it.sequence >= head.sequence)
        }
        return state.cursor()
    }
}

internal data class CallSystem(
    val port: SystemPort,
    val answer: suspend (CallID) -> Outcome<ActionReceipt, CallError>,
    val notificationAnswer: suspend (CallID) -> Outcome<ActionReceipt, CallError> = answer,
)

private fun incoming(result: IncomingResult): JsonObject {
    val id = "callID" to encode(result.callID)
    return when (result) {
        is IncomingResult.Duplicate -> message("duplicate", "original" to incoming(result.original))
        is IncomingResult.Admitted -> message("admitted", id)
        is IncomingResult.Refused -> when (val reason = result.reason) {
            is IncomingRefusal.SystemFailed -> message("refused", id, "error" to encode<CallError>(CallError.SystemFailed(reason.failure)))
            is IncomingRefusal.Previewed -> message("previewed", id, "reason" to encode(reason.reason))
            is IncomingRefusal.Ended -> message("ended", id, "reason" to encode(reason.reason))
            is IncomingRefusal.CallAlreadyExists -> message("refused", id, "error" to encode<CallError>(CallError.InvalidTransition(reason.state)))
            IncomingRefusal.Expired, IncomingRefusal.EventAlreadyUsed -> message("hidden", id)
        }
    }
}

private object DefaultMedia : MediaPort {
    override suspend fun prepare(request: Effect.PrepareMedia) = Outcome.Success(Unit)
    override suspend fun close(request: Effect.CloseMedia) = Unit
    override suspend fun sendTones(request: Effect.SendTones) = Outcome.Failure(CallError.Unsupported(Feature.TONES))
}

internal typealias Reply = Outcome<JsonElement, CallError>
internal fun ok(value: JsonElement): Reply = Outcome.Success(value)
internal fun failed(error: CallError): Reply = Outcome.Failure(error)
private inline fun <T> Outcome<T, CallError>.reply(convert: (T) -> JsonElement): Reply = when (this) {
    is Outcome.Failure -> this
    is Outcome.Success -> ok(convert(value))
}

internal fun envelope(kind: String, reply: Reply, vararg fields: Pair<String, JsonElement>) =
    message(kind, *fields, "result" to buildJsonObject {
        when (reply) {
            is Outcome.Success -> { put("ok", true); put("value", reply.value) }
            is Outcome.Failure -> { put("ok", false); put("error", encode(reply.error)) }
        }
    })
