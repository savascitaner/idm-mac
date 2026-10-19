import Foundation

/// Multi-connection HTTP downloader with resume and dynamic segment splitting (IDM-style).
///
/// All state lives on `queue`; URLSession delegate callbacks are delivered on the same queue,
/// so no locking is needed. Progress and completion are reported on the main queue.
final class SegmentedDownloader: NSObject, URLSessionDataDelegate {
    struct Snapshot {
        var totalBytes: Int64
        var receivedBytes: Int64
        var segments: [Segment]
        var tempPath: String?
        var finalPath: String?
        var fileName: String
        var connections: Int
        var torrentHash: String? = nil
    }

    enum Event {
        case progress(Snapshot)
        case completed(Snapshot)
        case failed(String, Snapshot)
    }

    private let queue = DispatchQueue(label: "idmmac.download")
    private var session: URLSession?
    private var record: DownloadRecord
    private let maxConnections: Int
    private let onEvent: (Event) -> Void

    private var segments: [Segment]
    private var total: Int64
    private var tempURL: URL?
    private var fileHandle: FileHandle?
    private var supportsRanges = false
    private var taskSegment: [Int: Int] = [:]      // taskIdentifier -> segment index
    private var probeTaskID: Int?
    private var finishedTasks = Set<Int>()         // tasks we cancelled on purpose
    private var retries: [Int: Int] = [:]          // segment index -> retry count
    private var stopped = false
    private var lastReport = Date.distantPast
    private var fileName: String

    private static let minSplit: Int64 = 512 * 1024
    static let htmlInsteadOfFile = "Sunucu dosya yerine bir web sayfası gönderdi"

    init(record: DownloadRecord, maxConnections: Int, onEvent: @escaping (Event) -> Void) {
        self.record = record
        self.maxConnections = max(1, min(32, maxConnections))
        self.onEvent = onEvent
        self.segments = record.segments
        self.total = record.totalBytes
        self.fileName = record.fileName
        if let t = record.tempPath { tempURL = URL(fileURLWithPath: t) }
        super.init()
    }

    // MARK: Control

    func start() {
        queue.async { [self] in
            stopped = false
            makeSession()
            if !segments.isEmpty, let t = tempURL, FileManager.default.fileExists(atPath: t.path) {
                supportsRanges = segments.count > 1 || segments.first?.end ?? -1 >= 0
                if openFile() { launchPending() }
            } else {
                segments = []
                probe()
            }
        }
    }

