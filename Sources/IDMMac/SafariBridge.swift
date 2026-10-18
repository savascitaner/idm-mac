import Foundation

/// The Safari extension runs sandboxed and can't reach the socket, so it sends
/// idmmac://message?t=<token>&d=<base64url JSON>. The token is generated at build time and
/// shared only with the extension, so a web page can't start downloads through the scheme.
enum SafariBridge {
    static let extensionID = "com.savascitaner.idmmac.Extension"

    static func message(from url: URL) -> [String: Any]? {
        guard url.scheme == "idmmac", url.host == "message",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = Bundle.main.object(forInfoDictionaryKey: "IDMBridgeToken") as? String,
              !token.isEmpty, !token.hasPrefix("__"),
              items.first(where: { $0.name == "t" })?.value == token,
              var d = items.first(where: { $0.name == "d" })?.value else { return nil }
        d = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        d += String(repeating: "=", count: (4 - d.count % 4) % 4)
        guard let data = Data(base64Encoded: d) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Makes sure Safari lists the bundled extension (Launch Services usually does this on first launch).
    static func registerExtension() {
        guard let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("IDMMacSafari.appex"),
              FileManager.default.fileExists(atPath: appex.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-a", appex.path]
        try? p.run()
    }
}
