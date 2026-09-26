package io.github.ulzuhan.arveil

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
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
        var active: UpdateInstaller? = null
            private set
    }
    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private val packages = activity.packageManager
    private val installer = packages.packageInstaller
    private var pending: MethodChannel.Result? = null
    private var callback: PendingIntent? = null
    private var sessionId = -1
    private var action: String? = null
    private var confirmation: Intent? = null
    private var resumed = false
    @Volatile private var closed = false

    @Suppress("DEPRECATION")
    private fun info(path: String? = null): PackageInfo? {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        return if (path == null) packages.getPackageInfo(activity.packageName, flags)
               else packages.getPackageArchiveInfo(path, flags)
    }

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signer ->
            MessageDigest.getInstance("SHA-256").digest(signer.toByteArray()).joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }

    private fun allowed() = Build.VERSION.SDK_INT < 26 || packages.canRequestPackageInstalls()

    init {
        active = this
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "device" -> result.success(mapOf("build" to version(info()!!), "sdk" to Build.VERSION.SDK_INT,
                        "applicationId" to activity.packageName, "arm64" to Build.SUPPORTED_ABIS.contains("arm64-v8a")))
                    "allowed" -> result.success(allowed())
                    "permission" -> {
                        if (Build.VERSION.SDK_INT >= 26) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}")))
                        }
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
            } catch (_: Exception) {
                result.error("install", "Android could not start the requested operation", null)
            }
        }
    }

    private fun prepare(file: File, expectedBuild: Long, size: Long, digest: String) {
        var created = -1
        try {
            val directory = File(activity.cacheDir, "updates").canonicalFile
            require(file.name == "update.apk" && file.canonicalFile.parentFile == directory)
            require(file.isFile && file.length() == size && size in 1..UpdatePackage.MAX_BYTES)
            val installed = info()!!
            val candidate = info(file.path) ?: error("Invalid archive")
            require(UpdatePackage.compatible(installed.packageName, version(installed), signers(installed),
                candidate.packageName, version(candidate), signers(candidate), expectedBuild))
            if (Build.VERSION.SDK_INT >= 24) require(candidate.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT)
            // A crash during copying can leave an unsealed session behind.
            installer.mySessions.filter { !it.isSealed }.forEach { installer.abandonSession(it.sessionId) }
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
                } catch (_: Exception) { finish("install") }
            }
        } catch (_: Exception) {
            if (created >= 0) try { installer.abandonSession(created) } catch (_: Exception) { }
            // Neither the archive nor Android exception text is surfaced to Dart.
            try {
                file.takeIf { it.name == "update.apk" &&
                    it.canonicalFile == File(File(activity.cacheDir, "updates").canonicalFile, "update.apk") }?.delete()
            } catch (_: Exception) { /* Still report failure if removal is unavailable. */ }
            activity.runOnUiThread { if (!closed) finish("package") }
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

    fun onResume() { resumed = true; showConfirmation() }
    fun onPause() { resumed = false }

    private fun showConfirmation() {
        val intent = confirmation ?: return
        if (!resumed || closed) return
        confirmation = null
        try { activity.startActivity(intent) } catch (_: Exception) { finish("install") }
    }

    private fun finish(error: String?) {
        if (error != null && sessionId >= 0) try { installer.abandonSession(sessionId) } catch (_: Exception) { }
        callback?.cancel()
        callback = null
        confirmation = null
        sessionId = -1
        action = null
        val result = pending
        pending = null
        if (error == null) result?.success(null) else result?.error(error, "Installation did not complete", null)
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        if (active === this) active = null
        finish("cancelled")
        worker.shutdown()
    }
}
