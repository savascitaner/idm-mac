import Foundation

/// The bundled rqbit BitTorrent client, run as a local server that only listens on 127.0.0.1.
/// It keeps its own session on disk, so unfinished torrents survive restarts; MDM drives it
/// through its HTTP API.
@MainActor
final class TorrentService {
    static let shared = TorrentService()
    static let port = 39871

    private var process: Process?
    private var waiting: [(Bool) -> Void] = []

    static var executable: URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let b = Paths.bundledBin?.appendingPathComponent("rqbit").path { candidates.append(b) }
        candidates += ["/opt/homebrew/bin/rqbit", "/usr/local/bin/rqbit"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Starts rqbit if it isn't answering yet, then reports whether it is ready.
    func ensureRunning(_ done: @escaping (Bool) -> Void) {
        Self.call("GET", "/", timeout: 2) { r in
            if case .success = r {
                self.pushLimit()
                return done(true)
            }
            self.waiting.append(done)
            guard self.waiting.count == 1 else { return }
            self.launch()
            self.poll(tries: 0)
        }
    }

    private func launch() {
        guard let exe = Self.executable else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--http-api-listen-addr", "127.0.0.1:\(Self.port)", "server", "start",
                       "--persistence-location", Paths.support.appendingPathComponent("rqbit").path,
                       AppModel.shared.downloadDirectory]
        let logURL = Paths.support.appendingPathComponent("rqbit.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = log
            p.standardError = log
        }
        do {
            try p.run()
            process = p
        } catch {
            process = nil
        }
    }

