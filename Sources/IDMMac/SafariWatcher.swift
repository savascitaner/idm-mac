import Foundation

/// Safari gives extensions no downloads API, so downloads it starts by itself (a link opened from
/// another app, a redirect, a script) are caught on disk instead: Safari writes each one as a
/// "name.download" folder whose Info.plist names the source URL. MDM takes the URL over and removes
/// Safari's partial copy, the way IDM takes over a browser download.
@MainActor
final class SafariWatcher {
    static let shared = SafariWatcher()

    private var sources: [DispatchSourceFileSystemObject] = []
    private var seen: Set<String> = []
    /// URLs given back to Safari (the server wanted Safari's cookies or sent a page); Safari keeps those.
    private var handedBack: [String: Date] = [:]

    func start(_ dirs: [String]) {
        for d in Set(dirs.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            let fd = open(d, O_EVTONLY)
            guard fd >= 0 else { continue }
            // Downloads Safari had already started before MDM was opened are left alone.
            for n in names(in: d) { seen.insert(d + "/" + n) }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.scan(d) }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    /// Lets Safari download this URL itself the next time it tries.
    func handBack(_ url: String) {
        handedBack = handedBack.filter { $0.value.timeIntervalSinceNow > -600 }
        handedBack[url] = Date()
    }

    private func names(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".download") }
    }

    private func scan(_ dir: String) {
        for n in names(in: dir) {
            let path = dir + "/" + n
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            take(path, tries: 0)
        }
    }

    /// Safari creates the folder first and writes Info.plist a moment later, so try a few times.
    private func take(_ path: String, tries: Int) {
        guard UserDefaults.standard.object(forKey: "safariTakeover") as? Bool ?? true else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let url = Self.sourceURL(path) else {
            if tries < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.take(path, tries: tries + 1) }
            }
            return
        }
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              handedBack[url].map({ $0.timeIntervalSinceNow < -600 }) ?? true else { return }
        let name = String(URL(fileURLWithPath: path).lastPathComponent.dropLast(".download".count))
        try? FileManager.default.removeItem(atPath: path)
        AppModel.shared.addFile(url: url, fileName: name, browserMime: "application/octet-stream", fallback: "safari")
    }

    /// The source URL from Safari's Info.plist, or from the "where from" tag on the partial file.
    static func sourceURL(_ path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
           let url = dict["DownloadEntryURL"] as? String, !url.isEmpty {
            return url
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for f in files where f != "Info.plist" {
            if let url = whereFrom(path + "/" + f) { return url }
        }
        return nil
    }

    private static func whereFrom(_ file: String) -> String? {
        let attr = "com.apple.metadata:kMDItemWhereFroms"
        let n = getxattr(file, attr, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(file, attr, &buf, n, 0, 0) == n,
              let list = (try? PropertyListSerialization.propertyList(from: Data(buf), format: nil)) as? [String]
        else { return nil }
        return list.first { $0.hasPrefix("http") }
    }
}
