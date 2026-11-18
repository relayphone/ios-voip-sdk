package com.relayphone.voip.system

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.relayphone.voip.Call
import com.relayphone.voip.CallID

/** Minimal ongoing call indication during Telecom admission. */
internal class AdmissionNotification(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)

    fun post(call: Call): Boolean {
        val manager = manager ?: return false
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false

        return try {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.voip_call_channel),
                NotificationManager.IMPORTANCE_LOW))
            manager.notify(call.id.value, ID, Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.sym_call_outgoing)
                .setContentTitle(call.parties.first().displayName)
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .build())
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun remove(id: CallID) {
        manager?.cancel(id.value, ID)
    }

    private companion object {
        const val CHANNEL = "relayphone.voip.ongoing"
        const val ID = 1
    }
}
