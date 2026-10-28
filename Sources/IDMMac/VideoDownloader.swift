import Foundation

/// One quality choice offered in the video dialog.
struct VideoOption: Identifiable, Hashable {
    var id: String { label }
    var label: String
    var detail: String
    var sort: String?      // yt-dlp -S
    var format: String     // yt-dlp -f
    var audioOnly: Bool
}

/// One audio language of a video (YouTube offers dubbed tracks next to the original).
struct AudioTrack: Identifiable, Hashable {
    var id: String { code }
    var code: String       // yt-dlp "language", e.g. "tr" or "en-US"
    var name: String
    var isOriginal: Bool

    var label: String { isOriginal ? "\(name) (orijinal)" : name }
}

struct VideoInfo {
    var title: String
    var webpageURL: String
    var thumbnail: String?
    var duration: Double?
    var options: [VideoOption]
    var audioTracks: [AudioTrack] = []

    /// The track to preselect: the Mac's language if the video has it, otherwise the original.
    var defaultTrack: AudioTrack? {
        guard audioTracks.count > 1 else { return nil }
        let mine = Locale.current.language.languageCode?.identifier ?? "tr"
        return audioTracks.first { $0.code.lowercased().hasPrefix(mine) }
            ?? audioTracks.first(where: \.isOriginal) ?? audioTracks.first
    }
}

struct PlaylistEntry: Identifiable {
    var id: String
    var url: String
    var title: String
    var thumbnail: String?
    var duration: Double?
}

struct PlaylistInfo {
    var title: String
    var entries: [PlaylistEntry]
}

enum YtDlp {
    /// Writes the browser cookies to a Netscape cookies.txt that yt-dlp can read.
    static func cookieFile(for id: UUID, cookies: [BrowserCookie]) -> URL? {
        guard !cookies.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: Paths.cookies, withIntermediateDirectories: true)
        let url = Paths.cookies.appendingPathComponent("\(id.uuidString).txt")
        let body = "# Netscape HTTP Cookie File\n" + cookies.map(\.netscapeLine).joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    static func commonArgs(cookieFile: URL?, headers: [String: String], playlist: Bool = false) -> [String] {
        var a = [playlist ? "--yes-playlist" : "--no-playlist", "--no-warnings", "--no-mtime"]
        if let c = cookieFile { a += ["--cookies", c.path] }
        if let ua = headers["User-Agent"], !ua.isEmpty { a += ["--user-agent", ua] }
        if let r = headers["Referer"], !r.isEmpty { a += ["--referer", r] }
        if let ff = Tools.ffmpeg { a += ["--ffmpeg-location", ff.path] }
        if let js = Tools.deno { a += ["--js-runtimes", "deno:" + js.path] }
        return a
    }

    /// Runs yt-dlp with the given arguments off the main thread; returns its stdout, or the error it printed.
    private static func run(_ args: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        guard let exe = Tools.ytdlp else {
            completion(.failure(Failure(L("yt-dlp bulunamadı"))))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                errDone.signal()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            p.waitUntilExit()
            let result: Result<Data, Error> = p.terminationStatus == 0
                ? .success(data)
                : .failure(Failure(lastLines(errData) ?? L("Video bilgisi alınamadı")))
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Runs `yt-dlp -J` and turns the format list into a few simple choices.
    static func probe(url: String, cookieFile: URL?, headers: [String: String],
                      completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        run(commonArgs(cookieFile: cookieFile, headers: headers) + ["-J", url]) { r in
            completion(r.flatMap { data -> Result<VideoInfo, Error> in
                if let info = parse(data, fallbackURL: url) { return .success(info) }
                return .failure(Failure(L("Video bilgisi alınamadı")))
            })
        }
    }

    /// Lists a playlist's videos without fetching each one (`--flat-playlist`).
    static func probePlaylist(url: String, cookieFile: URL?, headers: [String: String],
                              completion: @escaping (Result<PlaylistInfo, Error>) -> Void) {
        run(commonArgs(cookieFile: cookieFile, headers: headers, playlist: true) + ["--flat-playlist", "-J", url]) { r in
            completion(r.flatMap { data -> Result<PlaylistInfo, Error> in
                if let list = parsePlaylist(data) { return .success(list) }
                return .failure(Failure(L("Oynatma listesi okunamadı")))
            })
        }
    }

    static func parsePlaylist(_ data: Data) -> PlaylistInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["_type"] as? String == "playlist",
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        let list: [PlaylistEntry] = entries.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            var url = e["url"] as? String ?? id
            if !url.hasPrefix("http") { url = "https://www.youtube.com/watch?v=\(id)" }
            let thumbs = e["thumbnails"] as? [[String: Any]] ?? []
            return PlaylistEntry(id: id, url: url, title: e["title"] as? String ?? id,
                                 thumbnail: thumbs.last?["url"] as? String, duration: e["duration"] as? Double)
        }
        guard !list.isEmpty else { return nil }
        return PlaylistInfo(title: json["title"] as? String ?? "Oynatma listesi", entries: list)
    }

