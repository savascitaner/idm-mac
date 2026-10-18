import AppKit
import Foundation
import SafariServices

/// Native side of the Safari extension. Safari runs it sandboxed, so it can't reach the app's socket;
/// instead it hands each message to the app through the idmmac:// URL scheme.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let appID = "com.savascitaner.idmmac"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let msg = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let id = msg["id"] as? String ?? ""
        var reply: [String: Any] = ["id": id]

        if msg["type"] as? String == "ping" {
            reply["type"] = "pong"
            reply["app"] = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.appID).isEmpty
        } else if let url = Self.bridgeURL(msg) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
            reply["type"] = "accepted"
        } else {
            reply["type"] = "error"
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// idmmac://message?t=<token>&d=<base64url JSON>. The token is generated at build time and only
    /// this extension and the app know it, so web pages can't trigger downloads with the scheme.
    static func bridgeURL(_ msg: [String: Any]) -> URL? {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "IDMBridgeToken") as? String,
              let data = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        let d = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var c = URLComponents()
        c.scheme = "idmmac"
        c.host = "message"
        c.queryItems = [URLQueryItem(name: "t", value: token), URLQueryItem(name: "d", value: d)]
        return c.url
    }
}
