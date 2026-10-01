package io.github.ulzuhan.arveil

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Explicit external handoff. The profile and encrypted blobs are never exposed
 * by this provider. A viewer gets read access to one bounded-lived copy only. */
class AttachmentViewer(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/attachment_viewer")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val root = File(activity.cacheDir, "attachment-open")
    private val authority = "${activity.packageName}.attachment_viewer"
    private var closed = false
    private val cleanup = object : Runnable {
        override fun run() {
            if (!closed) {
                worker.execute { cleanExpired() }
                main.postDelayed(this, 30000)
            }
        }
    }

    init {
        cleanup.run()
        channel.setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name")
            val bytes = call.argument<ByteArray>("bytes")
            if (name.isNullOrBlank() || name.length > 240 || name == "." || name == ".." ||
                name.any { it == '/' || it == '\\' || it.code < 32 } ||
                bytes == null || bytes.size > 25 * 1024 * 1024 - 16) {
                result.error("invalid", "Invalid file.", null)
                return@setMethodCallHandler
            }
            worker.execute {
                var prepared: File? = null
                try {
                    cleanExpired()
                    val directory = File(root, UUID.randomUUID().toString())
                    prepared = directory
                    check(directory.mkdirs())
                    val file = File(directory, name)
                    file.outputStream().use { it.write(bytes) }
                    val uri = FileProvider.getUriForFile(activity, authority, file)
                    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
                        ?: "application/octet-stream"
                    main.post {
                        if (closed) {
                            directory.deleteRecursively()
                            result.error("closed", "Viewer closed.", null)
                        } else {
                            try {
                                val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).apply {
                                    clipData = ClipData.newRawUri("", uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                // Resolve the real view intent: a chooser itself can launch even
                                // when no app handles the underlying file type.
                                if (view.resolveActivity(activity.packageManager) == null) {
                                    directory.deleteRecursively()
                                    result.success(false)
                                } else {
                                    activity.startActivity(Intent.createChooser(view, null))
                                    result.success(true)
                                }
                            } catch (_: ActivityNotFoundException) {
                                directory.deleteRecursively()
                                result.success(false)
                            } catch (_: Exception) {
                                directory.deleteRecursively()
                                result.error("open", "Cannot open file.", null)
                            }
                        }
                    }
                } catch (_: Exception) {
                    prepared?.deleteRecursively()
                    main.post { result.error("open", "Cannot prepare file.", null) }
                }
            }
        }
    }

    private fun cleanExpired() {
        val cutoff = System.currentTimeMillis() - 60 * 60 * 1000
        root.listFiles()?.filter { it.isDirectory && it.lastModified() <= cutoff }?.forEach { dir ->
            dir.listFiles()?.filter { it.isFile }?.forEach { file ->
                try {
                    activity.revokeUriPermission(FileProvider.getUriForFile(activity, authority, file),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Exception) { /* No retained grants is already the desired state. */ }
            }
            dir.deleteRecursively()
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        main.removeCallbacks(cleanup)
        worker.shutdown()
    }
}
