import Foundation

enum DownloadKind: String, Codable {
    case file
    case video
}

enum DownloadState: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

/// One byte range of a segmented download. `end` is inclusive; -1 means "until EOF" (unknown size).
struct Segment: Codable, Equatable {
    var start: Int64
    var end: Int64
    var done: Int64

    var current: Int64 { start + done }
    var isComplete: Bool { end >= 0 && current > end }
    var remaining: Int64 { end >= 0 ? max(0, end - current + 1) : Int64.max }
}

struct BrowserCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var hostOnly: Bool
    var expirationDate: Double
}

struct DownloadRecord: Codable, Identifiable {
    var id = UUID()
    var kind: DownloadKind
    var url: String
    var pageURL: String?
    var fileName: String
    var directory: String
    var state: DownloadState = .queued
    var totalBytes: Int64 = -1
    var receivedBytes: Int64 = 0
    var speed: Double = 0
    var connections: Int = 0
    var error: String?
    var headers: [String: String] = [:]
    var cookies: [BrowserCookie] = []
    var segments: [Segment] = []
    var tempPath: String?
    var finalPath: String?
    var browserMime: String?
    var originalURL: String?
    var browserFallback: String?   // "safari": reopen there if the link turns out to be a web page
    var videoFormat: String?
    var videoSort: String?
    var audioOnly: Bool = false
    var thumbnail: String?
    var audioLanguage: String?
    var playlistIndex: Int?
    var createdAt = Date()
    var completedAt: Date?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var isActive: Bool { state == .downloading || state == .queued }
}

extension BrowserCookie {
    /// Line for a Netscape cookies.txt file (the format yt-dlp reads).
    var netscapeLine: String {
        let includeSub = hostOnly ? "FALSE" : "TRUE"
        var dom = domain
        if !hostOnly && !dom.hasPrefix(".") { dom = "." + dom }
        let exp = expirationDate > 0 ? String(Int64(expirationDate)) : "0"
        let prefix = httpOnly ? "#HttpOnly_" : ""
        return [prefix + dom, includeSub, path.isEmpty ? "/" : path, secure ? "TRUE" : "FALSE", exp, name, value]
            .joined(separator: "\t")
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        guard n >= 0 else { return "?" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String {
        guard bps > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/sn"
    }

    static func eta(remaining: Int64, speed: Double) -> String {
        guard speed > 1, remaining > 0 else { return "" }
        let s = Int(Double(remaining) / speed)
        if s >= 3600 { return String(format: "%d sa %02d dk", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return String(format: "%d dk %02d sn", s / 60, s % 60) }
        return "\(s) sn"
    }
}
