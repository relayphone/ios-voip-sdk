package com.relayphone.voip.expo

import com.relayphone.voip.Effect
import com.relayphone.voip.runtime.AnswerDecision
import com.relayphone.voip.runtime.CallRuntime
import com.relayphone.voip.runtime.MediaPort
import com.relayphone.voip.runtime.Reconciliation

/** Optional native ownership service for incoming answers. */
interface AnswerAuthority {
    suspend fun claim(request: Effect.RequestClaim): AnswerDecision
    suspend fun reconcile(request: Effect.Reconcile): Reconciliation
    suspend fun release(request: Effect.ReleasePermit)
}

/** Registers the host's media and call observers before the Expo module starts. */
object NativeCallMedia {
    internal data class Registration(
        val media: MediaPort?, val observers: List<(CallRuntime) -> Unit>, val authority: AnswerAuthority?,
    )

    private var started = false
    private var registration = Registration(null, emptyList(), null)

    /** Call from the host's Expo application lifecycle listener. Observers attach once per runtime. */
    @Synchronized
    fun register(
        media: MediaPort?, observers: List<(CallRuntime) -> Unit> = emptyList(), answerAuthority: AnswerAuthority? = null,
    ) {
        check(!started) { "Register call media before starting the calling module" }
        registration = Registration(media, observers.toList(), answerAuthority)
    }

    @Synchronized
    internal fun start(): Registration {
        started = true
        return registration
    }
}
