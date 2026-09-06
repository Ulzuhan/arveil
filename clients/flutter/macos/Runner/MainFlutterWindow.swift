import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    ProfileChannel.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// Keeping the profile out of the platform's backups.
///
/// Exclusion is not encryption and does not stand in for it: it keeps the
/// encrypted database from travelling to a cloud account whose protection
/// this application does not control. The attribute is set on every start,
/// because a directory that was replaced does not keep it.
enum ProfileChannel {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "arveil/profile",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let path = call.arguments as? String else {
        result(
          FlutterError(
            code: "bad-argument", message: "a path is required", details: nil))
        return
      }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "not-excluded",
            message: "the profile could not be excluded from backups",
            details: error.localizedDescription))
      }
    }
  }
}
