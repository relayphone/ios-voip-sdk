package com.relayphone.voip.expo

import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import com.relayphone.voip.AccountID
import com.relayphone.voip.CallingLine
import com.relayphone.voip.LineID
import com.relayphone.voip.runtime.MonotonicClock
import com.relayphone.voip.system.AndroidTelecomSystem
import kotlin.time.Instant
import kotlinx.coroutines.*

internal class CallHost private constructor(context: Context) {
    private val manager = context.packageManager
    private val app = manager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    val line = app.metaData?.getString("com.relayphone.voip.accountID")?.removePrefix("voip:")?.let {
        CallingLine(AccountID(it), LineID(it), app.metaData?.getString("com.relayphone.voip.label")?.removePrefix("voip:")
            ?: manager.getApplicationLabel(app).toString())
    }
    val presentation = IncomingCallNotification(context)
    val binding = CallBinding(scope, line, clock, NativeCallMedia.start(), presentation) { submit ->
        val telecom = AndroidTelecomSystem.register(context, 34, true, submit)
        CallSystem(telecom, telecom::answerWithReceipt, telecom::answerFromNotification)
    }
    val push by lazy { AndroidPushStatus(context, binding.state, presentation) }

    suspend fun act(key: String?, answer: Boolean): Boolean {
        val id = presentation.take(key) ?: return false
        val applied = binding.notificationAction(id, answer)
        if (!applied) presentation.find(key)?.actionTaken = false
        return applied
    }

    companion object {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val clock = MonotonicClock { Instant.fromEpochMilliseconds(SystemClock.elapsedRealtime()) }
        private var host: CallHost? = null

        @Synchronized
        fun get(context: Context): CallHost =
            host ?: CallHost(context.applicationContext).also { host = it }
    }
}
