package com.relayphone.voip.expo

import android.Manifest
import com.relayphone.voip.CallError
import com.relayphone.voip.MediaPermission
import expo.modules.interfaces.permissions.PermissionsStatus
import expo.modules.kotlin.functions.Coroutine
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

class VoIPConversationsModule : Module() {
    private val sendFrame: (String) -> Unit = { sendEvent("bridgeFrame", mapOf("json" to it)) }
    private val sendToken: (Map<String, Any?>) -> Unit = { sendEvent("pushTokenUpdated", it) }
    private val placement = PlacementReceiver { sendEvent("placementFrame", mapOf("json" to it)) }
    @Volatile private var negotiated = false

    override fun definition() = ModuleDefinition {
        Name("VoIPConversations")
        Events("bridgeFrame", "placementFrame", "incomingPush", "pushTokenUpdated")
        OnCreate {
            service = CallHost.get(requireNotNull(appContext.reactContext))
            CallHost.scope.launch { service.push.start() }
        }
        OnStartObserving("incomingPush") {
            pushEvents = CallHost.scope.launch {
                service.binding.pushOutcomes.collect { sendEvent("incomingPush", mapOf("json" to it.toString())) }
            }
        }
        OnStopObserving("incomingPush") { pushEvents?.cancel() }
        OnStartObserving("pushTokenUpdated") { CallHost.scope.launch { service.push.tokenObservers.add(sendToken) } }
        OnStopObserving("pushTokenUpdated") { CallHost.scope.launch { service.push.tokenObservers.remove(sendToken) } }
        OnActivityEntersForeground { CallHost.scope.launch { service.push.refresh() } }
        OnDestroy {
            service.binding.state.detach(sendFrame)
            pushEvents?.cancel()
            CallHost.scope.launch {
                service.binding.detachPlacement(placement)
                service.push.tokenObservers.remove(sendToken)
            }
        }
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
        AsyncFunction("getPushToken") Coroutine { ->
            withContext(Dispatchers.Main.immediate) { service.push.getToken() }
        }
        AsyncFunction("command") Coroutine { source: String ->
            withContext(Dispatchers.Main.immediate) {
                service.push.refresh()
                service.binding.command(source, negotiated, placement, ::permission)
            }
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

    private lateinit var service: CallHost
    private var pushEvents: Job? = null
}
