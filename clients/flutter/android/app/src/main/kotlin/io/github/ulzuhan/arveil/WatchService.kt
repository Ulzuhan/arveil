package io.github.ulzuhan.arveil

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.util.UUID
import kotlin.concurrent.thread

/** Keeps one watch session open while notices are enabled (ADR-014). The
 * relay says only that this device's mailbox stopped being empty; the
 * notification is generic and the profile stays closed. */
class WatchService : Service() {
    @Volatile private var running = false
    private var worker: Thread? = null
    private var network: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!WatchState.enabled(this)) { stopSelf(); return START_NOT_STICKY }
        startInForeground()
        if (worker == null) {
            running = true
            worker = thread(name = "arveil-watch") { loop() }
            watchNetwork()
        }
        return START_STICKY
    }

    private fun loop() {
        try {
            while (running) {
                val credentials = WatchState.credentials(this) ?: break
                val generation = WatchNative.reserve()
                if (!running) break
                when (WatchNative.run(generation, credentials, keepaliveSeconds) { onEvent(it) }) {
                    WatchNative.REFUSED, WatchNative.INVALID -> {
                        // The key is gone (rotated, revoked or removed). The
                        // app registers a new one the next time it opens.
                        WatchState.update(this) { it.put("error", "refused").put("listening", false) }
                        PushChannel.changed()
                        break
                    }
                }
            }
        } catch (_: Throwable) { /* Never log credentials; the app shows the state. */ }
        if (running) stopSelf()
    }

    private fun onEvent(event: Int): Boolean {
        try {
            when (event) {
                WatchNative.LISTENING -> WatchState.update(this) { it.put("listening", true).put("error", "") }
                WatchNative.DISCONNECTED -> WatchState.update(this) { it.put("listening", false) }
                WatchNative.ACTIVITY -> {
                    WatchState.update(this) {
                        if (!it.optBoolean("pending")) it.put("presented", false)
                        it.put("pending", true).put("hintRevision", UUID.randomUUID().toString())
                    }
                    PushNotice.deliverPending(this, PushChannel.foreground)
                }
            }
            PushChannel.changed()
        } catch (_: Exception) { /* A storage failure must not end the wait. */ }
        return running
    }

    /** A new network usually means the old socket is dead: reconnect now
     * rather than after the next failed keepalive. */
    private fun watchNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        var first = true
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (first) { first = false; return }
                WatchNative.stop()
            }
        }
        try { manager.registerDefaultNetworkCallback(callback); network = callback } catch (_: Exception) { }
    }

    override fun onDestroy() {
        running = false
        WatchNative.stop()
        network?.let { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it) }
        network = null
        worker = null
        WatchState.update(this) { it.put("listening", false) }
        PushChannel.changed()
        super.onDestroy()
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel,
                getString(R.string.watch_channel), NotificationManager.IMPORTANCE_MIN).apply { setShowBadge(false) })
        }
        val open = PendingIntent.getActivity(this, 141,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice: Notification = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("Arveil")
            .setContentText(getString(R.string.watch_running)).setContentIntent(open)
            .setOngoing(true).setSilent(true).setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET).build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(id, notice, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(id, notice)
    }

    companion object {
        const val id = 141
        const val channel = "arveil.watch"
        /** Below the idle limits of common tunnels and NATs; measured per
         * route during device acceptance (ADR-014, open questions). */
        const val keepaliveSeconds = 90

        fun start(context: Context) {
            val intent = Intent(context, WatchService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
        fun stop(context: Context) { context.stopService(Intent(context, WatchService::class.java)) }
    }
}

/** Starts the service again after a reboot or an update, if enabled. */
class WatchBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try { if (WatchState.enabled(context)) WatchService.start(context) } catch (_: Exception) { }
    }
}