    func pause() {
        queue.async { [self] in
            stopped = true
            session?.invalidateAndCancel()
            session = nil
            taskSegment.removeAll()
            try? fileHandle?.synchronize()
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    // MARK: Setup

    private func makeSession() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = maxConnections + 1
        cfg.timeoutIntervalForRequest = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
    }

    private func request(range: String?) -> URLRequest? {
        guard let url = URL(string: record.url) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in record.headers where !v.isEmpty { req.setValue(v, forHTTPHeaderField: k) }
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return req
    }

    private func probe() {
        guard let req = request(range: "bytes=0-0"), let task = session?.dataTask(with: req) else {
            fail("Geçersiz adres")
            return
        }
        probeTaskID = task.taskIdentifier
        task.resume()
    }

    private func handleProbe(_ response: URLResponse) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status >= 400 {
            fail("Sunucu hatası: HTTP \(status)")
            return
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let expected = (record.browserMime ?? "").lowercased()
        if type.contains("text/html"), !expected.isEmpty, !expected.contains("html") {
            // The server sent a web page (error, login or "please wait") instead of the file Chrome got.
            fail(Self.htmlInsteadOfFile)
            return
        }
        if status == 206, let cr = http?.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"), let n = Int64(cr[cr.index(after: slash)...]) {
            supportsRanges = true
            total = n
        } else {
            supportsRanges = false
            total = response.expectedContentLength
        }
        if let finalURL = response.url, finalURL.absoluteString != record.url {
            record.url = finalURL.absoluteString
        }
        // A name from the browser wins; otherwise use Content-Disposition / the URL.
        if fileName.isEmpty, let suggested = response.suggestedFilename, !suggested.isEmpty, suggested != "Unknown" {
            fileName = FileMeta.sanitize(suggested)
        }
        if fileName.isEmpty { fileName = FileMeta.fileName(from: response.url ?? URL(fileURLWithPath: "/indirme")) }

        let dir = URL(fileURLWithPath: record.directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = FileMeta.uniqueURL(in: dir, name: fileName)
        fileName = final.lastPathComponent
        tempURL = URL(fileURLWithPath: final.path + ".idmpart")

        planSegments()
        FileManager.default.createFile(atPath: tempURL!.path, contents: nil)
        guard openFile() else { return }
        if total > 0 { try? fileHandle?.truncate(atOffset: UInt64(total)) }
        launchPending()
    }

    private func planSegments() {
        guard supportsRanges, total > 0 else {
            segments = [Segment(start: 0, end: total > 0 ? total - 1 : -1, done: 0)]
            return
        }
        let byMin = Int((total + Self.minSplit - 1) / Self.minSplit)
        let n = max(1, min(maxConnections, byMin))
        let size = total / Int64(n)
        segments = (0..<n).map { i in
            let s = Int64(i) * size
            let e = i == n - 1 ? total - 1 : s + size - 1
            return Segment(start: s, end: e, done: 0)
        }
    }

    private func openFile() -> Bool {
        guard let t = tempURL else { fail("Geçici dosya yok"); return false }
        do {
            fileHandle = try FileHandle(forWritingTo: t)
            return true
        } catch {
            fail("Dosya açılamadı: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Segments

    private func launchPending() {
        let running = Set(taskSegment.values)
        for (i, seg) in segments.enumerated() where !seg.isComplete && !running.contains(i) {
            launch(i)
        }
        if segments.allSatisfy({ $0.isComplete }) { finish() }
        report(force: true)
    }

    private func launch(_ index: Int) {
        let seg = segments[index]
        let range: String?
        if supportsRanges {
            range = seg.end >= 0 ? "bytes=\(seg.current)-\(seg.end)" : "bytes=\(seg.current)-"
        } else {
            // No range support: always restart from zero.
            segments[index].done = 0
            range = nil
        }
        guard let req = request(range: range), let task = session?.dataTask(with: req) else { return }
        taskSegment[task.taskIdentifier] = index
        task.resume()
    }

    /// When a connection frees up, split the largest remaining segment so all connections stay busy.
    private func splitLargest() {
        guard supportsRanges, taskSegment.count < maxConnections else { return }
        let running = Set(taskSegment.values)
        guard let (idx, seg) = segments.enumerated()
            .filter({ running.contains($0.offset) && !$0.element.isComplete && $0.element.end >= 0 })
            .max(by: { $0.element.remaining < $1.element.remaining }),
            seg.remaining > Self.minSplit * 2 else { return }
        let mid = seg.current + seg.remaining / 2
        let newSeg = Segment(start: mid, end: seg.end, done: 0)
        segments[idx].end = mid - 1
        segments.append(newSeg)
        launch(segments.count - 1)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard session === self.session else { completionHandler(.cancel); return }
        if dataTask.taskIdentifier == probeTaskID {
            completionHandler(.cancel)
            probeTaskID = nil
            handleProbe(response)
            return
        }
        guard let idx = taskSegment[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status >= 400 {
            completionHandler(.cancel)
            fail("Sunucu hatası: HTTP \(status)")
            return
        }
        if supportsRanges && status == 200 && segments[idx].current > 0 {
            // Server ignored our Range header: fall back to a single stream from the start.
            completionHandler(.cancel)
            restartSingle()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, let idx = taskSegment[dataTask.taskIdentifier], let fh = fileHandle else { return }
        var chunk = data
        let seg = segments[idx]
        if seg.end >= 0 {
            let allowed = seg.end - seg.current + 1
            if allowed <= 0 {
                finishedTasks.insert(dataTask.taskIdentifier)
                dataTask.cancel()
                return
            }
            if Int64(chunk.count) > allowed { chunk = chunk.prefix(Int(allowed)) }
        }
        do {
            try fh.seek(toOffset: UInt64(seg.current))
            try fh.write(contentsOf: chunk)
        } catch {
            fail("Diske yazılamadı: \(error.localizedDescription)")
            return
        }
        segments[idx].done += Int64(chunk.count)
        if segments[idx].isComplete {
            finishedTasks.insert(dataTask.taskIdentifier)
            dataTask.cancel()
        }
        report(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, !stopped else { return }
        let id = task.taskIdentifier
        guard let idx = taskSegment.removeValue(forKey: id) else { return }
        let purposeful = finishedTasks.remove(id) != nil

        if !purposeful, let error {
            let tries = (retries[idx] ?? 0) + 1
            retries[idx] = tries
            if tries > 8 {
                fail("Bağlantı hatası: \(error.localizedDescription)")
                return
            }
            let delay = min(30.0, pow(2.0, Double(tries)))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, self.session != nil else { return }
                self.launch(idx)
            }
            return
        }

        if segments[idx].end < 0 {
            // Unknown length: the stream ended, so the file is complete.
            segments[idx].end = segments[idx].current - 1
            total = segments[idx].current
        }
        retries[idx] = 0
        splitLargest()
        if segments.allSatisfy({ $0.isComplete }) { finish() }
    }

    private func restartSingle() {
        session?.invalidateAndCancel()
        taskSegment.removeAll()
        supportsRanges = false
        segments = [Segment(start: 0, end: total > 0 ? total - 1 : -1, done: 0)]
        makeSession()
        launchPending()
    }

    // MARK: Reporting

    private var received: Int64 { segments.reduce(0) { $0 + $1.done } }

    private func snapshot() -> Snapshot {
        Snapshot(totalBytes: total, receivedBytes: received, segments: segments, tempPath: tempURL?.path,
                 finalPath: nil, fileName: fileName, connections: taskSegment.count)
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.4 else { return }
        lastReport = now
        let s = snapshot()
        DispatchQueue.main.async { self.onEvent(.progress(s)) }
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        session?.finishTasksAndInvalidate()
        session = nil
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        var s = snapshot()
        guard let temp = tempURL else { return }
        let dir = temp.deletingLastPathComponent()
        var final = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: final.path) { final = FileMeta.uniqueURL(in: dir, name: fileName) }
        do {
            try FileManager.default.moveItem(at: temp, to: final)
            s.finalPath = final.path
            s.fileName = final.lastPathComponent
            FileMeta.markDownloaded(final, from: record.url, referrer: record.headers["Referer"])
            DispatchQueue.main.async { self.onEvent(.completed(s)) }
        } catch {
            DispatchQueue.main.async { self.onEvent(.failed("Dosya taşınamadı: \(error.localizedDescription)", s)) }
        }
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        session?.invalidateAndCancel()
        session = nil
        taskSegment.removeAll()
        try? fileHandle?.close()
        fileHandle = nil
        let s = snapshot()
        DispatchQueue.main.async { self.onEvent(.failed(message, s)) }
    }
}
