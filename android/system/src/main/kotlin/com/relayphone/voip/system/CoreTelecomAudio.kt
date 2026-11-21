package com.relayphone.voip.system

import android.media.AudioManager
import android.media.ToneGenerator
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import com.relayphone.voip.DTMFSequence
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.map

internal class CoreTelecomAudio(
    private val scope: CallControlScope,
    private val manager: AudioManager,
) : TelecomAudioControl {
    @Volatile private var available = emptyMap<String, CallEndpointCompat>()
    // AudioManager mute is shared. Restore the prior setting when this call releases it.
    private var restoreMute: Boolean? = null
    private var appliedMute: Boolean? = null
    private var suspendedMute: Boolean? = null
    private var held = false
    private var closed = false

    override val currentEndpoint = scope.currentCallEndpoint.map { it.endpoint() }
    override val availableEndpoints = scope.availableEndpoints.map { endpoints ->
        available = endpoints.associateBy { it.identifier.toString() }
        endpoints.map { it.endpoint() }
    }
    override val isMuted = scope.isMuted

    override suspend fun selectEndpoint(id: String) = translateFailure {
        val endpoint = available[id] ?: throw NativeTelecomFailure()
        scope.requestEndpointChange(endpoint).requireSuccess()
    }

    override suspend fun setMuted(muted: Boolean) = synchronized(this) {
        if (closed || held) throw NativeTelecomFailure()
        applyMute(muted)
    }

    private fun applyMute(muted: Boolean) {
        val before = manager.isMicrophoneMute
        if (before == muted) return
        manager.isMicrophoneMute = muted
        if (manager.isMicrophoneMute != muted) throw NativeTelecomFailure()
        if (restoreMute == null) restoreMute = before
        appliedMute = muted
    }

    @Synchronized
    override fun holdChanged(held: Boolean) {
        if (closed || this.held == held) return
        this.held = held
        if (held) {
            suspendedMute = appliedMute
            releaseMute()
        } else {
            val restore = suspendedMute
            suspendedMute = null
            restore?.let(::applyMute)
        }
    }

    @Synchronized
    fun close() {
        closed = true
        releaseMute()
    }

    private fun releaseMute() {
        val restore = restoreMute ?: return
        if (manager.isMicrophoneMute == appliedMute) manager.isMicrophoneMute = restore
        restoreMute = null
        appliedMute = null
    }

    override suspend fun sendTones(digits: DTMFSequence) {
        val generator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)
        try {
            for ((index, digit) in digits.value.withIndex()) {
                if (index != 0) delay(70)
                if (!generator.startTone(tone(digit), 120)) throw NativeTelecomFailure()
                delay(120)
            }
        } finally {
            generator.release()
        }
    }

    private fun CallEndpointCompat.endpoint() = TelecomEndpoint(identifier.toString(), name.toString(), type)

    private fun tone(digit: Char): Int = when (digit) {
        in '0'..'9' -> ToneGenerator.TONE_DTMF_0 + (digit - '0')
        '*' -> ToneGenerator.TONE_DTMF_S
        '#' -> ToneGenerator.TONE_DTMF_P
        else -> ToneGenerator.TONE_DTMF_A + (digit.uppercaseChar() - 'A')
    }
}
