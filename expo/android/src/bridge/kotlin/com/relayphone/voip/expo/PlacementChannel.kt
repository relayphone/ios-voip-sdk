package com.relayphone.voip.expo

import com.relayphone.voip.*
import com.relayphone.voip.runtime.CallRuntime
import com.relayphone.voip.runtime.MonotonicClock
import java.time.format.DateTimeFormatterBuilder
import kotlin.time.Clock
import kotlin.time.Duration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.*

internal class PlacementReceiver(val send: (String) -> Unit) {
    var generation = 0L
    var attached = false
    var retired = false
}

/** Commands and their runtime callbacks share the binding's dispatcher. */
internal class PlacementChannel(private val clock: MonotonicClock, private val state: () -> State?) {
    private var receiver: PlacementReceiver? = null
    private val pending = mutableMapOf<ActionID, Pending>()

    fun attach(next: PlacementReceiver, generation: Long, attached: Boolean) {
        if (next.retired || generation <= next.generation) return
        val previous = receiver
        if (previous !== next) previous?.retired = true
        next.generation = generation
        next.attached = attached
        receiver = next
        cancelAll(if (attached) "replaced" else "detached")
    }

    fun detach(current: PlacementReceiver) {
        current.retired = true
        if (receiver !== current) return
        receiver = null
        cancelAll("detached")
    }

    suspend fun request(call: Call, request: Effect.RequestPlacement): PlacementResult {
        val client = receiver?.takeIf { it.attached } ?: return PlacementResult.Expired
        val remaining = request.deadline - clock.now()
        if (remaining <= Duration.ZERO) return PlacementResult.Expired
        val placement = Pending(client, client.generation, request)
        pending[request.actionID] = placement
        return try {
            val deadline = java.time.Instant.ofEpochMilli((Clock.System.now() + remaining).toEpochMilliseconds())
            client.send(message("placementRequested",
                "generation" to JsonPrimitive(placement.generation),
                "actionID" to encode(request.actionID),
                "deadline" to JsonPrimitive(timestamp.format(deadline)),
                "remainingMs" to JsonPrimitive(remaining.inWholeMilliseconds.coerceAtLeast(1)),
                "request" to message("start", "origin" to encode(request.origin), "callID" to encode(call.id),
                    "line" to encode(call.line), "parties" to encode(call.parties)),
            ).toString())
            placement.cancellation.await()
            PlacementResult.Failed(PlacementFailure.CANCELLED)
        } finally {
            if (pending.remove(request.actionID, placement)) placement.cancel(cancellationReason(request))
        }
    }

    suspend fun settle(calls: CallRuntime, client: PlacementReceiver, input: JsonObject): Boolean {
        val id = input.read<ActionID>("actionID")
        val placement = pending[id] ?: return false
        if (placement.receiver !== client || placement.generation != input.read<Long>("generation") ||
            clock.now() >= placement.request.deadline
        ) return false
        val result = input.obj("result").placementResult()
        pending.remove(id)
        return calls.settlePlacement(placement.request.attempt, result).also { accepted ->
            if (!accepted) placement.cancel(cancellationReason(placement.request))
        }
    }

    private fun cancelAll(reason: String) {
        val cancelled = pending.values.toList()
        pending.clear()
        for (placement in cancelled) {
            placement.cancel(reason)
            placement.cancellation.complete(Unit)
        }
    }

    private fun cancellationReason(request: Effect.RequestPlacement): String {
        val lifecycle = state()?.calls?.get(request.attempt.callID)?.lifecycle ?: return "reset"
        val reason = when (lifecycle) {
            is Lifecycle.Ending -> lifecycle.reason
            is Lifecycle.Ended -> lifecycle.reason
            else -> null
        }
        return when (val error = (reason as? EndReason.Failed)?.error) {
            is CallError.DeadlineExceeded -> "deadlineExceeded"
            is CallError.SystemFailed -> if (error.cause.operation == SystemOperation.RESET) "reset" else "ended"
            else -> "ended"
        }
    }

    private data class Pending(
        val receiver: PlacementReceiver, val generation: Long, val request: Effect.RequestPlacement,
        val cancellation: CompletableDeferred<Unit> = CompletableDeferred(),
    ) {
        fun cancel(reason: String) {
            receiver.send(message("placementCancelled", "generation" to JsonPrimitive(generation),
                "actionID" to encode(request.actionID), "reason" to JsonPrimitive(reason)).toString())
        }
    }

    private companion object {
        val timestamp = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
    }
}

private fun JsonObject.placementResult(): PlacementResult {
    if (!read<Boolean>("ok")) return PlacementResult.Failed(obj("error").read("cause"))
    val value = obj("value")
    return if (value.text("kind") == "placed") {
        PlacementResult.Placed(value["remoteID"]?.let { Wire.json.decodeFromJsonElement<RemoteCallID>(it) })
    } else PlacementResult.Refused(value.read("reason"))
}