    /// Restricts a format selector to one audio language, falling back to the default track.
    static func format(_ base: String, audioOnly: Bool, language: String?) -> String {
        guard let l = language, !l.isEmpty else { return base }
        return audioOnly ? "ba[language=\(l)]/\(base)" : "bv*+ba[language=\(l)]/\(base)"
    }

    /// Distinct audio languages among the formats, original first.
    static func audioTracks(_ formats: [[String: Any]]) -> [AudioTrack] {
        let names = Locale(identifier: "tr")
        var seen: [String: AudioTrack] = [:]
        for f in formats where (f["acodec"] as? String ?? "none") != "none" {
            guard let code = f["language"] as? String, !code.isEmpty, code != "und" else { continue }
            let note = (f["format_note"] as? String ?? "").lowercased()
            let original = note.contains("original") || ((f["language_preference"] as? NSNumber)?.intValue ?? 0) >= 10
            let name = names.localizedString(forIdentifier: code.replacingOccurrences(of: "-", with: "_")) ?? code
            if var t = seen[code] {
                t.isOriginal = t.isOriginal || original
                seen[code] = t
            } else {
                seen[code] = AudioTrack(code: code, name: name.prefix(1).uppercased() + String(name.dropFirst()), isOriginal: original)
            }
        }
        return seen.values.sorted { a, b in a.isOriginal != b.isOriginal ? a.isOriginal : a.name < b.name }
    }

