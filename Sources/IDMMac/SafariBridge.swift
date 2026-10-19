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

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Where macOS thinks the extension lives: the paths of every copy it has registered.
    static func registeredPaths() -> [String] {
        run("/usr/bin/pluginkit", ["-mAvv", "-i", extensionID]).split(separator: "\n").compactMap { line in
            guard let r = line.range(of: "Path = ") else { return nil }
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Makes sure Safari lists the bundled extension: forgets copies registered at other places
    /// (the mounted DMG, an older install) and registers the one inside this app.
    /// Returns a short report for the setup window.
    @discardableResult
    static func registerExtension() -> String {
        guard let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("IDMMacSafari.appex"),
              FileManager.default.fileExists(atPath: appex.path) else { return "Uygulamanın içinde Safari uzantısı yok" }
        for old in registeredPaths() where old != appex.path { _ = run("/usr/bin/pluginkit", ["-r", old]) }
        _ = run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                ["-f", "-R", "-trusted", Bundle.main.bundlePath])
        _ = run("/usr/bin/pluginkit", ["-a", appex.path])
        _ = run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID])
        let now = registeredPaths()
        return now.contains(appex.path) ? "Kayıtlı: \(appex.path)" : "Kaydedilemedi (macOS bu kopyayı listelemedi): \(appex.path)"
    }
}
