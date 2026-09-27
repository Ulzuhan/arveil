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
    ShareChannel.register(with: flutterViewController)
    LinkChannel.register(with: flutterViewController)

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

/// Sharing a contact link (ADR-012 §4) through the system's share menu. The
/// app only hands over the text; the person picks where it goes.
enum ShareChannel {
  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "io.github.ulzuhan.arveil/share",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak controller] call, result in
      guard call.method == "text",
        let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String, !text.isEmpty,
        let view = controller?.view
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let picker = NSSharingServicePicker(items: [text])
      let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
      picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
      result(true)
    }
  }
}

/// Links that open the app (ADR-012 §5). Only their text crosses: Dart
/// reads it and asks the person before anything happens. A link that
/// arrives before Dart asks waits here.
enum LinkChannel {
  private static var channel: FlutterMethodChannel?
  private static var pending: String?

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "io.github.ulzuhan.arveil/links",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "initial" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(pending)
      pending = nil
    }
    self.channel = channel
  }

  static func deliver(_ link: String) {
    guard link.count <= 4096 else { return }
    // Kept as well: Dart may not listen yet on a cold start, and it asks
    // for what is pending once it does. It ignores a link it already has.
    pending = link
    channel?.invokeMethod("open", arguments: link)
  }
}
