package io.github.ulzuhan.arveil

import android.app.Activity
import android.content.Intent
import android.os.CancellationSignal
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Reads the chosen document into bounded memory, without a plaintext cache. */
internal class AttachmentPicker(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val REQUEST = 0x4156
    }

    private val channel = MethodChannel(messenger, "io.github.ulzuhan.arveil/attachments")
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var cancellation: CancellationSignal? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "pick") {
                result.notImplemented()
            } else if (pending != null) {
                result.error("busy", "A file selection is already active", null)
            } else {
                pending = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    activity.startActivityForResult(intent, REQUEST)
                } catch (_: Exception) {
                    pending = null
                    result.error("unavailable", "File selection is unavailable", null)
                }
            }
        }
    }

    fun onResult(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending = null
            result.success(null)
            return
        }
        val signal = CancellationSignal()
        cancellation = signal
        // Neither the URI nor a filesystem path crosses the channel. Grants are
        // transient: never request persistable permission or create a cache file.
        worker.execute {
            try {
                val resolver = activity.contentResolver
                var name = "file"
                resolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null, null, null, signal,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                            require(cursor.getLong(sizeIndex) <= AttachmentInput.MAX_BYTES)
                        }
                    }
                }
                val bytes = resolver.openAssetFileDescriptor(uri, "r", signal)?.use { asset ->
                    asset.createInputStream().use { input ->
                        AttachmentInput.read(input) { signal.isCanceled }
                    }
                } ?: error("Document cannot be read")
                activity.runOnUiThread {
                    if (pending === result) {
                        pending = null
                        cancellation = null
                        result.success(mapOf("name" to name, "bytes" to bytes))
                    }
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    if (pending === result) {
                        pending = null
                        cancellation = null
                        // Provider errors can contain private document URIs.
                        result.error("read_failed", "The selected file could not be read within the size limit", null)
                    }
                }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        cancellation?.cancel()
        cancellation = null
        pending?.error("closed", "File selection was closed", null)
        pending = null
        worker.shutdownNow()
    }
}
