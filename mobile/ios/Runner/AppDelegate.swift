import Flutter
import UIKit

private enum AppGroupConfig {
  static let id = "group.com.sixcleanroom.sixCleanRoom"
  static let rulesFileName = "rules_v1.json"
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "six_clean_room/rules", binaryMessenger: messenger)
    channel.setMethodCallHandler(handleRulesChannel(call:result:))
  }

  private func handleRulesChannel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "appGroupPath":
      if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.id) {
        result(url.path)
      } else {
        result(
          FlutterError(
            code: "NO_APP_GROUP",
            message:
              "App Group container unavailable. Register \(AppGroupConfig.id) in Apple Developer and enable App Groups on the Runner target.",
            details: nil
          ))
      }
    case "writeRulesJson":
      guard let args = call.arguments as? [String: Any],
            let json = args["json"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Expected map with key json", details: nil))
        return
      }
      guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.id)
      else {
        result(FlutterError(code: "NO_APP_GROUP", message: "No App Group container", details: nil))
        return
      }
      let fileURL = base.appendingPathComponent(AppGroupConfig.rulesFileName)
      do {
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        result(fileURL.path)
      } catch {
        result(FlutterError(code: "WRITE_FAIL", message: error.localizedDescription, details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
