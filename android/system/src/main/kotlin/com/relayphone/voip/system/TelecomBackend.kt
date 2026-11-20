package com.relayphone.voip.system

import com.relayphone.voip.Call
import com.relayphone.voip.Direction
import com.relayphone.voip.EndReason
import com.relayphone.voip.CallError

internal interface TelecomBackend<NativeID : Any> {
    suspend fun addCall(
        call: Call,
        callbacks: TelecomCallbacks,
        admitted: (TelecomControl<NativeID>) -> Unit,
    )
}

internal interface TelecomControl<NativeID : Any> {
    val id: NativeID
    val audio: TelecomAudioControl? get() = null
    suspend fun answer()
    suspend fun setHeld(held: Boolean)
    suspend fun disconnect(cause: TelecomEnd)
}

internal class TelecomCallbacks(
    val answer: suspend () -> Unit,
    val disconnect: suspend () -> Unit,
    val setHeld: suspend (Boolean) -> Unit,
)

internal class NativeTelecomFailure(val code: Int? = null) : Exception()

internal enum class TelecomEnd { LOCAL, REMOTE, MISSED, REJECTED }

internal fun telecomEnd(reason: EndReason, direction: Direction): TelecomEnd = when (reason) {
    EndReason.LocalEnded -> TelecomEnd.LOCAL
    EndReason.LocalDeclined -> TelecomEnd.REJECTED
    EndReason.Unanswered -> if (direction == Direction.INCOMING) TelecomEnd.MISSED else TelecomEnd.REMOTE
    is EndReason.Failed -> if (reason.error is CallError.Refused) TelecomEnd.REJECTED else TelecomEnd.REMOTE
    else -> TelecomEnd.REMOTE
}
