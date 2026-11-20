package com.relayphone.voip.system

import androidx.core.telecom.CallEndpointCompat
import com.relayphone.voip.ActionID
import com.relayphone.voip.CallError
import com.relayphone.voip.DTMFSequence
import com.relayphone.voip.Outcome
import com.relayphone.voip.Platform
import com.relayphone.voip.SystemFailure
import com.relayphone.voip.SystemOperation
import com.relayphone.voip.runtime.CallAudioRoute
import com.relayphone.voip.runtime.CallAudioRouteType
import com.relayphone.voip.runtime.CallAudioRoutes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex

internal data class TelecomEndpoint(val id: String, val name: String, val type: Int) {
    fun route(sessionID: String) = CallAudioRoute("$sessionID/$id", name, when (type) {
        CallEndpointCompat.TYPE_EARPIECE -> CallAudioRouteType.RECEIVER
        CallEndpointCompat.TYPE_SPEAKER -> CallAudioRouteType.SPEAKER
        CallEndpointCompat.TYPE_WIRED_HEADSET -> CallAudioRouteType.WIRED
        CallEndpointCompat.TYPE_BLUETOOTH -> CallAudioRouteType.BLUETOOTH
        else -> CallAudioRouteType.OTHER
    })
}

internal interface TelecomAudioControl {
    val currentEndpoint: Flow<TelecomEndpoint>
    val availableEndpoints: Flow<List<TelecomEndpoint>>
    val isMuted: Flow<Boolean>
    suspend fun selectEndpoint(id: String)
    suspend fun setMuted(muted: Boolean)
    fun holdChanged(held: Boolean) {}
    suspend fun sendTones(digits: DTMFSequence)
}

internal class TelecomAudioSession(val id: String, val control: TelecomAudioControl) {
    val muteRequests = Mutex()
    @Volatile var muted = false
    @Volatile var systemMute: ActionID? = null
    var available = emptyMap<String, TelecomEndpoint>()
    var current: TelecomEndpoint? = null
}

internal class TelecomAudioRoutes {
    private var owner: TelecomAudioSession? = null
    private val snapshots = MutableStateFlow(CallAudioRoutes(1, emptyList(), null))
    val routes = snapshots.asStateFlow()

    fun observe(scope: CoroutineScope, session: TelecomAudioSession) {
        scope.launch {
            session.control.availableEndpoints.collect { endpoints ->
                update { session.available = endpoints.associateBy { it.id } }
            }
        }
        scope.launch {
            session.control.currentEndpoint.collect { endpoint ->
                update { session.current = endpoint }
            }
        }
    }

    fun activate(session: TelecomAudioSession) = update { owner = session }

    fun release(session: TelecomAudioSession) = update {
        if (owner === session) owner = null
    }

    @Synchronized
    fun isCurrent(session: TelecomAudioSession) = owner === session

    @Synchronized
    fun target(id: String): Pair<TelecomAudioSession, TelecomEndpoint>? {
        val session = owner ?: return null
        val endpointID = id.removePrefix("${session.id}/")
        if (endpointID == id) return null
        return session.available[endpointID]?.let { session to it }
    }

    @Synchronized
    private fun update(change: () -> Unit) {
        change()
        val session = owner
        val choices = session?.available?.values?.map { it.route(session.id) }.orEmpty()
        val current = session?.current?.route(session.id)
        val previous = snapshots.value
        if (previous.routes != choices || previous.current != current) {
            snapshots.value = CallAudioRoutes(previous.revision + 1, choices, current)
        }
    }
}

internal fun audioFailure(code: Int? = null): Outcome.Failure<CallError> =
    Outcome.Failure(CallError.SystemFailed(SystemFailure(Platform.ANDROID, SystemOperation.AUDIO, code)))

internal suspend fun confirmAudio(perform: suspend () -> Unit): Outcome<Unit, CallError> = try {
    perform()
    Outcome.Success(Unit)
} catch (error: CancellationException) {
    throw error
} catch (error: NativeTelecomFailure) {
    audioFailure(error.code)
} catch (_: RuntimeException) {
    audioFailure()
}
