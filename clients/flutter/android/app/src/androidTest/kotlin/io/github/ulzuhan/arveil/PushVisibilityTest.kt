package io.github.ulzuhan.arveil

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.unifiedpush.android.connector.UnifiedPush
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class PushVisibilityTest {
    @Test fun foregroundHintSurvivesBackgroundTransitionWithoutAnotherPush() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33) {
            ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")).use { it.readBytes() }
        }
        val instance = UUID.randomUUID().toString()
        UnifiedPush.saveDistributor(context, instrumentation.context.packageName)
        UnifiedPush.register(context, instance, "Arveil test")
        val token = context.getSharedPreferences("unifiedpush.connector", Context.MODE_PRIVATE)
            .getString("$instance/unifiedpush.connector", null)!!
        fun send() = context.sendBroadcast(Intent("org.unifiedpush.android.connector.MESSAGE")
            .setClassName(context, "org.unifiedpush.android.connector.internal.MessagingReceiverImpl")
            .putExtra("token", token).putExtra("bytesMessage", PushPolicy.marker))
        fun until(check: () -> Boolean) {
            repeat(100) { if (check()) return; Thread.sleep(50) }
            fail("Expected native notification state did not arrive")
        }
        try {
            PushStore.update(context) { it.put("enabled", true).put("instance", instance)
                .put("pending", false).put("presented", false) }
            PushNotice.clear(context)
            PushChannel.updateVisibility(context, true)
            send()
            until { PushStore.read(context).optBoolean("pending") }
            assertFalse(PushStore.read(context).optBoolean("presented"))
            assertTrue(manager.activeNotifications.none { it.id == PushNotice.id })

            // The relay may send only one hint while its mailbox stays pending.
            PushChannel.updateVisibility(context, false)
            until { manager.activeNotifications.any { it.id == PushNotice.id } }
            assertTrue(PushStore.read(context).optBoolean("presented"))
            val first = manager.activeNotifications.single { it.id == PushNotice.id }.postTime
            val revision = PushStore.read(context).optString("hintRevision")
            send()
            until { PushStore.read(context).optString("hintRevision") != revision }
            PushChannel.updateVisibility(context, true)
            PushChannel.updateVisibility(context, false)
            Thread.sleep(200)
            assertEquals(first, manager.activeNotifications.single { it.id == PushNotice.id }.postTime)

            // Dismissing a shown notice does not replay it until sync catches up.
            PushNotice.clear(context)
            PushChannel.updateVisibility(context, false)
            assertTrue(manager.activeNotifications.none { it.id == PushNotice.id })
            PushStore.update(context) { it.put("pending", false).put("presented", false) }
            send()
            until { manager.activeNotifications.any { it.id == PushNotice.id } }

            // A disabled pending hint must not be resurrected by onPause.
            PushNotice.clear(context)
            PushStore.update(context) { it.put("enabled", false).put("pending", true).put("presented", false) }
            PushChannel.updateVisibility(context, false)
            assertTrue(manager.activeNotifications.none { it.id == PushNotice.id })
        } finally {
            PushStore.update(context) { it.put("enabled", false).put("pending", false).put("presented", false) }
            PushChannel.updateVisibility(context, false)
            UnifiedPush.unregister(context, instance)
            PushNotice.clear(context)
        }
    }
}