    static func parse(_ data: Data, fallbackURL: String) -> VideoInfo? {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if json["_type"] as? String == "playlist", let entries = json["entries"] as? [[String: Any]],
           let first = entries.first(where: { $0["formats"] != nil }) ?? entries.first {
            json = first
        }
        let title = json["title"] as? String ?? "video"
        let formats = json["formats"] as? [[String: Any]] ?? []

        func size(_ f: [String: Any]) -> Int64 {
            (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value ?? 0
        }
        let videos = formats.filter { ($0["vcodec"] as? String ?? "none") != "none" }
        let audios = formats.filter { ($0["vcodec"] as? String ?? "") == "none" && ($0["acodec"] as? String ?? "none") != "none" }
        let bestAudio = audios.map(size).max() ?? 0

        var heights = Set<Int>()
        for f in videos { if let h = (f["height"] as? NSNumber)?.intValue, h > 0 { heights.insert(h) } }
        let sorted = heights.sorted(by: >)

        var options: [VideoOption] = []
        options.append(VideoOption(label: "En iyi kalite", detail: sorted.first.map { "\($0)p" } ?? "",
                                   sort: "res,ext:mp4:m4a", format: "bv*+ba/b", audioOnly: false))
        for h in sorted.prefix(6) {
            let best = videos.filter { ($0["height"] as? NSNumber)?.intValue == h }.map(size).max() ?? 0
            let total = best > 0 ? best + bestAudio : 0
            options.append(VideoOption(label: "\(h)p", detail: total > 0 ? "~" + Format.bytes(total) : "",
                                       sort: "res:\(h),ext:mp4:m4a", format: "bv*+ba/b", audioOnly: false))
        }
        if !audios.isEmpty || videos.isEmpty == false {
            options.append(VideoOption(label: "Sadece ses (m4a)", detail: bestAudio > 0 ? "~" + Format.bytes(bestAudio) : "",
                                       sort: "ext:m4a", format: "ba/b", audioOnly: true))
        }
        return VideoInfo(title: title,
                         webpageURL: json["webpage_url"] as? String ?? fallbackURL,
                         thumbnail: json["thumbnail"] as? String,
                         duration: (json["duration"] as? NSNumber)?.doubleValue,
                         options: options,
                         audioTracks: audioTracks(formats))
    }

    static func lastLines(_ data: Data) -> String? {
        let s = String(data: data, encoding: .utf8) ?? ""
        let lines = s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(3).joined(separator: "\n")
    }

    struct Failure: LocalizedError {
        var message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

/// Downloads one video with yt-dlp and reports progress parsed from its output.
final class VideoDownloader {
    private var process: Process?
    private let record: DownloadRecord
    private let onEvent: (SegmentedDownloader.Event) -> Void
    private var stopped = false

    init(record: DownloadRecord, onEvent: @escaping (SegmentedDownloader.Event) -> Void) {
        self.record = record
        self.onEvent = onEvent
    }

    func start() {
        guard let exe = Tools.ytdlp else {
            onEvent(.failed("yt-dlp bulunamadı", snapshot(0, -1)))
            return
        }
        stopped = false
        let cookieFile = YtDlp.cookieFile(for: record.id, cookies: record.cookies)
        var args = YtDlp.commonArgs(cookieFile: cookieFile, headers: record.headers)
        args += ["--newline", "--progress", "-N", "8",
                 "-f", record.videoFormat ?? "bv*+ba/b",
                 "-o", "\(record.directory)/\(record.playlistIndex.map { String(format: "%03d - ", $0) } ?? "")%(title).180B [%(id)s].%(ext)s",
                 "--progress-template", "download:IDMPROG %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s",
                 "--print", "after_move:IDMFILE %(filepath)s"]
        if let s = record.videoSort { args += ["-S", s] }
        // yt-dlp takes the cap once, when it starts.
        if SpeedLimit.bytesPerSecond > 0 { args += ["--limit-rate", "\(SpeedLimit.bytesPerSecond)"] }
        if !record.audioOnly { args += ["--merge-output-format", "mp4"] }
        if !record.audioOnly, UserDefaults.standard.bool(forKey: "videoSubtitles") {
            // Subtitles the uploader made, and YouTube's automatic captions, in the chosen languages, put into the file; a video without them downloads as usual.
            let langs = (UserDefaults.standard.string(forKey: "subtitleLanguages") ?? "tr,en")
                .split(whereSeparator: { ", ;".contains($0) }).joined(separator: ",")
            args += ["--write-subs", "--write-auto-subs", "--sub-langs", langs.isEmpty ? "tr,en" : langs, "--embed-subs"]
        }
        args.append(record.url)

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: record.directory)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        process = p

        var finalPath: String?
        var lastProgress = snapshot(0, -1)
        var errTail: [String] = []
        let lineQueue = DispatchQueue(label: "idmmac.ytdlp")
        var outBuffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lineQueue.sync {
                outBuffer.append(d)
                while let nl = outBuffer.firstIndex(of: 0x0A) {
                    let line = String(data: outBuffer[outBuffer.startIndex..<nl], encoding: .utf8) ?? ""
                    outBuffer.removeSubrange(outBuffer.startIndex...nl)
                    if line.hasPrefix("IDMFILE ") {
                        finalPath = String(line.dropFirst(8))
                    } else if line.hasPrefix("IDMPROG "), let s = self?.parseProgress(String(line.dropFirst(8))) {
                        lastProgress = s
                        DispatchQueue.main.async { self?.onEvent(.progress(s)) }
                    }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            lineQueue.sync {
                errTail += s.split(separator: "\n").map(String.init)
                if errTail.count > 20 { errTail.removeFirst(errTail.count - 20) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            // Drain whatever is left in the pipe (the IDMFILE line is printed last).
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            lineQueue.sync {
                outBuffer.append(rest)
                for line in String(data: outBuffer, encoding: .utf8)?.split(separator: "\n") ?? [] where line.hasPrefix("IDMFILE ") {
                    finalPath = String(line.dropFirst(8))
                }
            }
            if let c = cookieFile { try? FileManager.default.removeItem(at: c) }
            guard let self, !self.stopped else { return }
            var snap = lastProgress
            if proc.terminationStatus == 0 {
                snap.finalPath = finalPath
                if let fp = finalPath {
                    snap.fileName = URL(fileURLWithPath: fp).lastPathComponent
                    let size = (try? FileManager.default.attributesOfItem(atPath: fp)[.size] as? NSNumber)?.int64Value ?? snap.totalBytes
                    snap.totalBytes = size
                    snap.receivedBytes = size
                    FileMeta.markDownloaded(URL(fileURLWithPath: fp), from: self.record.url, referrer: self.record.pageURL)
                }
                DispatchQueue.main.async { self.onEvent(.completed(snap)) }
            } else {
                let msg = lineQueue.sync { errTail.filter { $0.contains("ERROR") }.last ?? errTail.last } ?? "yt-dlp hata verdi"
                DispatchQueue.main.async { self.onEvent(.failed(msg, snap)) }
            }
        }
        do {
            try p.run()
            onEvent(.progress(snapshot(0, -1)))
        } catch {
            onEvent(.failed("yt-dlp çalıştırılamadı: \(error.localizedDescription)", snapshot(0, -1)))
        }
    }

    /// yt-dlp resumes its .part files, so pausing is simply stopping the process.
    func pause() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func snapshot(_ got: Int64, _ total: Int64) -> SegmentedDownloader.Snapshot {
        SegmentedDownloader.Snapshot(totalBytes: total, receivedBytes: got, segments: [], tempPath: nil,
                                     finalPath: nil, fileName: record.fileName, connections: 0)
    }

    private func parseProgress(_ s: String) -> SegmentedDownloader.Snapshot? {
        let parts = s.split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count >= 4 else { return nil }
        let got = Int64(parts[0] ?? 0)
        let total = Int64(parts[1] ?? parts[2] ?? -1)
        var snap = snapshot(got, total)
        snap.connections = 8
        return snap
    }
}
