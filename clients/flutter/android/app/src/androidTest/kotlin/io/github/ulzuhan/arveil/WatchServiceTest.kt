package io.github.ulzuhan.arveil

import android.app.NotificationManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Device acceptance for ADR-014, driven by scripts/test_android_watch.py:
 * the service waits on a disposable relay with a watch key, shows only the
 * generic notice when mail arrives, and stops when the relay refuses the
 * key. Skipped without `-e credentials <hex>`. */
@RunWith(AndroidJUnit4::class)
class WatchServiceTest {
    private val tag = "ArveilWatchTest"

    @Test fun waitsNotifiesGenericallyAndStopsWhenRefused() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val hex = InstrumentationRegistry.getArguments().getString("credentials")
        assumeTrue("run through scripts/test_android_watch.py", !hex.isNullOrEmpty())
        val context = instrumentation.targetContext
        if (Build.VERSION.SDK_INT >= 33) {
            ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
                "pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")).use { it.readBytes() }
        }
        val credentials = hex!!.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val manager = context.getSystemService(NotificationManager::class.java)
        fun until(seconds: Int, what: String, check: () -> Boolean) {
            repeat(seconds * 10) { if (check()) return; Thread.sleep(100) }
            fail("timed out waiting for $what")
        }
        try {
            PushNotice.clear(context)
            PushStore.update(context) { state ->
                state.keys().asSequence().toList().forEach(state::remove)
                state.put("owner", "a".repeat(64)).put("enabled", true)
                    .put("watch", Base64.encodeToString(credentials, Base64.NO_WRAP))
            }
            PushChannel.updateVisibility(context, false)
            WatchService.start(context)

            until(30, "the subscription") { PushStore.read(context).optBoolean("listening") }
            // Android 12 and later may defer a foreground service's
            // notification by up to ten seconds.
            until(15, "the persistent notification") { manager.activeNotifications.any { it.id == WatchService.id } }
            Log.i(tag, "listening")

            until(90, "the activity notice") { manager.activeNotifications.any { it.id == PushNotice.id } }
            val notice = manager.activeNotifications.single { it.id == PushNotice.id }.notification
            assertEquals(context.getString(R.string.push_activity),
                notice.extras.getCharSequence("android.text")?.toString())
            assertTrue(PushStore.read(context).optBoolean("pending"))
            Log.i(tag, "notified")

            until(90, "the refusal") { PushStore.read(context).optString("error") == "refused" }
            assertFalse(PushStore.read(context).optBoolean("listening"))
            Log.i(tag, "refused")
        } finally {
            WatchService.stop(context)
            PushNotice.clear(context)
            PushStore.update(context) { state -> state.keys().asSequence().toList().forEach(state::remove) }
        }
    }
}
