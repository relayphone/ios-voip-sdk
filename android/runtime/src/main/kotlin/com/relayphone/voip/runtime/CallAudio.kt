package com.relayphone.voip.runtime

import com.relayphone.voip.Action
import com.relayphone.voip.ActionReceipt
import com.relayphone.voip.CallError
import com.relayphone.voip.Effect
import com.relayphone.voip.Outcome
import kotlinx.coroutines.flow.StateFlow

/** Telecom audio endpoints use opaque IDs for the lifetime of the call. */
public data class CallAudioRoute(public val id: String, public val name: String, public val type: CallAudioRouteType)

public enum class CallAudioRouteType(public val wire: String) {
    RECEIVER("builtInReceiver"), SPEAKER("builtInSpeaker"), WIRED("headphones"),
    BLUETOOTH("bluetooth"), OTHER("other"),
}

/** An observed endpoint list and current output, with an independent revision timeline. */
public data class CallAudioRoutes(
    public val revision: Long,
    public val routes: List<CallAudioRoute>,
    public val current: CallAudioRoute?,
)

/** Android call audio operations used by the Expo bridge. */
public interface CallAudio {
    public val routes: StateFlow<CallAudioRoutes>
    public suspend fun selectRoute(id: String): Outcome<Unit, CallError>
    public suspend fun perform(action: Action): Outcome<ActionReceipt, CallError>
    public suspend fun sendTones(request: Effect.SendTones): Outcome<Unit, CallError>
}
