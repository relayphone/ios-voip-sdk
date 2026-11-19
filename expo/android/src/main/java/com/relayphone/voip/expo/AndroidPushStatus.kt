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
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal class AndroidPushStatus(
    private val context: Context, private val state: BridgeState, private val presentation: IncomingCallNotification,
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
    private var started = false

    fun start() {
        if (started) return
        started = true
        val attempt = registration.begin()
        if (FirebaseApp.getApps(context).any { it.name == FirebaseApp.DEFAULT_APP_NAME }) {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                CallHost.scope.launch {
                    registration.complete(attempt, if (task.isSuccessful) task.result else null)
                    refresh()
                }
            }
        } else registration.complete(attempt, null)
        refresh()
    }

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
