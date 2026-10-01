package io.github.ulzuhan.arveil

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.unifiedpush.android.connector.UnifiedPush
import java.util.UUID

class PushChannel(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/push")
    private var permissionResult: MethodChannel.Result? = null
    private var permissionServer: String? = null
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
                        val previous = PushStore.read(activity)
                        if (previous.optString("owner") != owner) {
                            val instance = previous.optString("instance")
                            PushStore.update(activity) { it.keys().asSequence().toList().forEach(it::remove); it.put("owner", owner) }
                            if (instance.isNotEmpty()) UnifiedPush.unregister(activity, instance)
                            PushNotice.clear(activity)
                        }
                        result.success(status())
                    }
                    "enable" -> {
                        check(permissionResult == null)
                        val server = PushPolicy.server(call.argument<String>("server") ?: "", BuildConfig.DEBUG)
                        require(server != null)
                        require(UnifiedPush.getDistributors(activity).contains(distributor))
                        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            permissionResult = result
                            permissionServer = server
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
                        } else enable(server, result)
                    }
                    "retry" -> {
                        val state = PushStore.read(activity)
                        if (state.optBoolean("enabled")) register(state.optString("instance"))
                        result.success(status())
                    }
                    "disable" -> {
                        val instance = PushStore.read(activity).optString("instance")
                        PushStore.update(activity) {
                            it.put("enabled", false).put("endpoint", "").put("error", "")
                                .put("revision", UUID.randomUUID().toString()).put("pending", false).put("presented", false)
                        }
                        if (instance.isNotEmpty()) UnifiedPush.unregister(activity, instance)
                        PushNotice.clear(activity)
                        result.success(status())
                    }
                    "ack" -> {
                        PushStore.update(activity) {
                            if (it.optString("owner") == call.argument<String>("owner") &&
                                it.optString("revision") == call.argument<String>("revision")) {
                                it.put("applied", it.optString("revision"))
                            }
                        }
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
                    "takeOpen" -> { result.success(opened); opened = false }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("push", "Cannot update notification delivery.", null) }
        }
    }

    private fun enable(server: String, result: MethodChannel.Result) {
        try {
            if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) {
                PushStore.update(activity) { it.put("error", "permission") }
                result.success(status()); return
            }
            val previous = PushStore.read(activity)
            check(previous.optString("owner").isNotEmpty())
            val instance = if (previous.optBoolean("enabled") && previous.optString("server") == server)
                previous.optString("instance") else UUID.randomUUID().toString()
            if (previous.optString("instance").isNotEmpty() && previous.optString("instance") != instance)
                UnifiedPush.unregister(activity, previous.optString("instance"))
            PushStore.update(activity) {
                if (it.optString("instance") != instance) it.put("endpoint", "").put("revision", UUID.randomUUID().toString())
                it.put("instance", instance).put("enabled", true).put("server", server).put("error", "")
            }
            register(instance)
            result.success(status())
        } catch (_: Exception) { result.error("push", "Cannot enable notification delivery.", null) }
    }

    private fun register(instance: String) {
        UnifiedPush.saveDistributor(activity, distributor)
        UnifiedPush.register(activity, instance, "Arveil")
    }
    fun permission(granted: Boolean) {
        val result = permissionResult ?: return
        val server = permissionServer
        permissionResult = null; permissionServer = null
        if (granted && server != null) enable(server, result)
        else {
            try { PushStore.update(activity) { it.put("error", "permission") }; result.success(status()) }
            catch (_: Exception) { result.error("push", "Cannot read notification settings.", null) }
        }
    }
    private fun status(): Map<String, Any> {
        val state = PushStore.read(activity)
        return mapOf(
            "enabled" to state.optBoolean("enabled"), "server" to state.optString("server"),
            "owner" to state.optString("owner"), "endpoint" to state.optString("endpoint"),
            "revision" to state.optString("revision"), "applied" to state.optString("applied"),
            "pending" to state.optBoolean("pending"), "hintRevision" to state.optString("hintRevision"),
            "error" to state.optString("error"),
            "installed" to UnifiedPush.getDistributors(activity).contains(distributor),
            "permission" to NotificationManagerCompat.from(activity).areNotificationsEnabled()
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
        const val distributor = "io.heckel.ntfy"
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
