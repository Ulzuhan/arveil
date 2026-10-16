package io.github.ulzuhan.arveil

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject

/** What the activity service and the app share, in [PushStore]: whether
 * notices are on, for which identity, the watch credentials, and whether a
 * notice is waiting for a sync. Never the profile key or its database. */
object WatchState {
    fun enabled(context: Context): Boolean = credentials(context) != null && PushStore.read(context).optBoolean("enabled")
    fun credentials(context: Context): ByteArray? {
        val saved = PushStore.read(context).optString("watch")
        if (saved.isEmpty()) return null
        return try { Base64.decode(saved, Base64.NO_WRAP) } catch (_: IllegalArgumentException) { null }
    }
    fun update(context: Context, change: (JSONObject) -> Unit): JSONObject = PushStore.update(context, change)
    /** Fields the ntfy receiver of betas 5 and 6 left behind. */
    val legacy = listOf("instance", "server", "endpoint", "revision", "applied")
    fun hasLegacy(state: JSONObject) = state.optString("instance").isNotEmpty() || state.optString("endpoint").isNotEmpty()
}

object PushNotice {
    const val channel = "arveil.activity"
    const val id = 140
    const val openAction = "io.github.ulzuhan.arveil.OPEN_ACTIVITY"
    fun clear(context: Context) { NotificationManagerCompat.from(context).cancel(id) }
    /** Pending sync and presented notification are independent. A foreground
     * hint still needs one notice if the app leaves before sync succeeds. */
    fun deliverPending(context: Context, foreground: Boolean) {
        if (foreground) return
        try {
            val state = PushStore.read(context)
            if (!state.optBoolean("enabled") || !state.optBoolean("pending") || state.optBoolean("presented")) return
            if (show(context)) {
                PushStore.update(context) {
                    if (it.optBoolean("pending") && it.optString("hintRevision") == state.optString("hintRevision"))
                        it.put("presented", true)
                }
            }
        } catch (_: Exception) { /* Retry after a later hint or visibility change. */ }
    }

    fun show(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        val manager = context.getSystemService(NotificationManager::class.java)
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel,
                context.getString(R.string.push_channel), NotificationManager.IMPORTANCE_DEFAULT))
            if (manager.getNotificationChannel(channel)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        val intent = Intent(context, MainActivity::class.java).setAction(openAction)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val open = PendingIntent.getActivity(context, 140, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("Arveil")
            .setContentText(context.getString(R.string.push_activity))
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).build()
        return try { manager.notify(id, notice); true } catch (_: SecurityException) { false }
    }
}
