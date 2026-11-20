package com.relayphone.voip.expo

import android.content.Context
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.*

/** FCM entry point for apps that give the SDK its own messaging service. */
open class VoIPFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (!runBlocking { route(this@VoIPFirebaseMessagingService, message) }) onOtherMessage(message)
    }

    protected open fun onOtherMessage(message: RemoteMessage) = Unit

    override fun onNewToken(token: String) {
        runBlocking { recordToken(this@VoIPFirebaseMessagingService, token) }
    }

    companion object {
        /** For an existing messaging service. False leaves the message with the caller. */
        suspend fun route(context: Context, message: RemoteMessage): Boolean {
            val receipt = Clock.System.now()
            val elapsed = CallHost.clock.now()
            return when (val push = PushEnvelope.decode(message.data, receipt, elapsed)) {
                PushEnvelope.Unrelated -> false
                PushEnvelope.Invalid, PushEnvelope.Ineligible -> true
                is PushEnvelope.Invitation -> {
                    Log.d("VoIPPush", "Received invitation")
                    val job = CallHost.scope.async {
                        try {
                            val result = CallHost.get(context).binding.reportPush(push)
                            Log.d("VoIPPush", "Admission result: ${result?.javaClass?.simpleName}")
                        } catch (_: SecurityException) {
                            Log.d("VoIPPush", "Telecom registration was denied")
                        }
                    }
                    // Give cold Telecom admission time to complete before FCM releases the service.
                    if (withTimeoutOrNull(5.seconds) { job.await() } == null) {
                        Log.d("VoIPPush", "Messaging service admission wait expired")
                    }
                    true
                }
            }
        }

        /** Record a provider token and obtain the identity for the host's authenticated upload. */
        suspend fun recordToken(context: Context, token: String): FcmTokenRegistration =
            withContext(Dispatchers.Main.immediate) {
                CallHost.get(context).push.recordToken(token)
            }

        /** Fence the previous local generation after the host invalidates the token. */
        suspend fun invalidateToken(context: Context) = withContext(Dispatchers.Main.immediate) {
            CallHost.get(context).push.invalidateToken()
        }

        /** Apply a matching upload completion from the host's authenticated service. */
        suspend fun completeUpload(context: Context, target: FcmTokenRegistration, result: FcmUploadResult) =
            withContext(Dispatchers.Main.immediate) {
                CallHost.get(context).push.let { it.registration.completeUpload(target, result); it.refresh() }
            }
    }
}
