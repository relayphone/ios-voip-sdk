package com.relayphone.voip.system

import android.net.Uri
import android.os.ParcelUuid
import android.telecom.DisconnectCause
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallException
import androidx.core.telecom.CallsManager
import com.relayphone.voip.Call
import com.relayphone.voip.Direction
import com.relayphone.voip.Handle

internal class CoreTelecomBackend(
    private val calls: CallsManager,
    private val notification: AdmissionNotification,
    private val customIncomingPresentation: Boolean,
) : TelecomBackend<ParcelUuid> {
    override suspend fun addCall(
        call: Call,
        callbacks: TelecomCallbacks,
        admitted: (TelecomControl<ParcelUuid>) -> Unit,
    ) {
        val party = call.parties.first()
        val attributes = CallAttributesCompat(
            party.displayName,
            when (val handle = party.handle) {
                is Handle.Phone -> Uri.fromParts("tel", handle.e164, null)
                is Handle.Email -> Uri.fromParts("mailto", handle.address, null)
                is Handle.Opaque -> Uri.fromParts("voip", handle.value, null)
            },
            if (call.direction == Direction.INCOMING) CallAttributesCompat.DIRECTION_INCOMING
            else CallAttributesCompat.DIRECTION_OUTGOING,
        )
        var notificationPosted = false
        try {
            translateFailure {
                calls.addCall(
                    attributes,
                    onAnswer = { callbacks.answer() },
                    onDisconnect = { callbacks.disconnect() },
                    onSetActive = { callbacks.setHeld(false) },
                    onSetInactive = { callbacks.setHeld(true) },
                ) {
                    admitted(Control(this))
                    if (call.direction != Direction.INCOMING || !customIncomingPresentation)
                        notificationPosted = notification.post(call)
                }
            }
        } finally {
            if (notificationPosted) notification.remove(call.id)
        }
    }

    private class Control(private val scope: CallControlScope) : TelecomControl<ParcelUuid> {
        override val id: ParcelUuid = scope.getCallId()

        override suspend fun answer() = translateFailure {
            scope.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL).requireSuccess()
        }

        override suspend fun setHeld(held: Boolean) = translateFailure {
            (if (held) scope.setInactive() else scope.setActive()).requireSuccess()
        }

        override suspend fun disconnect(cause: TelecomEnd) = translateFailure {
            val code = when (cause) {
                TelecomEnd.LOCAL -> DisconnectCause.LOCAL
                TelecomEnd.REMOTE -> DisconnectCause.REMOTE
                TelecomEnd.MISSED -> DisconnectCause.MISSED
                TelecomEnd.REJECTED -> DisconnectCause.REJECTED
            }
            scope.disconnect(DisconnectCause(code)).requireSuccess()
        }
    }
}

private fun CallControlResult.requireSuccess() {
    if (this is CallControlResult.Error) throw NativeTelecomFailure(errorCode)
}

private inline fun <T> translateFailure(block: () -> T): T = try {
    block()
} catch (error: CallException) {
    throw NativeTelecomFailure(error.code)
} catch (_: SecurityException) {
    throw NativeTelecomFailure()
} catch (_: IllegalArgumentException) {
    throw NativeTelecomFailure()
} catch (_: UnsupportedOperationException) {
    throw NativeTelecomFailure()
}
