package io.github.ulzuhan.arveil

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var attachments: AttachmentPicker? = null
    private var updates: UpdateInstaller? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachments = AttachmentPicker(this, flutterEngine.dartExecutor.binaryMessenger)
        updates = UpdateInstaller(this, flutterEngine.dartExecutor.binaryMessenger)
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
        updates?.close()
        updates = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
