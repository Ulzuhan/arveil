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
    UpdateChannel.register(with: flutterViewController)

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

/// What the update notice needs from the system: the installed build, the
/// macOS version and the architecture, and opening a signed HTTPS link in
/// the browser. The Mac app never downloads or installs an update itself.
enum UpdateChannel {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "io.github.ulzuhan.arveil/updates",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "device":
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafeBytes(of: &machine.machine) {
          String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        result([
          "build": Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
          "applicationId": Bundle.main.bundleIdentifier ?? "",
          "arm64": architecture == "arm64",
          "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ])
      case "open":
        guard let text = (call.arguments as? [String: Any])?["url"] as? String,
          let url = URL(string: text), url.scheme == "https"
        else {
          result(
            FlutterError(code: "bad-argument", message: "an HTTPS link is required", details: nil))
          return
        }
        result(NSWorkspace.shared.open(url) ? nil : FlutterError(
          code: "browser", message: "no application opened the link", details: nil))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

