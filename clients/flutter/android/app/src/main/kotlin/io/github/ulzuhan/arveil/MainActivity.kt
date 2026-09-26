package io.github.ulzuhan.arveil

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var attachments: AttachmentPicker? = null
    private var updates: UpdateInstaller? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attachments = AttachmentPicker(this, flutterEngine.dartExecutor.binaryMessenger)
        updates = UpdateInstaller(this, flutterEngine.dartExecutor.binaryMessenger)
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
