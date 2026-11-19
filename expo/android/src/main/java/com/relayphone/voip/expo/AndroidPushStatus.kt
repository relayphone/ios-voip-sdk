package com.relayphone.voip.expo

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.AtomicFile
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.relayphone.voip.Wire
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal class AndroidPushStatus(
    private val context: Context, private val state: BridgeState, private val presentation: IncomingCallNotification,
    private val fcmEnabled: Boolean,
) {
    @Serializable
    private data class Installation(val id: String, val fcm: PushRegistration.Saved = PushRegistration.Saved())

    private val file = AtomicFile(File(context.noBackupFilesDir, "voip-push.json"))
    private val installed = try {
        Wire.json.decodeFromString<Installation>(file.readFully().decodeToString())
    } catch (_: FileNotFoundException) {
        Installation(UUID.randomUUID().toString()).also(::save)
    }
    val registration = PushRegistration(installed.id, "fcm", installed.fcm) { save(installed.copy(fcm = it)) }
    private var requested = false
    private var pendingRead: CompletableDeferred<Unit>? = null
    private var token: String? = null
    private var revision = 0L

    // Accessed on the main dispatcher alongside registration changes.
    val tokenObservers = mutableSetOf<(Map<String, Any?>) -> Unit>()

    private fun firebaseAvailable() = FirebaseApp.getApps(context).any { it.name == FirebaseApp.DEFAULT_APP_NAME }

    fun start() {
        if (requested || !fcmEnabled) {
            refresh()
            return
        }
        val attempt = registration.begin()
        if (firebaseAvailable()) {
            requested = true
            pendingRead = CompletableDeferred()
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                CallHost.scope.launch {
                    val value = if (task.isSuccessful) task.result else null
                    if (registration.complete(attempt, value)) {
                        refresh()
                        updateToken(value)
                    }
                }
            }
        } else registration.complete(attempt, null)
        refresh()
    }

    suspend fun getToken(): Map<String, Any?> {
        if (!fcmEnabled || !firebaseAvailable()) return tokenSnapshot(null)
        start()
        pendingRead?.await()
        return tokenSnapshot(token.takeIf { firebaseAvailable() })
    }

    fun recordToken(value: String): FcmTokenRegistration {
        val target = registration.changed(value)
        refresh()
        if (fcmEnabled && firebaseAvailable()) {
            requested = true
            updateToken(value)
        }
        return target
    }

    fun invalidateToken() {
        registration.invalidate()
        requested = true
        refresh()
        updateToken(null)
    }

    private fun updateToken(value: String?) {
        if (token != value) {
            token = value
            revision++
            val snapshot = tokenSnapshot(value)
            tokenObservers.toList().forEach { it(snapshot) }
        }
        pendingRead?.complete(Unit)
        pendingRead = null
    }

    private fun tokenSnapshot(value: String?) = mapOf(
        "revision" to revision,
        "token" to value?.let { mapOf("type" to "fcm", "value" to it) },
    )

    fun refresh() {
        val blocked = presentation.readiness()
        val health = buildJsonObject {
            put("registration", registration.value())
            put("readiness", if (blocked == null) message("ready")
                else message("blocked", "reason" to JsonPrimitive(blocked)))
            put("connectivity", message(connectivity()))
            // The FCM payload has no trusted installation and generation correlation.
            put("delivery", message("unknown", "reason" to JsonPrimitive("noEvidence")))
        }
        state.updatePush(health, presentation.fullScreenBlock())
    }

    private fun connectivity(): String {
        val network = context.getSystemService(ConnectivityManager::class.java) ?: return "unknown"
        val active = network.activeNetwork ?: return "offline"
        val capabilities = network.getNetworkCapabilities(active) ?: return "unknown"
        return if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) "online" else "unknown"
    }

    private fun save(value: Installation) {
        val stream = file.startWrite()
        try {
            stream.write(Wire.json.encodeToString(value).encodeToByteArray())
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }
}
