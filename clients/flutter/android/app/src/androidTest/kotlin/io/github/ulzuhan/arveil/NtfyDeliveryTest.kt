package io.github.ulzuhan.arveil

import android.app.NotificationManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.unifiedpush.android.connector.UnifiedPush
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Opt-in acceptance on a disposable emulator with the official ntfy app.
 * Configure its default server to the same adb-reversed loopback URL first.
 * No profile is opened; this tests the real distributor/receiver/OS delivery,
 * independently of the relay transport acceptance in test_ntfy_hints.py. */
@RunWith(AndroidJUnit4::class)
class NtfyDeliveryTest {
    @Test fun realDistributorDeliversGenericHintAndUnregisters() {
        val server = InstrumentationRegistry.getArguments().getString("ntfyServer")
        assumeTrue("Supply ntfyServer for the optional real-distributor acceptance", server != null)
        require(server != null && server.matches(Regex("http://127[.]0[.]0[.]1:[0-9]+")))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val manager = context.getSystemService(NotificationManager::class.java)
        assertTrue(UnifiedPush.getDistributors(context).contains(PushChannel.distributor))
        if (Build.VERSION.SDK_INT >= 33) {
            ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")).use { it.readBytes() }
        }
        fun until(description: String, check: () -> Boolean) {
            repeat(300) { if (check()) return; Thread.sleep(100) }
            fail(description)
        }
        fun publish(endpoint: String, body: ByteArray) {
            val connection = URL(endpoint).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/octet-stream")
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
                assertTrue("Disposable ntfy rejected the marker", connection.responseCode in 200..299)
                connection.inputStream.use { it.readBytes() }
            } finally { connection.disconnect() }
        }
        val instance = UUID.randomUUID().toString()
        try {
            PushStore.update(context) {
                it.keys().asSequence().toList().forEach(it::remove)
                it.put("enabled", true).put("instance", instance).put("server", server)
                    .put("owner", "a".repeat(64))
            }
            PushNotice.clear(context)
            PushChannel.updateVisibility(context, true)
            UnifiedPush.saveDistributor(context, PushChannel.distributor)
            UnifiedPush.register(context, instance, "Arveil acceptance")
            until("Real ntfy did not return an accepted endpoint") {
                PushStore.read(context).optString("endpoint").isNotEmpty()
            }
            val endpoint = PushStore.read(context).optString("endpoint")
            assertTrue(PushPolicy.endpoint(endpoint, server, true))
            PushNotice.clear(context) // Registration's setup notice is separate.
            // Endpoint registration precedes ntfy's asynchronous subscription.
            Thread.sleep(2000)
            publish(endpoint, PushPolicy.marker)
            until("Real ntfy did not deliver a hint while Arveil was foreground") {
                PushStore.read(context).optBoolean("pending")
            }
            assertTrue(manager.activeNotifications.none { it.id == PushNotice.id })
            PushChannel.updateVisibility(context, false)
            until("Leaving foreground did not display the pending hint") {
                manager.activeNotifications.any { it.id == PushNotice.id }
            }
            val first = manager.activeNotifications.single { it.id == PushNotice.id }.postTime
            val revision = PushStore.read(context).optString("hintRevision")
            publish(endpoint, PushPolicy.marker)
            until("Second real-distributor delivery did not arrive") {
                PushStore.read(context).optString("hintRevision") != revision
            }
            assertEquals(first, manager.activeNotifications.single { it.id == PushNotice.id }.postTime)
            PushStore.update(context) { it.put("pending", false).put("presented", false) }
            PushNotice.clear(context)
            publish(endpoint, PushPolicy.marker)
            until("Background delivery did not display a native notification") {
                manager.activeNotifications.any { it.id == PushNotice.id }
            }
            PushStore.update(context) {
                it.put("enabled", false).put("endpoint", "").put("pending", false).put("presented", false)
            }
            PushNotice.clear(context)
            UnifiedPush.unregister(context, instance)
            // The connector removes its token before sending UNREGISTER, so the
            // resulting remote callback is no longer mapped to this instance.
            assertNull(UnifiedPush.getSavedDistributor(context))
            publish(endpoint, PushPolicy.marker)
            Thread.sleep(1000)
            assertFalse(PushStore.read(context).optBoolean("pending"))
            assertTrue(manager.activeNotifications.none { it.id == PushNotice.id })
        } finally {
            PushStore.update(context) { it.put("enabled", false).put("pending", false).put("presented", false) }
            UnifiedPush.unregister(context, instance)
            PushNotice.clear(context)
            PushChannel.updateVisibility(context, false)
        }
    }
}
