package com.relayphone.voip.expo

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import com.relayphone.voip.AccountID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.LineID
import com.relayphone.voip.CallError
import com.relayphone.voip.MediaPermission
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.system.AndroidTelecomSystem
import expo.modules.interfaces.permissions.PermissionsStatus
import expo.modules.kotlin.functions.Coroutine
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlin.time.Instant
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

class VoIPConversationsModule : Module() {
    private val sendFrame: (String) -> Unit = { sendEvent("bridgeFrame", mapOf("json" to it)) }
    @Volatile private var negotiated = false

    override fun definition() = ModuleDefinition {
        Name("VoIPConversations")
        Events("bridgeFrame")
        OnCreate {
            synchronized(process) {
                if (host == null) host = start(requireNotNull(appContext.reactContext).applicationContext)
                service = checkNotNull(host)
            }
        }
        OnDestroy { service.binding.state.detach(sendFrame) }
        Function("negotiate") { source: String ->
            val selected = BridgeWire.negotiate(source)
            if (selected) negotiated = true
            envelope("negotiated", if (selected) ok(JsonObject(mapOf("version" to JsonPrimitive(1))))
                else failed(CallError.BridgeUnavailable)).toString()
        }
        Function("line") { encode(service.line).toString() }
        Function("attach") { check(negotiated); service.binding.state.attach(sendFrame).toString() }
        Function("detach") { service.binding.state.detach(sendFrame) }
        Function("snapshot") { check(negotiated); service.binding.state.snapshot().toString() }
        AsyncFunction("command") Coroutine { source: String ->
            withContext(Dispatchers.Main.immediate) { service.binding.command(source, negotiated, ::permission) }
        }
    }

    private suspend fun permission(kind: MediaPermission, request: Boolean): Reply {
        val name = if (kind == MediaPermission.MICROPHONE) Manifest.permission.RECORD_AUDIO else Manifest.permission.CAMERA
        val manager = appContext.permissions ?: return ok(message("restricted"))
        if (!manager.isPermissionPresentInManifest(name)) return ok(message("restricted"))
        var status = suspendCancellableCoroutine { continuation ->
            manager.getPermissions({ continuation.resumeWith(Result.success(it[name])) }, name)
        }
        if (request && status?.status != PermissionsStatus.GRANTED && status?.canAskAgain != false) {
            if (appContext.currentActivity?.hasWindowFocus() != true) return failed(CallError.PermissionRequired(kind))
            status = suspendCancellableCoroutine { continuation ->
                manager.askForPermissions({ continuation.resumeWith(Result.success(it[name])) }, name)
            }
        }
        return ok(message(when (status?.status) {
            PermissionsStatus.GRANTED -> "granted"
            PermissionsStatus.DENIED -> if (status.canAskAgain) "denied" else "restricted"
            else -> "notDetermined"
        }))
    }

    private lateinit var service: Host

    private data class Host(val line: CallingLine?, val binding: CallBinding)

    private companion object {
        val process = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var host: Host? = null

        fun start(context: Context): Host {
            val manager = context.packageManager
            val app = manager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
            val line = app.metaData?.getString("com.relayphone.voip.accountID")?.removePrefix("voip:")?.let {
                CallingLine(AccountID(it), LineID(it), app.metaData?.getString("com.relayphone.voip.label")?.removePrefix("voip:")
                    ?: manager.getApplicationLabel(app).toString())
            }
            val clock = MonotonicClock { Instant.fromEpochMilliseconds(SystemClock.elapsedRealtime()) }
            return Host(line, CallBinding(process, line, clock, NativeCallMedia.start()) { submit ->
                val telecom = AndroidTelecomSystem.register(context, 34, submit)
                CallSystem(telecom, telecom::answerWithReceipt)
            })
        }
    }
}
