import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !DesktopNotificationChannel.shouldKeepRunning
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    DesktopNotificationChannel.reopen()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// `arveil:` links from the link pages (ADR-012 §5). Universal links need
  /// an Apple Developer ID, so the page offers this scheme instead.
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme == "arveil" {
      LinkChannel.deliver(url.absoluteString)
    }
  }
}
