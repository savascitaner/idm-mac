import Foundation

/// One hit in the torrent search tab.
struct TorrentResult: Identifiable, Hashable {
    var id: String { link }
    var title: String
    var detail: String
    var source: String
    var link: String          // .torrent URL or magnet link
    var page: String?
    var thumbnail: String?
}

/// A place the search tab looks in. Only legal, openly licensed sources are offered.
protocol TorrentSource {
    var name: String { get }
    func search(_ query: String) async throws -> [TorrentResult]
}

enum TorrentSearch {
    static let sources: [TorrentSource] = [InternetArchiveSource(), LinuxSource()]

    /// Runs every source at once; a source that fails only adds a note, the others still show.
    static func run(_ query: String, in chosen: [TorrentSource]) async -> (results: [TorrentResult], errors: [String]) {
        await withTaskGroup(of: (String, Result<[TorrentResult], Error>).self) { group in
            for s in chosen {
                group.addTask {
                    do { return (s.name, .success(try await s.search(query))) } catch { return (s.name, .failure(error)) }
                }
            }
            var results: [TorrentResult] = []
            var errors: [String] = []
            for await (name, r) in group {
                switch r {
                case .success(let list): results += list
                case .failure(let e): errors.append("\(name): \(e.localizedDescription)")
                }
            }
            return (results, errors)
        }
    }

    static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("MDM (Mac Download Manager)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TorrentService.Failure(errorDescription: "HTTP \(http.statusCode)")
        }
        return data
    }

    /// All .torrent links on an HTML directory listing, as absolute URLs.
    static func torrentLinks(in html: String, base: URL) -> [URL] {
        let re = try! NSRegularExpression(pattern: #"href="([^"]+\.torrent)""#, options: .caseInsensitive)
        let ns = html as NSString
        var seen = Set<String>()
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let href = ns.substring(with: m.range(at: 1))
            guard let u = URL(string: href, relativeTo: base)?.absoluteURL, seen.insert(u.absoluteString).inserted else { return nil }
            return u
        }
    }
}

/// archive.org: public-domain and openly licensed films, music, books and software. Every item
/// has a torrent at /download/<id>/<id>_archive.torrent.
struct InternetArchiveSource: TorrentSource {
    let name = "Internet Archive"

    func search(_ query: String) async throws -> [TorrentResult] {
        // Items in the lending library can only be borrowed, so they have no torrent.
        let q = "(\(query)) AND mediatype:(movies OR audio OR texts OR software OR image) "
            + "AND NOT collection:(inlibrary OR printdisabled OR lendinglibrary)"
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
            + ["identifier", "title", "mediatype", "item_size", "year", "creator"].map { URLQueryItem(name: "fl[]", value: $0) }
            + [URLQueryItem(name: "sort[]", value: "downloads desc"),
               URLQueryItem(name: "rows", value: "50"),
               URLQueryItem(name: "output", value: "json")]
        let data = try await TorrentSearch.get(c.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let docs = (json?["response"] as? [String: Any])?["docs"] as? [[String: Any]] ?? []
        return docs.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let title = Self.text(d["title"]) ?? id
            var parts = [Self.kind(d["mediatype"] as? String)]
            if let y = Self.text(d["year"]) { parts.append(y) }
            if let a = Self.text(d["creator"]) { parts.append(a) }
            if let n = (d["item_size"] as? NSNumber)?.int64Value, n > 0 { parts.append(Format.bytes(n)) }
            return TorrentResult(title: title, detail: parts.joined(separator: " · "), source: name,
                                 link: "https://archive.org/download/\(id)/\(id)_archive.torrent",
                                 page: "https://archive.org/details/\(id)",
                                 thumbnail: "https://archive.org/services/img/\(id)")
        }
    }

    /// Fields come back as a string, a number or a list of strings.
    static func text(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [String] { return a.first }
        return nil
    }

    static func kind(_ m: String?) -> String {
        switch m {
        case "movies": return "Video"
        case "audio": return "Ses"
        case "texts": return "Kitap/Metin"
        case "software": return "Yazılım"
        case "image": return "Görsel"
        default: return m ?? "Öğe"
        }
    }
}

/// Official torrents of Linux distributions, read from the projects' own download servers.
struct LinuxSource: TorrentSource {
    let name = "Linux dağıtımları"

    func search(_ query: String) async throws -> [TorrentResult] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { $0 != "linux" && !$0.isEmpty }
        var all: [TorrentResult] = []
        var failures = 0
        for (distro, fetch) in [("Debian", debian), ("Ubuntu", ubuntu), ("Fedora", fedora)] as [(String, () async throws -> [URL])] {
            do {
                for u in try await fetch() {
                    let file = u.lastPathComponent.replacingOccurrences(of: ".torrent", with: "")
                    all.append(TorrentResult(title: file, detail: "\(distro) resmi torrenti", source: name,
                                             link: u.absoluteString, page: u.deletingLastPathComponent().absoluteString))
                }
            } catch {
                failures += 1
            }
        }
        if failures == 3 { throw TorrentService.Failure(errorDescription: "Dağıtım sunucularına ulaşılamadı") }
        return all.filter { r in
            let hay = (r.title + " " + r.detail).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private func listing(_ s: String) async throws -> [URL] {
        let base = URL(string: s)!
        let html = String(decoding: try await TorrentSearch.get(base), as: UTF8.self)
        return TorrentSearch.torrentLinks(in: html, base: base)
    }

    private func debian() async throws -> [URL] {
        var out: [URL] = []
        for arch in ["amd64", "arm64"] {
            for kind in ["bt-cd", "bt-dvd"] {
                out += (try? await listing("https://cdimage.debian.org/debian-cd/current/\(arch)/\(kind)/")) ?? []
            }
        }
        if out.isEmpty { throw TorrentService.Failure(errorDescription: "Debian") }
        return out
    }

    /// The two newest releases on releases.ubuntu.com (folders named like 24.04/).
    private func ubuntu() async throws -> [URL] {
        let base = URL(string: "https://releases.ubuntu.com/")!
        let html = String(decoding: try await TorrentSearch.get(base), as: UTF8.self)
        let re = try NSRegularExpression(pattern: #"href="(\d{2}\.\d{2}(?:\.\d+)?)/""#)
        let ns = html as NSString
        let versions = Set(re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        var out: [URL] = []
        for v in versions.prefix(2) {
            out += (try? await listing("https://releases.ubuntu.com/\(v)/")) ?? []
        }
        return out
    }

    private func fedora() async throws -> [URL] {
        try await listing("https://torrent.fedoraproject.org/")
    }
}
