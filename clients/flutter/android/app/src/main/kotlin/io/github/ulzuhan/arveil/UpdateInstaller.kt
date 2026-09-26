package io.github.ulzuhan.arveil

import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.net.toUri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executors

/** Only an explicit, non-exported PendingIntent can deliver installation status. */
class UpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        UpdateInstaller.active?.onResult(intent)
    }
}

internal class UpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        // Weak, so a destroyed activity is never kept alive through it.
        private var current = WeakReference<UpdateInstaller>(null)
        val active: UpdateInstaller? get() = current.get()

        /**
         * How long a return from the confirmation waits for Android's status
         * before asking about the session itself: some versions send none
         * when the confirmation is dismissed.
         */
        const val SETTLE_MILLIS = 2000L
    }
    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val packages = activity.packageManager
    private val installer = packages.packageInstaller
    private var pending: MethodChannel.Result? = null
    private var callback: PendingIntent? = null
    private var sessionId = -1
    private var action: String? = null
    private var confirmation: Intent? = null
    private var shown = false
    private var resumed = false
    @Volatile private var closed = false

    /**
     * A committed session whose outcome never arrived. It is left alone,
     * since the person may have confirmed it, until another attempt starts.
     */
    @Volatile private var unsettled = -1
    private val settle = Runnable { settle() }

    @Suppress("DEPRECATION")
    private fun info(path: String? = null): PackageInfo? {
        // For an archive, Android 9-10 fill signingInfo only when GET_SIGNATURES
        // is also asked for; without it the candidate had no signers and every
        // update was refused there. The legacy set is the fallback below.
        val flags = when {
            Build.VERSION.SDK_INT < 28 -> PackageManager.GET_SIGNATURES
            path == null -> PackageManager.GET_SIGNING_CERTIFICATES
            else -> PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
        }
        return if (path == null) packages.getPackageInfo(activity.packageName, flags)
               else packages.getPackageArchiveInfo(path, flags)
    }

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val current = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else null
        return UpdatePackage.signerDigests(current?.map { it.toByteArray() }, info.signatures?.map { it.toByteArray() })
    }

    private fun allowed() = Build.VERSION.SDK_INT < 26 || packages.canRequestPackageInstalls()

    // isSealed is only reached from API 26: UpdatePackage.abandonLeftover does not ask below it.
    @SuppressLint("NewApi")
    private fun leftoverSessions(): List<Int> = installer.mySessions
        .filter { session -> UpdatePackage.abandonLeftover(Build.VERSION.SDK_INT) { session.isSealed } }
        .map { it.sessionId }

    init {
        current = WeakReference(this)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "device" -> result.success(mapOf("build" to version(info()!!), "sdk" to Build.VERSION.SDK_INT,
                        "applicationId" to activity.packageName, "arm64" to Build.SUPPORTED_ABIS.contains("arm64-v8a")))
                    "allowed" -> result.success(allowed())
                    "permission" -> {
                        if (Build.VERSION.SDK_INT >= 26) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                "package:${activity.packageName}".toUri()))
                        }
                        result.success(null)
                    }
                    "open" -> {
                        // Dart passes the signed, HTTPS-only release notes link.
                        val link = call.argument<String>("url")!!.toUri()
                        require(link.scheme == "https")
                        activity.startActivity(Intent(Intent.ACTION_VIEW, link)
                            .addCategory(Intent.CATEGORY_BROWSABLE))
                        result.success(null)
                    }
                    "install" -> {
                        if (pending != null) result.error("busy", "Installation already active", null)
                        else if (!allowed()) result.error("permission", "Installation permission is required", null)
                        else {
                            val file = File(call.argument<String>("path")!!)
                            val expectedBuild = call.argument<Number>("build")!!.toLong()
                            val size = call.argument<Number>("size")!!.toLong()
                            val digest = call.argument<String>("sha256")!!
                            pending = result
                            worker.execute { prepare(file, expectedBuild, size, digest) }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.error("install", "Android could not start the requested operation", null)
            }
        }
    }

    private fun prepare(file: File, expectedBuild: Long, size: Long, digest: String) {
        var created = -1
        var accepted = false
        try {
            val directory = File(activity.cacheDir, "updates").canonicalFile
            require(file.name == "update.apk" && file.canonicalFile.parentFile == directory)
            require(file.isFile && file.length() == size && size in 1..UpdatePackage.MAX_BYTES)
            val installed = info()!!
            val candidate = info(file.path) ?: error("Invalid archive")
            require(UpdatePackage.compatible(installed.packageName, version(installed), signers(installed),
                candidate.packageName, version(candidate), signers(candidate), expectedBuild))
            require(candidate.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT)
            accepted = true
            // A new attempt replaces a session whose outcome never arrived.
            unsettled.takeIf { it >= 0 }?.let { installer.abandonSession(it) }
            unsettled = -1
            // A crash during copying can leave an unsealed session behind.
            leftoverSessions().forEach { installer.abandonSession(it) }
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(activity.packageName)
                setSize(size)
                if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
            created = installer.createSession(params)
            installer.openSession(created).use { session ->
                session.openWrite("base.apk", 0, size).use { output ->
                    file.inputStream().use { UpdatePackage.copyVerified(it, output, size, digest) }
                    session.fsync(output)
                }
            }
            val prepared = created
            activity.runOnUiThread {
                if (closed) { installer.abandonSession(prepared); return@runOnUiThread }
                try {
                    sessionId = prepared
                    action = "${activity.packageName}.UPDATE.${UUID.randomUUID()}"
                    val intent = Intent(activity, UpdateResultReceiver::class.java).setAction(action)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    callback = PendingIntent.getBroadcast(activity, prepared, intent, flags)
                    installer.openSession(prepared).use { it.commit(callback!!.intentSender) }
                } catch (_: Throwable) { finish("install") }
            }
        } catch (error: Throwable) {
            // Throwable, not Exception: an Error on this worker thread would end the app.
            if (created >= 0) try { installer.abandonSession(created) } catch (_: Throwable) { }
            // Neither the archive nor Android exception text is surfaced to Dart.
            val code = UpdatePackage.failure(accepted, error)
            if (code == "package") try {
                file.takeIf { it.name == "update.apk" &&
                    it.canonicalFile == File(File(activity.cacheDir, "updates").canonicalFile, "update.apk") }?.delete()
            } catch (_: Throwable) { /* Still report failure if removal is unavailable. */ }
            activity.runOnUiThread { if (!closed) finish(code) }
        }
    }

    @Suppress("DEPRECATION")
    fun onResult(intent: Intent) {
        if (closed || pending == null || intent.action != action ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != sessionId) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                confirmation = intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirmation == null) finish("install") else showConfirmation()
            }
            PackageInstaller.STATUS_SUCCESS -> finish(null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> finish("cancelled")
            else -> finish("install")
        }
    }

    fun onResume() {
        resumed = true
        // Back from the confirmation: give Android's status a moment first.
        if (shown && pending != null) {
            main.removeCallbacks(settle)
            main.postDelayed(settle, SETTLE_MILLIS)
        }
        showConfirmation()
    }

    fun onPause() {
        resumed = false
        main.removeCallbacks(settle)
    }

    private fun showConfirmation() {
        val intent = confirmation ?: return
        if (!resumed || closed) return
        confirmation = null
        try {
            activity.startActivity(intent)
            shown = true
        } catch (_: Exception) { finish("install") }
    }

    /**
     * No status arrived after the person came back from the confirmation, so
     * the screen would wait forever. A session that is gone was cancelled. One
     * that remains may have been confirmed and be installing, so it is not
     * abandoned here: Dart is told it was cancelled, and the next attempt
     * replaces the session if it is still there.
     */
    private fun settle() {
        if (closed || pending == null || !shown || !resumed) return
        val id = sessionId
        val remains = try { installer.getSessionInfo(id) != null } catch (_: Throwable) { false }
        if (remains) unsettled = id
        finish("cancelled", abandon = false)
    }

    private fun finish(error: String?, abandon: Boolean = true) {
        if (abandon && error != null && sessionId >= 0) try { installer.abandonSession(sessionId) } catch (_: Exception) { }
        main.removeCallbacks(settle)
        callback?.cancel()
        callback = null
        confirmation = null
        shown = false
        sessionId = -1
        action = null
        val result = pending
        pending = null
        if (error == null) result?.success(null) else result?.error(error, "Installation did not complete", null)
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        if (active === this) current.clear()
        // A committed session may be waiting for the person, who can still
        // confirm it after this activity is gone; only Dart's call ends here.
        finish("cancelled", abandon = false)
        worker.shutdown()
    }
}
