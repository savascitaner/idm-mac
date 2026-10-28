import Foundation

/// Safari gives extensions no downloads API, so downloads it starts by itself (a link opened from
/// another app, a redirect, a script) are caught on disk instead: Safari writes each one as a
/// "name.download" folder whose Info.plist names the source URL. MDM takes the URL over and, once its
/// own request works, removes Safari's partial copy, the way IDM takes over a browser download.
@MainActor
final class SafariWatcher: ObservableObject {
    static let shared = SafariWatcher()

    /// One line for the settings window: what is watched, or why it isn't.
    @Published private(set) var status = L("Başlatılmadı")
    static let logFile = Paths.support.appendingPathComponent("safari-izleme.log")

    private var watched: [String: DispatchSourceFileSystemObject] = [:]
    private var wanted: [String] = []
    private var seen: Set<String> = []
    /// URLs given back to Safari (the server wanted Safari's cookies or sent a page); Safari keeps those.
    private var handedBack: [String: Date] = [:]

    func start(_ dirs: [String]) {
        var all = dirs
        // Safari can be set to save somewhere other than Downloads.
        if let p = CFPreferencesCopyAppValue("DownloadsPath" as CFString, "com.apple.Safari" as CFString) as? String {
            all.append((p as NSString).expandingTildeInPath)
        }
        wanted = Array(Set(all.map { URL(fileURLWithPath: $0).standardizedFileURL.path }))
        log("başladı: \(wanted.joined(separator: ", "))")
        attach()
    }

