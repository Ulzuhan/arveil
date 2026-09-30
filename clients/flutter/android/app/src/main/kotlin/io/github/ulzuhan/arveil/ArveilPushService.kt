package io.github.ulzuhan.arveil

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage
import java.util.UUID

class ArveilPushService : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) = safely {
        val state = PushStore.read(this)
        if (!state.optBoolean("enabled") || instance != state.optString("instance")) return@safely
        val accepted = PushPolicy.endpoint(endpoint.url, state.optString("server"), BuildConfig.DEBUG)
        var changed = false
        PushStore.update(this) {
            it.put("error", if (accepted) "" else "endpoint")
            if (accepted && it.optString("endpoint") != endpoint.url) {
                it.put("endpoint", endpoint.url).put("revision", UUID.randomUUID().toString())
                changed = true
            }
        }
        PushChannel.changed()
        if (changed && !PushChannel.foreground) PushNotice.show(this, setup = true)
    }

    override fun onMessage(message: PushMessage, instance: String) = safely {
        val state = PushStore.read(this)
        if (!state.optBoolean("enabled") || instance != state.optString("instance") ||
            !message.content.contentEquals(PushPolicy.marker)) return@safely
        // The fixed marker is intentionally untrusted. No Flutter engine,
        // profile, message decryption or second executor is started here.
        val alreadyPending = state.optBoolean("pending")
        PushStore.update(this) { it.put("pending", true).put("hintRevision", UUID.randomUUID().toString()) }
        PushChannel.changed()
        if (!alreadyPending && !PushChannel.foreground) PushNotice.show(this)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) = failure(instance, "registration")
    override fun onUnregistered(instance: String) = safely {
        val state = PushStore.read(this)
        if (!state.optBoolean("enabled") || instance != state.optString("instance")) return@safely
        PushStore.update(this) {
            it.put("endpoint", "").put("revision", UUID.randomUUID().toString()).put("error", "registration")
        }
        PushChannel.changed()
    }
    private fun failure(instance: String, reason: String) = safely {
        if (instance == PushStore.read(this).optString("instance")) {
            PushStore.update(this) { it.put("error", reason) }
            PushChannel.changed()
        }
    }
    private fun safely(action: () -> Unit) { try { action() } catch (_: Exception) { /* No capabilities in logs. */ } }
}

object PushNotice {
    const val channel = "arveil.activity"
    const val id = 140
    const val openAction = "io.github.ulzuhan.arveil.OPEN_ACTIVITY"
    fun clear(context: Context) { NotificationManagerCompat.from(context).cancel(id) }
    fun show(context: Context, setup: Boolean = false) {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel,
                context.getString(R.string.push_channel), NotificationManager.IMPORTANCE_DEFAULT))
        }
        val intent = Intent(context, MainActivity::class.java).setAction(openAction)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val open = PendingIntent.getActivity(context, 140, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notice = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("Arveil")
            .setContentText(context.getString(if (setup) R.string.push_setup else R.string.push_activity))
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).build()
        try { manager.notify(id, notice) } catch (_: SecurityException) { /* Permission was revoked. */ }
    }
}
