import Foundation
import SafariServices
import os.log

private let kAppGroupId = "group.com.sixcleanroom.sixCleanRoom"
private let kRulesFileName = "rules_v1.json"

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

  func beginRequest(with context: NSExtensionContext) {
    let request = context.inputItems.first as? NSExtensionItem

    let message: Any?
    if #available(iOS 15.0, macOS 11.0, *) {
      message = request?.userInfo?[SFExtensionMessageKey]
    } else {
      message = request?.userInfo?["message"]
    }

    os_log(.default, "CleanRoomShield native message: %{public}@", String(describing: message))

    var payload: [String: Any] = [:]

    if let dict = message as? [String: Any],
       let cmd = dict["cmd"] as? String,
       cmd == "getRulesJson" {
      let json = Self.readRulesJsonString() ?? "{\"schemaVersion\":0}"
      payload["rulesJson"] = json
    } else {
      payload["rulesJson"] = Self.readRulesJsonString() ?? "{\"schemaVersion\":0}"
    }

    let response = NSExtensionItem()
    if #available(iOS 15.0, macOS 11.0, *) {
      response.userInfo = [SFExtensionMessageKey: payload]
    } else {
      response.userInfo = ["message": payload]
    }

    context.completeRequest(returningItems: [response], completionHandler: nil)
  }

  private static func readRulesJsonString() -> String? {
    guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroupId) else {
      return nil
    }
    let url = base.appendingPathComponent(kRulesFileName)
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
