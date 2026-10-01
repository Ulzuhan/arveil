import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate {
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
    AttachmentViewerChannel.register(with: flutterViewController)
    DesktopNotificationChannel.register(with: flutterViewController)

    super.awakeFromNib()
    self.delegate = self
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if DesktopNotificationChannel.shouldKeepRunning {
      sender.orderOut(nil)
      DesktopNotificationChannel.publishVisibility()
      return false
    }
    return true
  }
  func windowDidBecomeKey(_ notification: Notification) { DesktopNotificationChannel.publishVisibility() }
  func windowDidResignKey(_ notification: Notification) { DesktopNotificationChannel.publishVisibility() }
  func windowDidMiniaturize(_ notification: Notification) { DesktopNotificationChannel.publishVisibility() }
  func windowDidDeminiaturize(_ notification: Notification) { DesktopNotificationChannel.publishVisibility() }
}

/// Local notifications only. Neither APNs nor any remote provider is used.
final class DesktopNotificationChannel: NSObject, UNUserNotificationCenterDelegate {
  private static let shared = DesktopNotificationChannel()
  private var channel: FlutterMethodChannel?
  private var profileOpen = false
  private var statusItem: NSStatusItem?
  private var pending: String?
  private var openLabel = "Open Arveil"
  private var quitLabel = "Quit Arveil"
  private let defaults = UserDefaults.standard
  private let center = UNUserNotificationCenter.current()
  private var enabled: Bool { defaults.bool(forKey: "arveil.notifications.enabled") }
  private var background: Bool { defaults.bool(forKey: "arveil.notifications.background") }
  static var shouldKeepRunning: Bool { shared.profileOpen && shared.background }

  static func register(with controller: FlutterViewController) {
    shared.center.delegate = shared
    let channel = FlutterMethodChannel(name: "io.github.ulzuhan.arveil/notifications",
      binaryMessenger: controller.engine.binaryMessenger)
    shared.channel = channel
    channel.setMethodCallHandler { call, result in shared.handle(call, result) }
  }

