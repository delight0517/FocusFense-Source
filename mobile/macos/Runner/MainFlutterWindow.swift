import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Per-schedule application blocking.
    // Mirrors the Focusgate pattern: watch NSWorkspace launches + poll every
    // 2 s, and terminate any running app whose localized name matches a
    // target in the active schedule set. Targets are pushed from Dart via
    // a method channel — no IPC polling, no plist storage.
    AppBlockBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )

    FrontmostAppBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

// MARK: - App blocking (terminate running apps that match active targets)

private final class AppBlockBridge {
  static let shared = AppBlockBridge()

  private let channelName = "com.sixvpnblocker.app/app_block"
  private var targets: [String] = []          // already-lowercased display names
  private var monitorTimer: Timer?
  private var launchObserver: NSObjectProtocol?
  private var lastEnforcedAt: Date = .distantPast
  private var terminationCounts: [String: Int] = [:]

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "setTargets":
        let args = call.arguments as? [String: Any]
        let raw = (args?["targets"] as? [String]) ?? []
        self.targets = raw
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
          .filter { !$0.isEmpty }
        // Sweep right away so the user sees the effect instantly.
        self.enforceAgainstRunningApps()
        result([
          "ok": true,
          "count": self.targets.count
        ])
      case "getStatus":
        result([
          "targetCount": self.targets.count,
          "targets": self.targets,
          "monitorRunning": self.monitorTimer != nil,
          "lastEnforcedAtMs": Int64(self.lastEnforcedAt.timeIntervalSince1970 * 1000)
        ])
      case "kickNow":
        // Diagnostic: force an immediate sweep without changing targets.
        self.enforceAgainstRunningApps()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    startMonitoring()
  }

  // MARK: Monitoring

  private func startMonitoring() {
    if launchObserver == nil {
      launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] note in
        self?.handleAppLaunch(note: note)
      }
    }

    if monitorTimer == nil {
      // 2 s polling matches Focusgate. Short enough that the app dies before
      // it can render its first useful frame, long enough that we don't burn
      // battery scanning constantly.
      monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        self?.enforceAgainstRunningApps()
      }
    }
  }

  private func handleAppLaunch(note: Notification) {
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
      return
    }
    enforce(app: app)
  }

  private func enforceAgainstRunningApps() {
    lastEnforcedAt = Date()
    if targets.isEmpty { return }
    for app in NSWorkspace.shared.runningApplications {
      enforce(app: app)
    }
  }

  /// Terminate [app] if its lowercased display name matches any active target.
  /// Self-skip so we never kill the blocker itself; system processes (no
  /// display name) are also skipped to avoid harming Finder/loginwindow/etc.
  private func enforce(app: NSRunningApplication) {
    if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
    if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
    guard let raw = app.localizedName, !raw.isEmpty else { return }
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if name.isEmpty { return }

    let blocked = targets.contains { target in matches(name, target: target) }
    if !blocked { return }

    let terminated = app.terminate() || app.forceTerminate()
    if terminated {
      terminationCounts[name, default: 0] += 1
      NSLog("6VPN AppBlock: terminated \(raw) (count=\(terminationCounts[name] ?? 0))")
    } else {
      NSLog("6VPN AppBlock: failed to terminate \(raw)")
    }
  }

  /// Exact match, or substring for targets ≥ 5 chars (avoids false positives
  /// like "go" matching "Google Chrome"). Mirrors Focusgate's heuristic.
  private func matches(_ appName: String, target: String) -> Bool {
    if appName == target { return true }
    if target.count < 5 { return false }
    return appName.contains(target)
  }
}

// MARK: - Frontmost app (usage sampling)

private final class FrontmostAppBridge {
  static let shared = FrontmostAppBridge()

  private let channelName = "com.sixvpnblocker.app/frontmost"

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getFrontmost":
        guard let app = NSWorkspace.shared.frontmostApplication else {
          result([
            "bundleId": "",
            "localizedName": "",
            "processIdentifier": -1,
          ])
          return
        }
        let bid = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""
        result([
          "bundleId": bid,
          "localizedName": name,
          "processIdentifier": app.processIdentifier,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