    private func poll(tries: Int) {
        Self.call("GET", "/", timeout: 1) { r in
            if case .success = r { return self.finish(true) }
            guard tries < 40, self.process?.isRunning ?? false else { return self.finish(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll(tries: tries + 1) }
        }
    }

    private func finish(_ ok: Bool) {
        if ok { pushLimit() }
        let w = waiting
        waiting = []
        w.forEach { $0(ok) }
    }

    /// The download cap for all torrents (bytes per second, 0 = none). Uploads are not capped.
    private var limit = 0

    func setLimit(_ bytesPerSecond: Int) {
        limit = bytesPerSecond
        if process?.isRunning == true { pushLimit() }
    }

    private func pushLimit() {
        let body: [String: Any] = ["download_bps": limit > 0 ? limit as Any : NSNull(), "upload_bps": NSNull()]
        Self.call("POST", "/torrents/limits", body: try? JSONSerialization.data(withJSONObject: body),
                  contentType: "application/json") { _ in }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// One HTTP API call; JSON answers are decoded, the completion runs on the main thread.
    static func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     contentType: String? = nil, timeout: TimeInterval = 30,
                     completion: @escaping (Result<Any, Error>) -> Void) {
        var c = URLComponents(string: "http://127.0.0.1:\(port)\(path)")!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<Any, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(Failure(errorDescription: "Torrent motoru: \(text.isEmpty ? "HTTP \(http.statusCode)" : text)"))
            } else {
                result = .success(data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } ?? [:])
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

/// Downloads one torrent (magnet link, .torrent URL or .torrent file) through rqbit.
@MainActor
final class TorrentDownloader {
    private var record: DownloadRecord
    private let onEvent: (SegmentedDownloader.Event) -> Void
    private var generation = 0   // bumps when polling stops, so an old poll loop ends
    private var stopped = false
    private var name = ""
    private var total: Int64 = -1

    init(record: DownloadRecord, onEvent: @escaping (SegmentedDownloader.Event) -> Void) {
        self.record = record
        self.onEvent = onEvent
        name = record.fileName
        total = record.totalBytes
    }

    static func isTorrent(url: String, fileName: String = "", mime: String? = nil) -> Bool {
        if url.lowercased().hasPrefix("magnet:") { return true }
        if (mime ?? "").lowercased().contains("bittorrent") { return true }
        let path = URL(string: url)?.path ?? url
        return path.lowercased().hasSuffix(".torrent") || fileName.lowercased().hasSuffix(".torrent")
    }

    func start() {
        TorrentService.shared.ensureRunning { ok in
            guard !self.stopped else { return }
            guard ok else {
                return self.fail(TorrentService.executable == nil ? "Torrent motoru (rqbit) bulunamadı"
                                                                   : "Torrent motoru başlatılamadı")
            }
            if let hash = self.record.torrentHash {
                // rqbit remembers the torrent from its own session; just make sure it runs.
                TorrentService.call("POST", "/torrents/\(hash)/start") { r in
                    if case .failure = r { self.add() } else { self.watch(hash) }
                }
            } else {
                self.add()
            }
        }
    }

    /// Fetches .torrent files ourselves (with the browser's cookies), magnet links go as they are.
    private func add() {
        let src = record.url
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let u = URL(string: src) else { return fail("Geçersiz adres") }
            var req = URLRequest(url: u, timeoutInterval: 60)
            for (k, v) in record.headers { req.setValue(v, forHTTPHeaderField: k) }
            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, error == nil, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                          data.first == UInt8(ascii: "d") else {
                        return self.fail(".torrent dosyası alınamadı")
                    }
                    self.post(data, isURL: false)
                }
            }.resume()
        } else if src.hasPrefix("/") || src.hasPrefix("file:") {
            let path = URL(string: src)?.isFileURL == true ? URL(string: src)!.path : src
            guard let data = FileManager.default.contents(atPath: path) else { return fail(".torrent dosyası okunamadı") }
            post(data, isURL: false)
        } else {
            post(Data(src.utf8), isURL: true)
        }
    }

    private func post(_ body: Data, isURL: Bool) {
        let q = [URLQueryItem(name: "overwrite", value: "true"),
                 URLQueryItem(name: "output_folder", value: record.directory),
                 URLQueryItem(name: "is_url", value: isURL ? "true" : "false")]
        report() // shows "connecting" while a magnet link's metadata is fetched from peers
        TorrentService.call("POST", "/torrents", query: q, body: body, timeout: 600) { r in
            switch r {
            case .failure(let e):
                self.fail(e.localizedDescription)
            case .success(let json):
                let details = (json as? [String: Any])?["details"] as? [String: Any] ?? [:]
                guard let hash = details["info_hash"] as? String else { return self.fail("Torrent eklenemedi") }
                self.name = details["name"] as? String ?? self.name
                let files = details["files"] as? [[String: Any]] ?? []
                let size = files.reduce(Int64(0)) { $0 + ((($1["length"] as? NSNumber)?.int64Value) ?? 0) }
                if size > 0 { self.total = size }
                self.record.torrentHash = hash
                if self.stopped {
                    TorrentService.call("POST", "/torrents/\(hash)/pause") { _ in }
                    return
                }
                self.watch(hash)
            }
        }
    }

    private func watch(_ hash: String) {
        generation += 1
        poll(hash, generation)
    }

    private func poll(_ hash: String, _ gen: Int) {
        guard gen == generation, !stopped else { return }
        refresh(hash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.poll(hash, gen) }
    }

    private func refresh(_ hash: String) {
        TorrentService.call("GET", "/torrents/\(hash)/stats/v1", timeout: 5) { r in
            guard !self.stopped, case .success(let json) = r, let s = json as? [String: Any] else { return }
            let got = (s["progress_bytes"] as? NSNumber)?.int64Value ?? 0
            if let t = (s["total_bytes"] as? NSNumber)?.int64Value, t > 0 { self.total = t }
            let live = s["live"] as? [String: Any]
            let peers = ((live?["snapshot"] as? [String: Any])?["peer_stats"] as? [String: Any])?["live"] as? Int ?? 0
            if let err = s["error"] as? String, !err.isEmpty {
                return self.fail(err)
            }
            if s["finished"] as? Bool == true {
                self.generation += 1
                self.stopped = true
                let path = (self.record.directory as NSString).appendingPathComponent(self.name)
                if FileManager.default.fileExists(atPath: path) {
                    FileMeta.markDownloaded(URL(fileURLWithPath: path), from: self.record.url, referrer: self.record.pageURL)
                }
                // The download is done: stop sharing it and let rqbit forget it (the files stay).
                TorrentService.call("POST", "/torrents/\(hash)/forget") { _ in }
                var snap = self.snapshot(got: self.total > 0 ? self.total : got, peers: 0)
                snap.finalPath = path
                self.onEvent(.completed(snap))
                return
            }
            self.onEvent(.progress(self.snapshot(got: got, peers: peers)))
        }
    }

    private func report() {
        onEvent(.progress(snapshot(got: record.receivedBytes, peers: 0)))
    }

    private func snapshot(got: Int64, peers: Int) -> SegmentedDownloader.Snapshot {
        SegmentedDownloader.Snapshot(totalBytes: total, receivedBytes: got, segments: [], tempPath: nil, finalPath: nil,
                                     fileName: name, connections: peers, torrentHash: record.torrentHash)
    }

    private func fail(_ msg: String) {
        generation += 1
        stopped = true
        onEvent(.failed(msg, snapshot(got: record.receivedBytes, peers: 0)))
    }

    func pause() {
        stopped = true
        generation += 1
        if let h = record.torrentHash { TorrentService.call("POST", "/torrents/\(h)/pause") { _ in } }
    }

    /// Removes the torrent from rqbit; with `deleteFiles` the partly downloaded data goes too.
    static func forget(_ hash: String, deleteFiles: Bool) {
        TorrentService.shared.ensureRunning { ok in
            guard ok else { return }
            TorrentService.call("POST", "/torrents/\(hash)/\(deleteFiles ? "delete" : "forget")") { _ in }
        }
    }
}