  private func status(_ result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      DispatchQueue.main.async {
        result(["enabled": self.enabled && settings.authorizationStatus == .authorized,
          "background": self.background])
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    #if DEBUG
    // Acceptance hooks query the real OS and window; never present in releases.
    case "acceptanceInspect":
      center.getDeliveredNotifications { notices in
        DispatchQueue.main.async {
          result(["visible": NSApp.windows.first(where: { $0 is MainFlutterWindow })?.isVisible == true,
            "background": Self.shouldKeepRunning,
            "delivered": notices.filter { $0.request.identifier == "arveil.activity" }.count])
        }
      }
    case "acceptanceCloseWindow":
      if Self.shouldKeepRunning {
        NSApp.windows.first(where: { $0 is MainFlutterWindow })?.performClose(nil)
      }
      result(nil)
    case "acceptanceOpenWindow": Self.reopen(); result(nil)
    #endif
    case "status": status(result)
    case "takeOpen": result(pending); pending = nil
    case "profile":
      profileOpen = args["open"] as? Bool == true
      openLabel = args["openLabel"] as? String ?? openLabel
      quitLabel = args["quitLabel"] as? String ?? quitLabel
      if !profileOpen {
        center.removePendingNotificationRequests(withIdentifiers: ["arveil.activity"])
        center.removeDeliveredNotifications(withIdentifiers: ["arveil.activity"])
        pending = nil
      }
      updateMenu()
      Self.publishVisibility()
      result(nil)
    case "configure":
      defaults.set(args["background"] as? Bool == true, forKey: "arveil.notifications.background")
      updateMenu()
      if args["enabled"] as? Bool == true {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
          DispatchQueue.main.async {
            self.defaults.set(granted && error == nil, forKey: "arveil.notifications.enabled")
            self.status(result)
          }
        }
      } else {
        defaults.set(false, forKey: "arveil.notifications.enabled")
        center.removePendingNotificationRequests(withIdentifiers: ["arveil.activity"])
        center.removeDeliveredNotifications(withIdentifiers: ["arveil.activity"])
        status(result)
      }
    case "show":
      guard profileOpen, enabled,
        let token = args["token"] as? String, token.count == 64,
        token.allSatisfy({ $0.isHexDigit }),
        let title = args["title"] as? String, title.count <= 80,
        let body = args["body"] as? String, body.count <= 200
      else { result(false); return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      content.userInfo = ["token": token]
      center.add(UNNotificationRequest(identifier: "arveil.activity", content: content, trigger: nil)) { error in
        DispatchQueue.main.async { result(error == nil) }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func updateMenu() {
    if !Self.shouldKeepRunning {
      if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
      statusItem = nil
      return
    }
    let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Arveil")
    item.button?.toolTip = "Arveil"
    let menu = NSMenu()
    let open = NSMenuItem(title: openLabel, action: #selector(openWindow), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: quitLabel, action: #selector(quitApp), keyEquivalent: "")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  @objc private func openWindow() { Self.reopen() }
  @objc private func quitApp() { NSApp.terminate(nil) }
  static func reopen() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0 is MainFlutterWindow })?.makeKeyAndOrderFront(nil)
  }
  static func publishVisibility() {
    DispatchQueue.main.async {
      let window = NSApp.windows.first(where: { $0 is MainFlutterWindow })
      shared.channel?.invokeMethod("visibility", arguments:
        NSApp.isActive && window?.isVisible == true && window?.isKeyWindow == true)
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler(profileOpen && enabled ? [.banner, .sound] : [])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async {
      let token = response.notification.request.content.userInfo["token"] as? String ?? ""
      if self.profileOpen {
        self.channel?.invokeMethod("opened", arguments: token)
      } else { self.pending = token }
      Self.reopen()
      completionHandler()
    }
  }
}

/// Plaintext exists here only after an explicit external-opening confirmation.
/// Copies stay in the sandbox's temporary directory, excluded from backups.
enum AttachmentViewerChannel {
  private static let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("attachment-open", isDirectory: true)
  private static var timer: Timer?
  private static let worker = DispatchQueue(label: "arveil.attachment-opening")

  static func register(with controller: FlutterViewController) {
    worker.async { cleanExpired() }
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
      worker.async { cleanExpired() }
    }
    let channel = FlutterMethodChannel(name: "io.github.ulzuhan.arveil/attachment_viewer",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: Any],
        let name = args["name"] as? String, !name.isEmpty, name.count <= 240,
        name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
        name.rangeOfCharacter(from: .controlCharacters) == nil,
        let bytes = args["bytes"] as? FlutterStandardTypedData,
        bytes.data.count <= 25 * 1024 * 1024 - 16
      else { result(FlutterError(code: "invalid", message: "Invalid file.", details: nil)); return }
      worker.async {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
          cleanExpired()
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
          var excluded = directory
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try excluded.setResourceValues(values)
          let file = directory.appendingPathComponent(name)
          try bytes.data.write(to: file, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
          DispatchQueue.main.async {
            let opened = NSWorkspace.shared.open(file)
            if !opened { worker.async { try? FileManager.default.removeItem(at: directory) } }
            result(opened)
          }
        } catch {
          try? FileManager.default.removeItem(at: directory)
          DispatchQueue.main.async {
            result(FlutterError(code: "open", message: "Cannot prepare file.", details: nil))
          }
        }
      }
    }
  }

  private static func cleanExpired() {
    let cutoff = Date().addingTimeInterval(-3600)
    let directories = (try? FileManager.default.contentsOfDirectory(at: root,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
    for directory in directories {
      guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
        values.isDirectory == true, let modified = values.contentModificationDate, modified <= cutoff
      else { continue }
      try? FileManager.default.removeItem(at: directory)
    }
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
