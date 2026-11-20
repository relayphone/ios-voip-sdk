package com.relayphone.voip.expo

import com.relayphone.voip.CallError
import com.relayphone.voip.Effect
import com.relayphone.voip.Feature
import com.relayphone.voip.Outcome
import com.relayphone.voip.runtime.CallAudio
import com.relayphone.voip.runtime.CallAudioRoute
import com.relayphone.voip.runtime.CallAudioRoutes
import com.relayphone.voip.runtime.MediaPort
import kotlinx.serialization.json.*

internal fun CallAudioRoutes.bridgeValue(): JsonObject = buildJsonObject {
    put("revision", revision)
    put("routes", JsonArray(routes.map { it.bridgeValue() }))
    put("current", current?.bridgeValue() ?: JsonNull)
}

private fun CallAudioRoute.bridgeValue() = buildJsonObject {
    put("id", id)
    put("name", name)
    put("type", type.wire)
}

internal class ApplicationMedia(private val audio: CallAudio?) : MediaPort {
    override suspend fun prepare(request: Effect.PrepareMedia) = Outcome.Success(Unit)
    override suspend fun close(request: Effect.CloseMedia) = Unit
    override suspend fun sendTones(request: Effect.SendTones) =
        audio?.sendTones(request) ?: Outcome.Failure(CallError.Unsupported(Feature.TONES))
}
