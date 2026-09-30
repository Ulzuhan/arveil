package io.github.ulzuhan.arveil

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var attachments: AttachmentPicker? = null
    private var viewer: AttachmentViewer? = null
    private var updates: UpdateInstaller? = null
    private var links: MethodChannel? = null

    /// A link that opened the app before Dart asked for it.
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachments = AttachmentPicker(this, flutterEngine.dartExecutor.binaryMessenger)
        viewer = AttachmentViewer(this, flutterEngine.dartExecutor.binaryMessenger)
        updates = UpdateInstaller(this, flutterEngine.dartExecutor.binaryMessenger)
        // Links that open the app (ADR-012 §5). Only their text crosses:
        // Dart reads it and asks the person before anything happens.
        pendingLink = linkOf(intent)
        links = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.ulzuhan.arveil/links").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "initial") {
                    result.success(pendingLink)
                    pendingLink = null
                } else {
                    result.notImplemented()
                }
            }
        }
        // Sharing a contact link (ADR-012 §4) through the system's own sheet:
        // the app only hands over the text; the person picks where it goes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.github.ulzuhan.arveil/share")
            .setMethodCallHandler { call, result ->
                val text = call.argument<String>("text")
                if (call.method != "text" || text.isNullOrEmpty()) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                startActivity(Intent.createChooser(send, null))
                result.success(true)
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val link = linkOf(intent) ?: return
        links?.invokeMethod("open", link) ?: run { pendingLink = link }
    }

    private fun linkOf(intent: Intent?): String? =
        if (intent?.action == Intent.ACTION_VIEW) intent.dataString?.takeIf { it.length <= 4096 } else null

    override fun onResume() { super.onResume(); updates?.onResume() }
    override fun onPause() { updates?.onPause(); super.onPause() }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == AttachmentPicker.REQUEST) {
            attachments?.onResult(resultCode, data)
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        attachments?.close()
        attachments = null
        viewer?.close()
        viewer = null
        updates?.close()
        updates = null
        links?.setMethodCallHandler(null)
        links = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