    /// Opens each folder; macOS may still be asking for Downloads access, so retry until it works.
    private func attach() {
        var failed: [String] = []
        for d in wanted where watched[d] == nil {
            let fd = open(d, O_EVTONLY)
            guard fd >= 0, let names = try? FileManager.default.contentsOfDirectory(atPath: d) else {
                if fd >= 0 { close(fd) }
                failed.append(d)
                continue
            }
            // Downloads Safari had already started before MDM was opened are left alone.
            for n in names where n.hasSuffix(".download") { seen.insert(d + "/" + n) }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename],
                                                                queue: .main)
            src.setEventHandler { [weak self] in self?.scan(d) }
            src.setCancelHandler { close(fd) }
            src.resume()
            watched[d] = src
            log("izleniyor: \(d)")
        }
        if failed.isEmpty {
            status = L("Çalışıyor: ") + watched.keys.sorted().map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
        } else {
            status = L("Erişilemiyor: ") + failed.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
                + " (Sistem Ayarları > Gizlilik ve Güvenlik > Dosyalar ve Klasörler'de MDM'ye izin ver)"
            log("erişilemedi: \(failed.joined(separator: ", ")) errno=\(errno)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.attach() }
        }
    }

    /// Lets Safari download this URL itself the next time it tries.
    func handBack(_ url: String) {
        handedBack = handedBack.filter { $0.value.timeIntervalSinceNow > -600 }
        handedBack[url] = Date()
    }

    private func scan(_ dir: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        // Safari reuses a bundle name once the earlier one is gone (finished, cancelled, file deleted);
        // forget those paths so the same file downloaded again is noticed.
        seen = seen.filter { !$0.hasPrefix(dir + "/") || FileManager.default.fileExists(atPath: $0) }
        for n in names where n.hasSuffix(".download") {
            let path = dir + "/" + n
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            log("yeni Safari indirmesi: \(n)")
            take(path, tries: 0)
        }
    }

    /// Safari creates the folder first and writes Info.plist a moment later, so try a few times.
    private func take(_ path: String, tries: Int) {
        guard UserDefaults.standard.object(forKey: "safariTakeover") as? Bool ?? true else {
            return log("ayarlarda kapalı, Safari'ye bırakıldı")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return log("Safari indirmeyi MDM almadan bitirdi: \(path)")
        }
        guard let (url, referrer) = Self.source(path) else {
            if tries < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.take(path, tries: tries + 1) }
            } else {
                let inside = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                log("kaynak adres bulunamadı; içerik: \(inside)")
            }
            return
        }
        // The "where from" tag (page URL) can land a moment after Info.plist; wait for it briefly.
        if referrer == nil, tries < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.take(path, tries: tries + 1) }
            return
        }
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return log("http değil: \(url)") }
        if let t = handedBack[url], t.timeIntervalSinceNow > -600 { return log("Safari'ye geri verilmişti: \(url)") }
        if Self.isYouTubeStream(url) {
            // A googlevideo.com link is one stream of a YouTube video, tied to Safari's session (and IP):
            // fetching it directly gives 403 or only a piece. MDM downloads the video from its page with
            // yt-dlp instead, the way the "Bu videoyu indir" button does.
            guard let page = referrer, Self.isWatchPage(page) else {
                // Not a public video page (YouTube Studio's "İndir" hands out the owner's own file, which
                // yt-dlp can't get: it is sent to the sign-in page). Download the file itself.
                log("YouTube akışı ama izleme sayfasından gelmiyor (\(referrer ?? "sayfa yok")), dosya olarak indiriliyor: \(url)")
                return takeFile(path, url: url, referrer: referrer)
            }
            try? FileManager.default.removeItem(atPath: path)
            log("YouTube akışı, Safari'nin kopyası silindi, video penceresi açılıyor: \(page)")
            AppModel.shared.handle(["type": "video", "pageUrl": page, "userAgent": Self.userAgent])
            return
        }
        takeFile(path, url: url, referrer: referrer)
    }

    /// A public YouTube video page yt-dlp can read: watch, shorts, live, embed or youtu.be.
    nonisolated static func isWatchPage(_ s: String) -> Bool {
        guard let u = URL(string: s), let host = u.host?.lowercased() else { return false }
        if host == "youtu.be" { return u.path.count > 1 }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com"), host != "studio.youtube.com" else { return false }
        return ["/watch", "/shorts/", "/live/", "/embed/"].contains { u.path.hasPrefix($0) }
    }

    /// googlevideo.com (or its old *.c.youtube.com name) /videoplayback: a YouTube media stream.
    nonisolated static func isYouTubeStream(_ s: String) -> Bool {
        guard let u = URL(string: s), let host = u.host?.lowercased() else { return false }
        return (host.hasSuffix(".googlevideo.com") || host.hasSuffix(".c.youtube.com")) && u.path.contains("videoplayback")
    }

    private func takeFile(_ path: String, url: String, referrer: String?) {
        let name = String(URL(fileURLWithPath: path).lastPathComponent.dropLast(".download".count))
        // Safari's copy is kept until MDM's first request succeeds (AppModel removes it then). If the server
        // refuses MDM (it wants Safari's cookies, or the link is tied to Safari's IP like iCloud Private Relay
        // or a googlevideo.com link), Safari simply goes on and the reason shows in MDM's list.
        var headers = ["User-Agent": Self.userAgent]
        if let r = referrer { headers["Referer"] = r }
        log("devralınıyor: \(url) (sayfa: \(referrer ?? "yok"))")
        AppModel.shared.addFile(url: url, fileName: name, headers: headers, browserMime: "application/octet-stream",
                                safariPartial: path)
    }

    /// What MDM says it is when it fetches a download Safari started: Safari itself, so servers that
    /// look at the browser answer MDM the way they answered Safari.
    nonisolated static let userAgent: String = {
        let v = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v ?? "18.0") Safari/605.1.15"
    }()

    /// The source URL and the page it came from. The URL is in Safari's Info.plist; the page is the
    /// second entry of the "where from" tag Safari puts on the partial file.
    static func source(_ path: String) -> (String, String?)? {
        var froms = whereFrom(path)
        if froms.isEmpty {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for f in files where f != "Info.plist" {
                froms = whereFrom(path + "/" + f)
                if !froms.isEmpty { break }
            }
        }
        var url: String?
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            for key in ["DownloadEntryURL", "DownloadEntryOriginalURL", "URL"] {
                if let u = dict[key] as? String, !u.isEmpty { url = u; break }
            }
        }
        guard let u = url ?? froms.first else { return nil }
        return (u, froms.first { $0 != u })
    }

    /// Bytes loaded and total size of a Safari "name.download" folder: from its Info.plist when Safari writes
    /// the numbers there, else from the size of the partial file inside (total -1 when unknown).
    nonisolated static func progress(of path: String) -> (Int64, Int64) {
        var bytes: Int64 = 0
        var total: Int64 = -1
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            if let b = (dict["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value { bytes = b }
            if let t = (dict["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value, t > 0 { total = t }
        }
        if bytes == 0 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for f in files where f != "Info.plist" {
                bytes += ((try? FileManager.default.attributesOfItem(atPath: path + "/" + f))?[.size] as? Int64) ?? 0
            }
        }
        return (bytes, total)
    }

    private static func whereFrom(_ file: String) -> [String] {
        let attr = "com.apple.metadata:kMDItemWhereFroms"
        let n = getxattr(file, attr, nil, 0, 0, 0)
        guard n > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(file, attr, &buf, n, 0, 0) == n,
              let list = (try? PropertyListSerialization.propertyList(from: Data(buf), format: nil)) as? [String]
        else { return [] }
        return list.filter { $0.hasPrefix("http") }
    }

    func log(_ line: String) {
        Log.write("safari", line)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: Self.logFile) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: Self.logFile)
        }
    }
}
