package com.example.voipconversations

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.service.notification.StatusBarNotification
import androidx.test.platform.app.InstrumentationRegistry
import com.google.firebase.messaging.RemoteMessage
import com.relayphone.voip.expo.VoIPFirebaseMessagingService
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PushDeliveryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = instrumentation.uiAutomation
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val keyguard = context.getSystemService(KeyguardManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val service = object : VoIPFirebaseMessagingService() {
        init { attachBaseContext(context) }
        override fun onOtherMessage(message: RemoteMessage) { unrelated = message.data["other"] }
    }
    private var unrelated: String? = null

    @Test
    fun deliversInBackgroundAndOnLockScreen() {
        shell("appops set ${context.packageName} USE_FULL_SCREEN_INTENT allow")
        assertTrue(notifications.canUseFullScreenIntent())
        val serviceName = ComponentName(context, VoIPFirebaseMessagingService::class.java)
        assertTrue(context.packageManager.getServiceInfo(serviceName, 0).enabled)
        shell("logcat -c")
        val run = "fcm-test-${SystemClock.elapsedRealtime()}"
        val cold = "$run-cold"
        service.onMessageReceived(message(cold))
        decline(callStyle(cold))
        await("cold notification removed") { active(cold) == null }
        assertFalse(logs().contains("VoIPPushExample ready"))

        shell("am start -W -n ${context.packageName}/.MainActivity")
        await("JavaScript listeners") { logs().contains("VoIPPushExample ready") }
        shell("input keyevent KEYCODE_HOME")
        await("launcher foreground") { device.rootInActiveWindow?.packageName?.toString()?.let { it != context.packageName } == true }

        service.onMessageReceived(RemoteMessage.Builder("example").setData(mapOf("other" to "preserved")).build())
        assertEquals("preserved", unrelated)
        val expired = "$run-expired"
        val background = "$run-background"
        service.onMessageReceived(message(expired, expiresOffset = -1))
        absent(expired)

        val incoming = message(background)
        service.onMessageReceived(incoming)
        val notification = callStyle(background)
        await("JavaScript ringing") { logs().contains("VoIPPushExample $background ringing") }
        service.onMessageReceived(incoming)
        assertEquals(notification.postTime, callStyle(background).postTime)
        decline(notification)
        awaitAction(background, "end", "ended")
        await("declined notification removed") { active(background) == null }
        val duplicate = "$run-duplicate"
        service.onMessageReceived(message(duplicate, event = background))
        absent(duplicate)

        val locked = "$run-locked"
        val pin = "2468"
        assertTrue(shell("locksettings set-pin $pin").contains("set to"))
        try {
            shell("input keyevent KEYCODE_SLEEP")
            await("screen off and locked") { !power.isInteractive && keyguard.isKeyguardLocked }
            service.onMessageReceived(message(locked, caller = "Locked caller"))
            val lockedNotification = callStyle(locked)
            await("full-screen incoming UI over keyguard") {
                val window = device.rootInActiveWindow
                power.isInteractive && keyguard.isKeyguardLocked &&
                    window != null && window.packageName == context.packageName &&
                    window.findAccessibilityNodeInfosByText("Locked caller").isNotEmpty()
            }
            lockedNotification.notification.actions.single { it.title.toString().equals("Answer", true) }.actionIntent.send()
            awaitAction(locked, "answer", "connecting")
            await("ringing notification removed after Answer") { active(locked) == null }
        } finally {
            shell("locksettings clear --old $pin")
            shell("input keyevent KEYCODE_WAKEUP")
            shell("wm dismiss-keyguard")
        }
    }

    private fun callStyle(id: String): StatusBarNotification {
        await("CallStyle notification for $id") { active(id) != null }
        val row = requireNotNull(active(id))
        val notification = row.notification
        assertEquals(Notification.CATEGORY_CALL, notification.category)
        assertEquals("android.app.Notification\$CallStyle", notification.extras.getString(Notification.EXTRA_TEMPLATE))
        assertNotNull(notification.fullScreenIntent)
        return row
    }

    private fun absent(id: String) {
        repeat(10) {
            assertNull(active(id))
            assertFalse(logs().contains("VoIPPushExample $id ringing"))
            SystemClock.sleep(100)
        }
    }

    private fun active(id: String) = notifications.activeNotifications.firstOrNull { it.tag == id && it.id == 2 }

    private fun decline(row: StatusBarNotification) =
        row.notification.actions.single { it.title.toString().equals("Decline", true) }.actionIntent.send()

    private fun awaitAction(id: String, action: String, status: String) {
        val expected = "VoIPPushExample $id $action system $status"
        await("JavaScript $action receipt and $status state") { logs().contains(expected) }
        assertEquals(1, logs().lineSequence().count { it.contains(expected) })
    }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 20_000
        do {
            if (condition()) return
            SystemClock.sleep(100)
        } while (SystemClock.elapsedRealtime() < deadline)
        fail("Missing $description")
    }

    private fun logs() = shell("logcat -d -s ReactNativeJS:I")

    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(device.executeShellCommand(command))
        .bufferedReader().use { it.readText() }

    private fun message(id: String, event: String = id, caller: String = "Background caller", expiresOffset: Long = 40): RemoteMessage {
        val now = Instant.now()
        val timestamp = DateTimeFormatterBuilder().appendInstant(3).toFormatter()
        val value = JSONObject().put("issuedAt", timestamp.format(now.minusSeconds(5)))
            .put("expiresAt", timestamp.format(now.plusSeconds(expiresOffset)))
            .put("invitation", JSONObject().put("callID", id).put("eventID", event)
                .put("line", JSONObject().put("accountID", "example").put("id", "example").put("label", "VoIP Example"))
                .put("party", JSONObject().put("id", "caller").put("displayName", caller)
                    .put("handle", JSONObject().put("kind", "opaque").put("value", "caller"))))
        return RemoteMessage.Builder("example")
            .setData(mapOf("version" to "1", "kind" to "pushEnvelope", "value" to value.toString())).build()
    }
}
