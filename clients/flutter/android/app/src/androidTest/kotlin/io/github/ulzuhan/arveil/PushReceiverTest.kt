package io.github.ulzuhan.arveil

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import org.unifiedpush.android.connector.UnifiedPush

/** Runs only on a disposable emulator. Exercises the real exported connector,
 * private PushService, Keystore and Android notification manager, not mocks. */
@RunWith(AndroidJUnit4::class)
class PushReceiverTest {
    @Test fun rejectsUnknownTokensAndCoalescesGenericHintsWithoutOpeningAProfile() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33) {
            instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS").close()
        }
        val instance = UUID.randomUUID().toString()
        // A disposable fake distributor never sends a network request. Its
        // registration causes the official library to create an unguessable token.
        UnifiedPush.saveDistributor(context, instrumentation.context.packageName)
        UnifiedPush.register(context, instance, "Arveil test")
        val connector = context.getSharedPreferences("unifiedpush.connector", Context.MODE_PRIVATE)
        val token = connector.getString("$instance/unifiedpush.connector", null)
            ?: throw AssertionError("Connector token not found")
        PushStore.update(context) { it.put("enabled", true).put("instance", instance)
            .put("owner", "a".repeat(64)).put("server", "https://notify.example.org") }
        fun send(action: String, suppliedToken: String = token, bytes: ByteArray? = null, endpoint: String? = null) {
            val intent = Intent("org.unifiedpush.android.connector.$action")
                .setClassName(context, "org.unifiedpush.android.connector.internal.MessagingReceiverImpl")
                .putExtra("token", suppliedToken)
            if (bytes != null) intent.putExtra("bytesMessage", bytes)
            if (endpoint != null) intent.putExtra("endpoint", endpoint)
            context.sendBroadcast(intent)
        }
        fun until(check: () -> Boolean) {
            repeat(100) { if (check()) return; Thread.sleep(50) }
            throw AssertionError("Native push callback did not complete")
        }
        try {
            PushNotice.clear(context)
            send("MESSAGE", suppliedToken = "invalid-token", bytes = PushPolicy.marker)
            Thread.sleep(250)
            assertFalse(PushStore.read(context).optBoolean("pending"))
            send("MESSAGE", bytes = "not-the-marker".toByteArray())
            Thread.sleep(250)
            assertFalse(PushStore.read(context).optBoolean("pending"))
            send("NEW_ENDPOINT", endpoint = "https://other.example.org/up-wrong")
            until { PushStore.read(context).optString("error") == "endpoint" }
            assertEquals("", PushStore.read(context).optString("endpoint"))
            send("NEW_ENDPOINT", endpoint = "https://notify.example.org/up-test?up=1")
            until { PushStore.read(context).optString("endpoint").isNotEmpty() }
            PushNotice.clear(context)
            send("MESSAGE", bytes = PushPolicy.marker)
            until { manager.activeNotifications.any { it.id == PushNotice.id &&
                it.notification.extras.getCharSequence(android.app.Notification.EXTRA_TEXT)?.toString() ==
                    context.getString(R.string.push_activity) } }
            val first = manager.activeNotifications.single { it.id == PushNotice.id }
            assertFalse(first.notification.extras.toString().contains("up-test"))
            send("MESSAGE", bytes = PushPolicy.marker)
            Thread.sleep(250)
            assertEquals(1, manager.activeNotifications.count { it.id == PushNotice.id })
            assertEquals(first.postTime, manager.activeNotifications.single { it.id == PushNotice.id }.postTime)
            val prefs = context.getSharedPreferences("arveil.push", Context.MODE_PRIVATE).getString("state", "")!!
            assertFalse(prefs.contains("notify.example.org"))
            PushStore.update(context) { it.put("enabled", false).put("pending", false) }
            PushNotice.clear(context)
            send("MESSAGE", bytes = PushPolicy.marker)
            Thread.sleep(250)
            assertFalse(PushStore.read(context).optBoolean("pending"))
            assertFalse(manager.activeNotifications.any { it.id == PushNotice.id })
        } finally {
            PushStore.update(context) { it.put("enabled", false).put("endpoint", "").put("pending", false) }
            UnifiedPush.unregister(context, instance)
            PushNotice.clear(context)
        }
    }
}

class FakeDistributor : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { /* Test-only sink. */ }
}
