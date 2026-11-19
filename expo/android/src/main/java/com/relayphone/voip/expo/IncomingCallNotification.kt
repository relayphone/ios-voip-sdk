package com.relayphone.voip.expo

import android.Manifest
import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.relayphone.voip.*
import com.relayphone.voip.runtime.PresentationPort
import com.relayphone.voip.system.AdmissionNotification
import com.relayphone.voip.system.R
import java.util.UUID
import kotlinx.coroutines.launch

internal class IncomingCallNotification(private val context: Context) : PresentationPort {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val ongoing = AdmissionNotification(context)
    private val ringing = mutableMapOf<CallID, Ring>()

    data class Ring(val caller: String, val key: String = UUID.randomUUID().toString()) {
        var closeScreen: (() -> Unit)? = null
        var actionTaken = false
    }

    fun readiness(): String? = when {
        manager == null -> "systemUnavailable"
        !manager.areNotificationsEnabled() || (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) ->
            "notificationsDisabled"
        manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE -> "notificationsDisabled"
        else -> null
    }

    fun fullScreenBlock(): String? = when {
        readiness() == "systemUnavailable" -> "unsupportedPlatform"
        readiness() != null -> "requiresPermission"
        Build.VERSION.SDK_INT >= 34 && manager?.canUseFullScreenIntent() != true -> "requiresPermission"
        (manager?.getNotificationChannel(CHANNEL)?.importance ?: NotificationManager.IMPORTANCE_HIGH) <
            NotificationManager.IMPORTANCE_HIGH -> "disabledByPolicy"
        else -> null
    }

    override fun publish(call: Call) {
        if (call.direction != Direction.INCOMING) return
        when (call.lifecycle) {
            Lifecycle.Ringing -> if (call.id !in ringing) {
                val ring = Ring(call.parties.first().displayName)
                ringing[call.id] = ring
                post(call.id, ring)
            }
            is Lifecycle.Ending, is Lifecycle.Ended -> {
                clear(call.id)
                ongoing.remove(call.id)
                NativeCallMedia.recordCredential(call.id, null)
            }
            else -> if (clear(call.id)) { ongoing.post(call) }
        }
    }

    fun find(key: String?): Ring? = ringing.values.firstOrNull { it.key == key }

    fun take(key: String?): CallID? {
        val entry = ringing.entries.firstOrNull { it.value.key == key && !it.value.actionTaken } ?: return null
        entry.value.actionTaken = true
        return entry.key
    }

    private fun clear(id: CallID): Boolean {
        val ring = ringing.remove(id) ?: return false
        manager?.cancel(id.value, ID)
        ring.closeScreen?.invoke()
        return true
    }

    private fun post(id: CallID, ring: Ring) {
        val manager = manager ?: return
        if (readiness() != null) return
        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.voip_incoming_channel),
            NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(sound, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
        })
        val show = activity(ring, "show")
        val answer = activity(ring, "answer")
        val decline = PendingIntent.getBroadcast(context, 0,
            Intent(context, DeclineIncomingCall::class.java).setData(uri(ring, "decline")), FLAGS)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle(ring.caller)
            .setContentText(context.getString(R.string.voip_incoming_call))
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(show)
            .setOngoing(true)
        if (fullScreenBlock() == null) builder.setFullScreenIntent(show, true)
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setStyle(Notification.CallStyle.forIncomingCall(Person.Builder().setName(ring.caller).build(), decline, answer))
        } else {
            builder.addAction(Notification.Action.Builder(null, context.getString(R.string.voip_decline), decline).build())
            builder.addAction(Notification.Action.Builder(null, context.getString(R.string.voip_answer), answer).build())
        }
        try {
            manager.notify(id.value, ID, builder.build().apply { flags = flags or Notification.FLAG_INSISTENT })
        } catch (_: SecurityException) {
            // Permission can change between checking readiness and posting.
        }
    }

    private fun activity(ring: Ring, action: String): PendingIntent =
        PendingIntent.getActivity(context, 0, Intent(context, IncomingCallActivity::class.java)
            .setAction(action).setData(uri(ring, action)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP), FLAGS)

    private fun uri(ring: Ring, action: String) = Uri.parse("voip-call://incoming/$action/${ring.key}")

    companion object {
        private const val CHANNEL = "relayphone.voip.incoming"
        private const val ID = 2
        private const val FLAGS = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    }
}

class DeclineIncomingCall : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        CallHost.scope.launch {
            try { CallHost.get(context).act(intent.data?.lastPathSegment, false) }
            finally { pending.finish() }
        }
    }
}

class IncomingCallActivity : Activity() {
    private var ring: IncomingCallNotification.Ring? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        show(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        show(intent)
    }

    private fun show(intent: Intent) {
        val host = CallHost.get(this)
        val key = intent.data?.lastPathSegment
        ring?.closeScreen = null
        val current = host.presentation.find(key) ?: return finish()
        ring = current
        current.closeScreen = ::finish
        fun act(answer: Boolean) {
            // Keep the Answer activity visible until it can open the host app.
            if (answer) current.closeScreen = null
            CallHost.scope.launch {
                if (host.act(key, answer) && answer) {
                    packageManager.getLaunchIntentForPackage(packageName)?.let(::startActivity)
                }
                finish()
            }
        }
        if (intent.action == "answer") return act(true)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            addView(TextView(context).apply { text = current.caller; textSize = 28f })
            addView(Button(context).apply { setText(R.string.voip_answer); setOnClickListener { act(true) } })
            addView(Button(context).apply { setText(R.string.voip_decline); setOnClickListener { act(false) } })
        })
    }

    override fun onDestroy() {
        ring?.closeScreen = null
        super.onDestroy()
    }
}
