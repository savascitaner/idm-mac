import Darwin
import Foundation

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("IDMMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var socket: String { support.appendingPathComponent("ipc.sock").path }
    static var database: URL { support.appendingPathComponent("downloads.json") }
    static var bin: URL { support.appendingPathComponent("bin", isDirectory: true) }
    static var cookies: URL { support.appendingPathComponent("cookies", isDirectory: true) }
    static var extensionDir: URL { support.appendingPathComponent("ChromeExtension", isDirectory: true) }

    static var bundledBin: URL? { Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) }
}

/// Locates yt-dlp and ffmpeg. yt-dlp is copied out of the (signed, read-only) bundle so it can update itself.
enum Tools {
    static var ytdlp: URL? {
        let fm = FileManager.default
        let local = Paths.bin.appendingPathComponent("yt-dlp")
        if fm.isExecutableFile(atPath: local.path) { return local }
        if let bundled = Paths.bundledBin?.appendingPathComponent("yt-dlp"), fm.isExecutableFile(atPath: bundled.path) {
            do {
                try fm.createDirectory(at: Paths.bin, withIntermediateDirectories: true)
                try fm.copyItem(at: bundled, to: local)
                FileMeta.removeQuarantine(local)
                return local
            } catch {
                return bundled
            }
        }
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where fm.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static var ffmpeg: URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let b = Paths.bundledBin?.appendingPathComponent("ffmpeg").path { candidates.append(b) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs `yt-dlp -U` at most once a day, because sites like YouTube break old versions quickly.
    static func updateYtdlpIfNeeded(force: Bool = false, completion: ((String) -> Void)? = nil) {
        let key = "lastYtdlpUpdate"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard force || now - last > 86_400 else { return }
        guard let exe = ytdlp, exe.path.hasPrefix(Paths.bin.path) else { return }
        UserDefaults.standard.set(now, forKey: key)
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["-U"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion?(out) }
        }
    }
}

enum FileMeta {
    /// Marks a downloaded file the way browsers do, so Gatekeeper still checks downloaded apps
    /// and Finder shows where the file came from.
    static func markDownloaded(_ file: URL, from source: String, referrer: String?) {
        let agent = "IDM Mac"
        let uuid = UUID().uuidString
        let q = String(format: "0081;%08x;%@;%@", Int(Date().timeIntervalSince1970), agent, uuid)
        setXattr(file, "com.apple.quarantine", Data(q.utf8))

        var froms = [source]
        if let r = referrer, !r.isEmpty { froms.append(r) }
        if let plist = try? PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0) {
            setXattr(file, "com.apple.metadata:kMDItemWhereFroms", plist)
        }
    }

    static func removeQuarantine(_ file: URL) {
        _ = file.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
    }

    private static func setXattr(_ file: URL, _ name: String, _ data: Data) {
        _ = file.path.withCString { path in
            data.withUnsafeBytes { buf in
                setxattr(path, name, buf.baseAddress, buf.count, 0, 0)
            }
        }
    }

    /// Returns a non-existing URL in `dir`, appending " (1)", " (2)"… if needed.
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 1
        while fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: candidate.path + ".idmpart") {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "indirme" }
        if s.utf8.count > 240 { s = String(s.prefix(200)) }
        return s
    }

    static func fileName(from url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return sanitize(last.isEmpty || last == "/" ? (url.host ?? "indirme") : last)
    }
}
