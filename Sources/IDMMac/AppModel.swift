import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var downloads: [DownloadRecord] = []
    @Published var browsersLinked: [String] = []
    @Published var speedHistory: [Double] = Array(repeating: 0, count: 60)
    /// Speed samples per download (one per second), for the detail panel.
    @Published var speedSeries: [UUID: [Double]] = [:]
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0

    /// `--demo` fills the window with sample downloads (used for the CI screenshot); nothing is saved.
    let isDemo = CommandLine.arguments.contains("--demo")

    @AppStorage("downloadDirectory") var downloadDirectory: String = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage("connections") var connections: Int = 8
    @AppStorage("maxParallel") var maxParallel: Int = 3
    @AppStorage("notify") var notify: Bool = true

    private var fileEngines: [UUID: SegmentedDownloader] = [:]
    private var videoEngines: [UUID: VideoDownloader] = [:]
    private var lastBytes: [UUID: (Int64, Date)] = [:]
    private var server: IPCServer?
    private var sleepActivity: NSObjectProtocol?
    private var saveTimer: Timer?
    private var speedTimer: Timer?
    private let videoWindows = VideoWindowController()
    private var dockHost: NSHostingView<DockTileView>?
    private var ticks = 0
    private var booted = false
    private var early: [[String: Any]] = []

    func boot() {
        if isDemo {
            DemoData.fill(self)
        } else {
            load()
        }
        refreshDisk()
        server = IPCServer(path: Paths.socket) { msg, reply in
            let id = msg["id"] as? String ?? ""
            reply(["type": "accepted", "id": id])
            Task { @MainActor in AppModel.shared.handle(msg) }
        }
        server?.start()
        browsersLinked = HostInstaller.install()
        _ = HostInstaller.exportExtension()
        _ = Tools.ytdlp
        Tools.updateYtdlpIfNeeded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.save() }
        }
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        SafariBridge.registerExtension()
        booted = true
        early.forEach(handle)
        early = []
        pump()
    }

    /// Messages can arrive (via idmmac:// links) before boot has loaded the saved list.
    func receive(_ msg: [String: Any]) {
        if booted { handle(msg) } else { early.append(msg) }
    }

    /// Runs once a second: speed graphs, Dock progress, disk space.
    private func tick() {
        if isDemo { DemoData.advance(self) }
        speedHistory.append(totalSpeed)
        if speedHistory.count > 60 { speedHistory.removeFirst(speedHistory.count - 60) }
        for d in downloads where d.state == .downloading {
            var s = speedSeries[d.id] ?? []
            s.append(d.speed)
            if s.count > 120 { s.removeFirst(s.count - 120) }
            speedSeries[d.id] = s
        }
        updateDock()
        ticks += 1
        if ticks % 10 == 0 { refreshDisk() }
    }

    func refreshDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: downloadDirectory).resourceValues(forKeys: keys) else { return }
        diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(v.volumeTotalCapacity ?? 0)
    }

    /// Draws a progress bar over the Dock icon while something is downloading.
    private func updateDock() {
        let tile = NSApp.dockTile
        if activeCount > 0, let p = overallProgress {
            if let host = dockHost {
                host.rootView = DockTileView(progress: p)
            } else {
                let host = NSHostingView(rootView: DockTileView(progress: p))
                host.frame = NSRect(origin: .zero, size: tile.size)
                tile.contentView = host
                dockHost = host
            }
            tile.display()
        } else if dockHost != nil {
            tile.contentView = nil
            dockHost = nil
            tile.display()
        }
    }

    // MARK: Incoming messages from the browser

    func handle(_ msg: [String: Any]) {
        let type = msg["type"] as? String ?? ""
        let cookies = Self.parseCookies(msg["cookies"])
        var headers: [String: String] = [:]
        if let ua = msg["userAgent"] as? String { headers["User-Agent"] = ua }
        if let r = msg["referrer"] as? String, !r.isEmpty { headers["Referer"] = r }

        switch type {
        case "download":
            guard let url = msg["url"] as? String else { return }
            addFile(url: url, fileName: msg["filename"] as? String ?? "", headers: headers, cookies: cookies,
                    browserMime: msg["mime"] as? String, originalURL: msg["originalUrl"] as? String)
        case "video":
            let page = msg["pageUrl"] as? String ?? ""
            let media = msg["mediaUrl"] as? String
            showVideoDialog(pageURL: page, mediaURL: media, title: msg["title"] as? String, headers: headers, cookies: cookies)
        case "url":
            guard let s = msg["url"] as? String, let u = URL(string: s) else { return }
            if Self.looksLikeVideoPage(u) {
                showVideoDialog(pageURL: s, mediaURL: nil, title: nil, headers: headers, cookies: cookies)
            } else {
                addFile(url: s, headers: headers, cookies: cookies)
            }
        default:
            break
        }
    }

    static func parseCookies(_ any: Any?) -> [BrowserCookie] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { c in
            guard let name = c["name"] as? String, let value = c["value"] as? String else { return nil }
            return BrowserCookie(name: name, value: value,
                                 domain: c["domain"] as? String ?? "",
                                 path: c["path"] as? String ?? "/",
                                 secure: c["secure"] as? Bool ?? false,
                                 httpOnly: c["httpOnly"] as? Bool ?? false,
                                 hostOnly: c["hostOnly"] as? Bool ?? false,
                                 expirationDate: (c["expirationDate"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    static func cookieHeader(_ cookies: [BrowserCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: Adding

    func addFile(url: String, fileName: String = "", headers: [String: String] = [:], cookies: [BrowserCookie] = [],
                 browserMime: String? = nil, originalURL: String? = nil) {
        var h = headers
        if !cookies.isEmpty { h["Cookie"] = Self.cookieHeader(cookies) }
        var name = FileMeta.sanitize(URL(fileURLWithPath: fileName).lastPathComponent)
        if fileName.isEmpty { name = "" }
        var rec = DownloadRecord(kind: .file, url: url, pageURL: headers["Referer"], fileName: name,
                                 directory: downloadDirectory, headers: h)
        rec.browserMime = browserMime
        rec.originalURL = originalURL
        downloads.insert(rec, at: 0)
        notifyUser("İndirme başladı", name.isEmpty ? url : name)
        pump()
    }

    func addVideo(info: VideoInfo, option: VideoOption, track: AudioTrack? = nil,
                  headers: [String: String], cookies: [BrowserCookie]) {
        insertVideo(url: info.webpageURL, title: info.title, thumbnail: info.thumbnail, option: option, track: track,
                    directory: downloadDirectory, index: nil, headers: headers, cookies: cookies)
        pump()
    }

    /// Queues every video of a playlist into its own folder; they download `maxParallel` at a time.
    /// `only` limits the download to the checked videos; their numbers keep the playlist order.
    func addPlaylist(_ list: PlaylistInfo, only: Set<String>? = nil, option: VideoOption, track: AudioTrack?,
                     headers: [String: String], cookies: [BrowserCookie]) {
        let dir = URL(fileURLWithPath: downloadDirectory)
            .appendingPathComponent(FileMeta.sanitize(list.title), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var count = 0
        for (i, e) in list.entries.enumerated() where only?.contains(e.id) ?? true {
            count += 1
            insertVideo(url: e.url, title: e.title, thumbnail: e.thumbnail ?? "https://i.ytimg.com/vi/\(e.id)/hqdefault.jpg",
                        option: option, track: track, directory: dir.path, index: i + 1, headers: headers, cookies: cookies)
        }
        notifyUser("Oynatma listesi sıraya alındı", "\(list.title): \(count) video")
        pump()
    }

    private func insertVideo(url: String, title: String, thumbnail: String?, option: VideoOption, track: AudioTrack?,
                             directory: String, index: Int?, headers: [String: String], cookies: [BrowserCookie]) {
        var label = option.audioOnly ? "ses" : option.label
        if let t = track { label += ", \(t.name)" }
        var rec = DownloadRecord(kind: .video, url: url, pageURL: headers["Referer"],
                                 fileName: (index.map { String(format: "%03d - ", $0) } ?? "") + title + " (\(label))",
                                 directory: directory, headers: headers, cookies: cookies)
        rec.videoFormat = YtDlp.format(option.format, audioOnly: option.audioOnly, language: track?.code)
        rec.videoSort = option.sort
        rec.audioOnly = option.audioOnly
        rec.thumbnail = thumbnail
        rec.audioLanguage = track?.code
        rec.playlistIndex = index
        // Playlist items go in queue order: pump() starts from the end of the list.
        downloads.insert(rec, at: 0)
    }

    func addFromUserInput(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        if Self.looksLikeVideoPage(u) {
            showVideoDialog(pageURL: s, mediaURL: nil, title: nil, headers: [:], cookies: [])
        } else {
            addFile(url: s)
        }
    }

    static func looksLikeVideoPage(_ u: URL) -> Bool {
        let host = u.host?.lowercased() ?? ""
        let sites = ["youtube.com", "youtu.be", "vimeo.com", "x.com", "twitter.com", "instagram.com",
                     "facebook.com", "tiktok.com", "dailymotion.com", "twitch.tv", "reddit.com"]
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func showVideoDialog(pageURL: String, mediaURL: String?, title: String?, headers: [String: String], cookies: [BrowserCookie]) {
        let req = VideoRequest(pageURL: pageURL, mediaURL: mediaURL, title: title ?? "", headers: headers, cookies: cookies)
        videoWindows.show(req)
    }

    // MARK: Scheduling

    /// Starts queued downloads up to the parallel limit.
    func pump() {
        let running = downloads.filter { $0.state == .downloading }.count
        var slots = max(1, maxParallel) - running
        for i in downloads.indices.reversed() where slots > 0 && downloads[i].state == .queued {
            start(at: i)
            slots -= 1
        }
        updateSleepAssertion()
    }

    private func start(at i: Int) {
        let rec = downloads[i]
        downloads[i].state = .downloading
        downloads[i].error = nil
        let id = rec.id
        let handler: (SegmentedDownloader.Event) -> Void = { [weak self] ev in
            Task { @MainActor in self?.apply(ev, to: id) }
        }
        switch rec.kind {
        case .file:
            let e = SegmentedDownloader(record: rec, maxConnections: connections, onEvent: handler)
            fileEngines[id] = e
            e.start()
        case .video:
            let e = VideoDownloader(record: rec, onEvent: handler)
            videoEngines[id] = e
            e.start()
        }
    }

    private func apply(_ ev: SegmentedDownloader.Event, to id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        func merge(_ s: SegmentedDownloader.Snapshot) {
            downloads[i].totalBytes = s.totalBytes
            downloads[i].receivedBytes = s.receivedBytes
            downloads[i].connections = s.connections
            if downloads[i].kind == .file {
                downloads[i].segments = s.segments
                downloads[i].tempPath = s.tempPath
                if !s.fileName.isEmpty { downloads[i].fileName = s.fileName }
            }
            let now = Date()
            if let (b, t) = lastBytes[id], now.timeIntervalSince(t) > 0.3 {
                let inst = Double(s.receivedBytes - b) / now.timeIntervalSince(t)
                downloads[i].speed = inst < 0 ? downloads[i].speed : downloads[i].speed * 0.6 + inst * 0.4
                lastBytes[id] = (s.receivedBytes, now)
            } else if lastBytes[id] == nil {
                lastBytes[id] = (s.receivedBytes, now)
            }
        }
        switch ev {
        case .progress(let s):
            guard downloads[i].state == .downloading else { return }
            merge(s)
        case .completed(let s):
            merge(s)
            downloads[i].state = .completed
            downloads[i].finalPath = s.finalPath
            if !s.fileName.isEmpty { downloads[i].fileName = s.fileName }
            downloads[i].speed = 0
            downloads[i].completedAt = Date()
            downloads[i].cookies = []
            downloads[i].headers["Cookie"] = nil
            finished(id)
            notifyUser("İndirme tamamlandı", downloads[i].fileName)
        case .failed(var msg, let s):
            merge(s)
            if msg == SegmentedDownloader.htmlInsteadOfFile, downloads[i].browserMime != nil {
                // Like IDM: if we can't fetch it, let the browser download it after all.
                let url = downloads[i].originalURL ?? downloads[i].url
                if server?.broadcast(["type": "fallback", "url": url]) == true {
                    msg += "; indirme Chrome'a geri verildi"
                }
                if let t = downloads[i].tempPath { try? FileManager.default.removeItem(atPath: t) }
            }
            downloads[i].state = .failed
            downloads[i].error = msg
            downloads[i].speed = 0
            finished(id)
            notifyUser("İndirme başarısız", "\(downloads[i].fileName): \(msg)")
        }
    }

    private func finished(_ id: UUID) {
        fileEngines[id] = nil
        videoEngines[id] = nil
        lastBytes[id] = nil
        save()
        pump()
    }

    // MARK: User actions

    func pause(_ id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isActive else { return }
        fileEngines[id]?.pause()
        videoEngines[id]?.pause()
        fileEngines[id] = nil
        videoEngines[id] = nil
        lastBytes[id] = nil
        downloads[i].state = .paused
        downloads[i].speed = 0
        save()
        pump()
    }

    func resume(_ id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        guard downloads[i].state == .paused || downloads[i].state == .failed else { return }
        if downloads[i].state == .failed, downloads[i].kind == .file,
           downloads[i].tempPath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            downloads[i].segments = []
            downloads[i].tempPath = nil
        }
        downloads[i].state = .queued
        pump()
    }

    func remove(_ id: UUID, deleteFile: Bool = false) {
        pause(id)
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        let rec = downloads[i]
        if let t = rec.tempPath, rec.state != .completed { try? FileManager.default.removeItem(atPath: t) }
        if deleteFile, let f = rec.finalPath { try? FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil) }
        downloads.remove(at: i)
        speedSeries[id] = nil
        save()
    }

    func clearCompleted() {
        downloads.removeAll { $0.state == .completed }
        save()
    }

    func reveal(_ rec: DownloadRecord) {
        if let f = rec.finalPath, FileManager.default.fileExists(atPath: f) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: rec.directory))
        }
    }

    func open(_ rec: DownloadRecord) {
        if let f = rec.finalPath { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
    }

    func pauseAll() { downloads.filter(\.isActive).forEach { pause($0.id) } }

    func resumeAll() {
        for d in downloads where d.state == .paused { resume(d.id) }
    }

    // MARK: Helpers

    var activeCount: Int { downloads.filter { $0.state == .downloading }.count }
    var totalSpeed: Double { downloads.filter { $0.state == .downloading }.reduce(0) { $0 + $1.speed } }
    var queuedCount: Int { downloads.filter { $0.state == .queued }.count }
    var pausedCount: Int { downloads.filter { $0.state == .paused }.count }

    /// Combined progress of the running downloads whose size is known.
    var overallProgress: Double? {
        let act = downloads.filter { $0.state == .downloading && $0.totalBytes > 0 }
        let total = act.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return nil }
        return Double(act.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(total)
    }

    var remainingBytes: Int64 {
        downloads.filter { $0.state == .downloading && $0.totalBytes > 0 }
            .reduce(Int64(0)) { $0 + max(0, $1.totalBytes - $1.receivedBytes) }
    }

    private var completedToday: [DownloadRecord] {
        downloads.filter { $0.state == .completed && $0.completedAt.map(Calendar.current.isDateInToday) == true }
    }

    var todayCount: Int { completedToday.count }
    var todayBytes: Int64 { completedToday.reduce(Int64(0)) { $0 + max($1.totalBytes, $1.receivedBytes) } }

    private func updateSleepAssertion() {
        let busy = downloads.contains { $0.state == .downloading }
        if busy && sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "İndirme sürüyor")
        } else if !busy, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
        NSApp?.dockTile.badgeLabel = busy ? "\(activeCount)" : nil
    }

    private func notifyUser(_ title: String, _ body: String) {
        guard notify else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") ?? false }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: Paths.database),
              var list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        for i in list.indices where list[i].state == .downloading || list[i].state == .queued {
            list[i].state = .paused
            list[i].speed = 0
        }
        downloads = list
    }

    func save() {
        guard !isDemo else { return }
        if let data = try? JSONEncoder().encode(downloads) {
            try? data.write(to: Paths.database, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.database.path)
        }
    }
}
