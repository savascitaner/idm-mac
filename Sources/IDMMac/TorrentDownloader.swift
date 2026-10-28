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
        guard let exe = Self.executable else { return Log.torrent("rqbit not found (bundle bin or Homebrew)") }
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
        p.terminationHandler = { proc in
            let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(800)) } ?? ""
            Log.torrent("rqbit exited with status \(proc.terminationStatus); rqbit.log tail: \(tail)")
        }
        do {
            try p.run()
            process = p
            Log.torrent("rqbit started: \(exe.path) \(p.arguments?.joined(separator: " ") ?? "")")
        } catch {
            process = nil
            Log.torrent("rqbit could not be started: \(exe.path): \(error.localizedDescription)")
        }
    }

    private func poll(tries: Int) {
        Self.call("GET", "/", timeout: 1) { r in
            if case .success = r { return self.finish(true) }
            guard tries < 40, self.process?.isRunning ?? false else {
                Log.torrent("rqbit did not answer on 127.0.0.1:\(Self.port) (tries \(tries), running \(self.process?.isRunning ?? false))")
                return self.finish(false)
            }
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

/// What MDM needs from a .torrent file: its files, trackers and HTTP web seeds (BEP 19).
struct TorrentMeta {
    struct File {
        var path: [String]
        var length: Int64
    }

    var name: String
    var files: [File]
    var multiFile: Bool
    var trackers: [String]
    var webSeeds: [String]
    var isPrivate: Bool

    var total: Int64 { files.reduce(0) { $0 + $1.length } }

    init?(_ data: Data) {
        guard let root = Bencode.decode(data) as? [String: Any], let info = root["info"] as? [String: Any] else { return nil }
        func text(_ v: Any?) -> String? { (v as? Data).map { String(decoding: $0, as: UTF8.self) } }
        guard let n = text(info["name.utf-8"]) ?? text(info["name"]), !n.isEmpty else { return nil }
        name = n
        if let list = info["files"] as? [[String: Any]] {
            multiFile = true
            files = list.compactMap { f in
                guard let len = f["length"] as? Int64,
                      let parts = (f["path.utf-8"] as? [Any] ?? f["path"] as? [Any])?.compactMap(text), !parts.isEmpty else { return nil }
                return File(path: parts, length: len)
            }
        } else {
            multiFile = false
            files = [File(path: [], length: info["length"] as? Int64 ?? 0)]
        }
        var tr: [String] = text(root["announce"]).map { [$0] } ?? []
        for tier in root["announce-list"] as? [Any] ?? [] {
            for t in (tier as? [Any] ?? []).compactMap(text) where !tr.contains(t) { tr.append(t) }
        }
        trackers = tr
        if let one = text(root["url-list"]) {
            webSeeds = [one]
        } else {
            webSeeds = (root["url-list"] as? [Any] ?? []).compactMap(text)
        }
        webSeeds = webSeeds.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        isPrivate = info["private"] as? Int64 == 1
    }

    /// The file's address on a web seed, as BEP 19 builds it.
    func url(of file: File, on seed: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var s = seed
        if multiFile {
            if !s.hasSuffix("/") { s += "/" }
            s += ([name] + file.path).map(enc).joined(separator: "/")
        } else if s.hasSuffix("/") {
            s += enc(name)
        }
        return URL(string: s)
    }

    /// Where the file goes on disk; nil for a path that would leave the download folder.
    func localPath(of file: File, in directory: String) -> String? {
        let parts = [name] + file.path
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return nil }
        return parts.reduce(directory) { ($0 as NSString).appendingPathComponent($1) }
    }
}

/// Just enough bencode to read a .torrent file.
enum Bencode {
    static func decode(_ data: Data) -> Any? {
        let d = Data(data)
        var i = d.startIndex
        return value(d, &i)
    }

    private static func value(_ d: Data, _ i: inout Data.Index) -> Any? {
        guard i < d.endIndex else { return nil }
        switch d[i] {
        case UInt8(ascii: "i"):
            guard let e = d[(i + 1)...].firstIndex(of: UInt8(ascii: "e")),
                  let n = Int64(String(decoding: d[(i + 1)..<e], as: UTF8.self)) else { return nil }
            i = e + 1
            return n
        case UInt8(ascii: "l"):
            i += 1
            var out: [Any] = []
            while i < d.endIndex, d[i] != UInt8(ascii: "e") {
                guard let v = value(d, &i) else { return nil }
                out.append(v)
            }
            guard i < d.endIndex else { return nil }
            i += 1
            return out
        case UInt8(ascii: "d"):
            i += 1
            var out: [String: Any] = [:]
            while i < d.endIndex, d[i] != UInt8(ascii: "e") {
                guard let k = value(d, &i) as? Data, let v = value(d, &i) else { return nil }
                out[String(decoding: k, as: UTF8.self)] = v
            }
            guard i < d.endIndex else { return nil }
            i += 1
            return out
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            guard let c = d[i...].firstIndex(of: UInt8(ascii: ":")),
                  let n = Int(String(decoding: d[i..<c], as: UTF8.self)), n >= 0, n <= d.endIndex - (c + 1) else { return nil }
            i = c + 1 + n
            return d.subdata(in: (c + 1)..<i)
        default:
            return nil
        }
    }
}

/// Downloads one torrent (magnet link, .torrent URL or .torrent file) through rqbit. When nobody
/// shares the torrent but its .torrent file lists HTTP web seeds (archive.org does this for every
/// item), MDM fetches the files from there itself: rqbit does not speak web seeds.
@MainActor
final class TorrentDownloader {
    /// No new data for this long while rqbit runs the torrent means the swarm can't deliver it.
    static let stallSeconds: TimeInterval = 45

    private var record: DownloadRecord
    private let onEvent: (SegmentedDownloader.Event) -> Void
    private var generation = 0   // bumps when polling stops, so an old poll loop ends
    private var stopped = false
    private var name = ""
    private var total: Int64 = -1
    private var meta: TorrentMeta?
    private var note: String?

    // What rqbit last reported, to notice stalls and log changes only.
    private var lastState = ""
    private var lastBytes: Int64 = -1
    private var lastChange = Date()
    private var lastLog = Date.distantPast
    private var dhtLogged = false

    // Web seed download.
    private var webSeed = false
    private var webTask: URLSessionDownloadTask?
    private var webIndex = 0
    private var webSeedIndex = 0
    private var webDone: Int64 = 0
    private var webFailed: [(String, Int64)] = []

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

    private var isMagnet: Bool { record.url.lowercased().hasPrefix("magnet:") }

    func start() {
        if record.torrentWebSeed == true, !isMagnet {
            // An earlier run found no peers and switched to the web seeds: go on there.
            report("Web kaynağına bağlanılıyor")
            return loadTorrentFile { data in
                guard let m = TorrentMeta(data), !m.webSeeds.isEmpty else { return self.fail(".torrent dosyası okunamadı") }
                self.meta = m
                self.startWebSeed(reason: "resumed")
            }
        }
        report("Torrent motoru başlatılıyor")
        TorrentService.shared.ensureRunning { ok in
            guard !self.stopped else { return }
            guard ok else {
                return self.fail(TorrentService.executable == nil ? "Torrent motoru (rqbit) bulunamadı"
                                                                   : "Torrent motoru başlatılamadı")
            }
            if let hash = self.record.torrentHash {
                // rqbit remembers the torrent from its own session; just make sure it runs.
                TorrentService.call("POST", "/torrents/\(hash)/start") { r in
                    if case .failure = r { self.add() } else {
                        Log.torrent("\(self.name): resumed in rqbit (\(hash))")
                        if !self.isMagnet { self.loadTorrentFile(quiet: true) { self.meta = TorrentMeta($0) } }
                        self.watch(hash)
                    }
                }
            } else {
                self.add()
            }
        }
    }

    /// Fetches a .torrent file ourselves (with the browser's cookies) or reads it from disk.
    private func loadTorrentFile(quiet: Bool = false, _ done: @escaping (Data) -> Void) {
        let src = record.url
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let u = URL(string: src) else {
                if !quiet { fail("Geçersiz adres") }
                return
            }
            var req = URLRequest(url: u, timeoutInterval: 60)
            for (k, v) in record.headers { req.setValue(v, forHTTPHeaderField: k) }
            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard let data, error == nil, status < 400, data.first == UInt8(ascii: "d") else {
                        Log.torrent(".torrent fetch failed: \(src): \(error?.localizedDescription ?? "HTTP \(status)")")
                        if !quiet { self.fail(".torrent dosyası alınamadı") }
                        return
                    }
                    done(data)
                }
            }.resume()
        } else {
            let path = URL(string: src)?.isFileURL == true ? URL(string: src)!.path : src
            guard let data = FileManager.default.contents(atPath: path) else {
                if !quiet { fail(".torrent dosyası okunamadı") }
                return
            }
            done(data)
        }
    }

    /// Magnet links go to rqbit as they are, .torrent files as their contents.
    private func add() {
        if isMagnet {
            let items = URLComponents(string: record.url)?.queryItems ?? []
            Log.torrent("adding magnet \(record.fileName): \(items.filter { $0.name == "tr" }.count) trackers, "
                        + "\(items.filter { $0.name == "ws" }.count) web seeds")
            return post(Data(record.url.utf8), isURL: true)
        }
        loadTorrentFile { data in
            self.meta = TorrentMeta(data)
            if let m = self.meta {
                Log.torrent("adding .torrent \(m.name): \(m.files.count) files, \(Format.bytes(m.total)), "
                            + "trackers \(m.trackers), web seeds \(m.webSeeds), private \(m.isPrivate)")
                if m.total > 0 { self.total = m.total }
            } else {
                Log.torrent("adding .torrent \(self.record.url): could not read it ourselves, rqbit will try")
            }
            self.post(data, isURL: false)
        }
    }

    private func post(_ body: Data, isURL: Bool) {
        let q = [URLQueryItem(name: "overwrite", value: "true"),
                 URLQueryItem(name: "output_folder", value: record.directory),
                 URLQueryItem(name: "is_url", value: isURL ? "true" : "false")]
        // A magnet link answers only once its metadata came from a peer.
        report(isURL ? "Meta veri aranıyor (eşlerden alınıyor)" : "Torrent ekleniyor")
        let started = Date()
        TorrentService.call("POST", "/torrents", query: q, body: body, timeout: 600) { r in
            switch r {
            case .failure(let e):
                let waited = Int(Date().timeIntervalSince(started))
                Log.torrent("rqbit add failed after \(waited) s: \(e.localizedDescription)")
                if (e as? URLError)?.code == .timedOut {
                    return self.fail("Kaynak bulunamadı: 10 dakikada hiçbir eşten meta veri gelmedi")
                }
                self.fail(e.localizedDescription)
            case .success(let json):
                let details = (json as? [String: Any])?["details"] as? [String: Any] ?? [:]
                guard let hash = details["info_hash"] as? String else {
                    Log.torrent("rqbit add answered without an info hash: \(json)")
                    return self.fail("Torrent eklenemedi")
                }
                self.name = details["name"] as? String ?? self.name
                let files = details["files"] as? [[String: Any]] ?? []
                let size = files.reduce(Int64(0)) { $0 + ((($1["length"] as? NSNumber)?.int64Value) ?? 0) }
                if size > 0 { self.total = size }
                Log.torrent("added \(self.name) (\(hash)): \(files.count) files, \(Format.bytes(size)), "
                            + "\(Int(Date().timeIntervalSince(started))) s")
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
        lastBytes = -1
        lastChange = Date()
        poll(hash, generation)
    }

    private func poll(_ hash: String, _ gen: Int) {
        guard gen == generation, !stopped else { return }
        refresh(hash, gen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.poll(hash, gen) }
    }

    private func refresh(_ hash: String, _ gen: Int) {
        TorrentService.call("GET", "/torrents/\(hash)/stats/v1", timeout: 5) { r in
            guard gen == self.generation, !self.stopped else { return }
            guard case .success(let json) = r, let s = json as? [String: Any] else {
                if case .failure(let e) = r, Date().timeIntervalSince(self.lastLog) > 30 {
                    self.lastLog = Date()
                    Log.torrent("\(self.name): stats failed: \(e.localizedDescription)")
                }
                return
            }
            let got = (s["progress_bytes"] as? NSNumber)?.int64Value ?? 0
            if let t = (s["total_bytes"] as? NSNumber)?.int64Value, t > 0 { self.total = t }
            if let err = s["error"] as? String, !err.isEmpty {
                Log.torrent("\(self.name): rqbit error: \(err)")
                return self.fail(err)
            }
            if s["finished"] as? Bool == true {
                Log.torrent("\(self.name): finished through BitTorrent")
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

            let state = s["state"] as? String ?? "?"
            let live = s["live"] as? [String: Any]
            let ps = (live?["snapshot"] as? [String: Any])?["peer_stats"] as? [String: Any] ?? [:]
            func n(_ k: String) -> Int { (ps[k] as? NSNumber)?.intValue ?? 0 }
            let peers = n("live"), seen = n("seen"), connecting = n("connecting"), seeders = n("live_seeders")
            let now = Date()
            if got != self.lastBytes {
                self.lastBytes = got
                self.lastChange = now
            }
            let idle = now.timeIntervalSince(self.lastChange)
            let speed = ((live?["download_speed"] as? [String: Any])?["human_readable"] as? String) ?? "-"
            let summary = "state \(state), \(got)/\(self.total) bytes, peers live \(peers) (seeders \(seeders)) "
                + "connecting \(connecting) queued \(n("queued")) seen \(seen) dead \(n("dead")), down \(speed), idle \(Int(idle)) s"
            if state != self.lastState || now.timeIntervalSince(self.lastLog) >= 30 {
                Log.torrent("\(self.name): \(summary)")
                self.lastState = state
                self.lastLog = now
            }

            switch state {
            case "initializing":
                self.note = "Dosyalar denetleniyor"
            case "paused":
                self.note = "Torrent motorunda duraklatılmış"
            default:
                if peers > 0 {
                    self.note = "\(peers) eşe bağlı" + (seeders > 0 ? " (\(seeders) tam kaynak)" : "")
                        + (idle >= 30 ? " · eşler veri göndermiyor" : "")
                } else if seen == 0 {
                    self.note = idle >= 120 ? "Kaynak bulunamadı: bu torrenti şu an paylaşan yok"
                                            : "Eş aranıyor (izleyici ve DHT)"
                } else {
                    self.note = idle >= 120 ? "Kaynak bulunamadı: \(seen) eş bulundu ama hiçbiri bağlanmadı"
                                            : "\(seen) eş bulundu, bağlanılıyor"
                }
            }

            if idle >= 60, !self.dhtLogged {
                self.dhtLogged = true
                TorrentService.call("GET", "/dht/stats", timeout: 5) { d in
                    switch d {
                    case .success(let j): Log.torrent("DHT: \(j)")
                    case .failure(let e): Log.torrent("DHT stats unavailable: \(e.localizedDescription)")
                    }
                }
            }

            if state == "live", idle >= Self.stallSeconds, let m = self.meta, !m.webSeeds.isEmpty, !m.isPrivate {
                return self.startWebSeed(reason: "no data from BitTorrent for \(Int(idle)) s (\(summary))")
            }
            self.onEvent(.progress(self.snapshot(got: got, peers: peers)))
        }
    }

    // MARK: Web seeds

    private func startWebSeed(reason: String) {
        guard let m = meta else { return }
        Log.torrent("\(m.name): switching to web seeds \(m.webSeeds): \(reason)")
        generation += 1
        webSeed = true
        name = m.name
        total = m.total
        webIndex = 0
        webSeedIndex = 0
        webDone = 0
        webFailed = []
        let gen = generation
        let begin = {
            self.nextWebFile(gen)
            self.webPoll(gen)
        }
        if let h = record.torrentHash, record.torrentWebSeed != true {
            // rqbit drops the torrent and the files it preallocated: a file of full size on disk
            // then always means the web seed finished it, which lets a paused download resume.
            report("Web kaynağına geçiliyor")
            TorrentService.call("POST", "/torrents/\(h)/delete") { _ in begin() }
        } else {
            begin()
        }
    }

    private var webHost: String {
        guard let m = meta, webSeedIndex < m.webSeeds.count else { return "web" }
        return URL(string: m.webSeeds[webSeedIndex])?.host ?? "web"
    }

    private func webPoll(_ gen: Int) {
        guard gen == generation, !stopped else { return }
        let got = webDone + (webTask?.countOfBytesReceived ?? 0)
        note = "Eş bulunamadı, web kaynağından indiriliyor (\(webHost))"
        onEvent(.progress(snapshot(got: got, peers: 0)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.webPoll(gen) }
    }

    private func nextWebFile(_ gen: Int) {
        guard gen == generation, !stopped, let m = meta else { return }
        guard webIndex < m.files.count else { return finishWebSeed() }
        let file = m.files[webIndex]
        let shown = ([m.name] + file.path).joined(separator: "/")
        guard let dest = m.localPath(of: file, in: record.directory) else {
            Log.torrent("web seed: skipped unsafe path \(shown)")
            webFailed.append((shown, file.length))
            webIndex += 1
            return nextWebFile(gen)
        }
        let have = ((try? FileManager.default.attributesOfItem(atPath: dest))?[.size] as? NSNumber)?.int64Value ?? -1
        if webSeedIndex == 0, have == file.length, have > 0 {
            // Finished in an earlier run.
            webDone += file.length
            webIndex += 1
            return nextWebFile(gen)
        }
        guard webSeedIndex < m.webSeeds.count, let url = m.url(of: file, on: m.webSeeds[webSeedIndex]) else {
            Log.torrent("web seed: no seed could deliver \(shown)")
            webFailed.append((shown, file.length))
            webIndex += 1
            webSeedIndex = 0
            return nextWebFile(gen)
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("MDM (Mac Download Manager)", forHTTPHeaderField: "User-Agent")
        let expected = file.length
        let task = URLSession.shared.downloadTask(with: req) { tmp, response, error in
            var problem: String?
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                problem = error.localizedDescription
            } else if status >= 400 {
                problem = "HTTP \(status)"
            } else if let tmp {
                // The temporary file is gone once this handler returns, so it is moved right here.
                let fm = FileManager.default
                let size = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.int64Value ?? -1
                if size != expected {
                    problem = "boyut \(size), beklenen \(expected)"
                } else {
                    do {
                        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        try? fm.removeItem(atPath: dest)
                        try fm.moveItem(at: tmp, to: URL(fileURLWithPath: dest))
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            DispatchQueue.main.async { self.webFileEnded(gen, url: url, shown: shown, length: expected, problem: problem) }
        }
        webTask = task
        task.resume()
    }

    private func webFileEnded(_ gen: Int, url: URL, shown: String, length: Int64, problem: String?) {
        guard gen == generation, !stopped else { return }
        webTask = nil
        if let problem {
            Log.torrent("web seed: \(url.absoluteString): \(problem)")
            webSeedIndex += 1   // the next seed gets a try, then the file is given up
        } else {
            Log.torrent("web seed: got \(shown) (\(Format.bytes(length)))")
            webDone += length
            webIndex += 1
            webSeedIndex = 0
        }
        nextWebFile(gen)
    }

    private func finishWebSeed() {
        generation += 1
        let missing = webFailed.reduce(Int64(0)) { $0 + $1.1 }
        // archive.org lists small metadata files that can change after the torrent was made;
        // losing those is fine, losing real content is not.
        if total > 0, missing * 100 > total {
            Log.torrent("web seed: \(webFailed.count) files missing: \(webFailed.map { $0.0 })")
            return fail("Kaynak bulunamadı: eş yok, web kaynağı da \(webFailed.count) dosyayı vermedi")
        }
        if !webFailed.isEmpty { Log.torrent("web seed: skipped small files \(webFailed.map { $0.0 })") }
        Log.torrent("\(name): finished through web seeds")
        stopped = true
        let path = (record.directory as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path) {
            FileMeta.markDownloaded(URL(fileURLWithPath: path), from: record.url, referrer: record.pageURL)
        }
        note = nil
        var snap = snapshot(got: total, peers: 0)
        snap.finalPath = path
        onEvent(.completed(snap))
    }

    // MARK: -

    private func report(_ text: String) {
        note = text
        onEvent(.progress(snapshot(got: record.receivedBytes, peers: 0)))
    }

    private func snapshot(got: Int64, peers: Int) -> SegmentedDownloader.Snapshot {
        SegmentedDownloader.Snapshot(totalBytes: total, receivedBytes: got, segments: [], tempPath: nil, finalPath: nil,
                                     fileName: name, connections: peers, torrentHash: record.torrentHash,
                                     note: note, webSeed: webSeed)
    }

    private func fail(_ msg: String) {
        generation += 1
        stopped = true
        webTask?.cancel()
        note = nil
        Log.torrent("\(name): failed: \(msg)")
        onEvent(.failed(msg, snapshot(got: record.receivedBytes, peers: 0)))
    }

    func pause() {
        stopped = true
        generation += 1
        webTask?.cancel()
        webTask = nil
        Log.torrent("\(name): paused\(webSeed ? " (web seed)" : "")")
        if !webSeed, let h = record.torrentHash { TorrentService.call("POST", "/torrents/\(h)/pause") { _ in } }
    }

    /// Removes the torrent from rqbit; with `deleteFiles` the partly downloaded data goes too.
    static func forget(_ hash: String, deleteFiles: Bool) {
        TorrentService.shared.ensureRunning { ok in
            guard ok else { return }
            TorrentService.call("POST", "/torrents/\(hash)/\(deleteFiles ? "delete" : "forget")") { _ in }
        }
    }
}
