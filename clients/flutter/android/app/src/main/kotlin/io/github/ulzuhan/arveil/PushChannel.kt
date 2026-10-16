package io.github.ulzuhan.arveil

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** The app's side of activity notices (ADR-014). Registering and removing
 * the watch key goes through the open Rust profile; this channel only keeps
 * the credentials it is handed, encrypted, and starts or stops the service. */
class PushChannel(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/push")
    private var permissionResult: MethodChannel.Result? = null
    private var permissionCredentials: ByteArray? = null
    private var opened = activity.intent?.action == PushNotice.openAction
    init {
        live = this
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(status())
                    "bind" -> {
                        val owner = call.argument<String>("owner") ?: ""
                        require(owner.matches(Regex("[a-f0-9]{64}")))
                        if (PushStore.read(activity).optString("owner") != owner) {
                            // Another identity on this phone: nothing of the
                            // previous one's notices survives.
                            WatchService.stop(activity)
                            PushStore.update(activity) { it.keys().asSequence().toList().forEach(it::remove); it.put("owner", owner) }
                            PushNotice.clear(activity)
                        } else if (WatchState.enabled(activity)) WatchService.start(activity)
                        result.success(status())
                    }
                    "enable" -> {
                        check(permissionResult == null)
                        val credentials = call.argument<ByteArray>("credentials")
                        require(credentials != null && credentials.size in 64..8192)
                        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            permissionResult = result
                            permissionCredentials = credentials
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
                        } else enable(credentials, result)
                    }
                    "disable" -> {
                        WatchService.stop(activity)
                        PushStore.update(activity) {
                            it.put("enabled", false).put("watch", "").put("error", "").put("listening", false)
                                .put("pending", false).put("presented", false).put("removal", true)
                        }
                        PushNotice.clear(activity)
                        result.success(status())
                    }
                    "synced" -> {
                        var clear = false
                        PushStore.update(activity) {
                            if (it.optString("owner") == call.argument<String>("owner") &&
                                it.optString("hintRevision") == call.argument<String>("revision")) {
                                it.put("pending", false).put("presented", false); clear = true
                            }
                        }
                        if (clear) PushNotice.clear(activity)
                        result.success(status())
                    }
                    "removed" -> {
                        PushStore.update(activity) { if (!it.optBoolean("enabled")) it.remove("removal") }
                        result.success(status())
                    }
                    "legacyCleared" -> {
                        PushStore.update(activity) { state -> WatchState.legacy.forEach(state::remove) }
                        result.success(status())
                    }
                    "battery" -> {
                        if (Build.VERSION.SDK_INT >= 23 && !batteryExempt()) {
                            activity.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(Uri.parse("package:${activity.packageName}")))
                        }
                        result.success(status())
                    }
                    "takeOpen" -> { result.success(opened); opened = false }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("push", "Cannot update notification delivery.", null) }
        }
    }

    private fun enable(credentials: ByteArray, result: MethodChannel.Result) {
        try {
            if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) {
                PushStore.update(activity) { it.put("error", "permission") }
                result.success(status()); return
            }
            check(PushStore.read(activity).optString("owner").isNotEmpty())
            PushStore.update(activity) {
                it.put("enabled", true).put("watch", Base64.encodeToString(credentials, Base64.NO_WRAP))
                    .put("error", "").put("listening", false)
                it.remove("removal")
            }
            WatchService.stop(activity)
            WatchService.start(activity)
            result.success(status())
        } catch (_: Exception) { result.error("push", "Cannot enable notification delivery.", null) }
    }

    fun permission(granted: Boolean) {
        val result = permissionResult ?: return
        val credentials = permissionCredentials
        permissionResult = null; permissionCredentials = null
        if (granted && credentials != null) enable(credentials, result)
        else {
            try { PushStore.update(activity) { it.put("error", "permission") }; result.success(status()) }
            catch (_: Exception) { result.error("push", "Cannot read notification settings.", null) }
        }
    }

    private fun batteryExempt(): Boolean =
        Build.VERSION.SDK_INT < 23 || activity.getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(activity.packageName) == true

    private fun status(): Map<String, Any> {
        val state = PushStore.read(activity)
        return mapOf(
            "enabled" to (state.optBoolean("enabled") && state.optString("watch").isNotEmpty()),
            "owner" to state.optString("owner"),
            "listening" to state.optBoolean("listening"),
            "pending" to state.optBoolean("pending"), "hintRevision" to state.optString("hintRevision"),
            "error" to state.optString("error"),
            "removal" to state.optBoolean("removal"),
            "legacy" to WatchState.hasLegacy(state),
            "legacyEnabled" to (WatchState.hasLegacy(state) && state.optBoolean("enabled")),
            "permission" to NotificationManagerCompat.from(activity).areNotificationsEnabled(),
            "battery" to batteryExempt()
        )
    }
    fun visibility(value: Boolean) = updateVisibility(activity, value)
    fun opened(intent: Intent) {
        if (intent.action == PushNotice.openAction) { opened = true; channel.invokeMethod("opened", null) }
    }
    fun close() {
        if (live === this) live = null
        updateVisibility(activity, false)
        permissionResult?.error("closed", "Activity closed.", null)
        permissionResult = null
        channel.setMethodCallHandler(null)
    }
    companion object {
        const val permissionRequest = 3140
        var foreground = false
            private set
        private var live: PushChannel? = null
        internal fun updateVisibility(context: Context, value: Boolean) {
            foreground = value
            if (value) changed() else PushNotice.deliverPending(context, false)
        }
        fun changed() { Handler(Looper.getMainLooper()).post { live?.channel?.invokeMethod("changed", null) } }
    }
}
