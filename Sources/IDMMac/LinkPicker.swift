import AppKit
import SwiftUI

/// One link found on a page by the browser extension ("Sayfadaki tüm linkleri indir").
struct PageLink: Identifiable, Hashable {
    var id: String { url }
    let url: String
    let text: String
    let name: String
    let group: LinkGroup
}

enum LinkGroup: String, CaseIterable, Identifiable {
    case video, music, archive, program, document, image, torrent, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return L("Video")
        case .music: return L("Ses")
        case .archive: return L("Arşiv")
        case .program: return L("Program")
        case .document: return L("Belge")
        case .image: return L("Görsel")
        case .torrent: return L("Torrent")
        case .other: return L("Diğer")
        }
    }

    static let images: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "bmp", "tif", "tiff", "avif"]

    static func of(_ ext: String) -> LinkGroup {
        let e = ext.lowercased()
        if images.contains(e) { return .image }
        switch Category.of(extension: e) {
        case .video: return .video
        case .music: return .music
        case .archive: return .archive
        case .program: return .program
        case .document: return .document
        case .torrent: return .torrent
        case .other: return .other
        }
    }
}

struct LinkRequest: Identifiable {
    let id = UUID()
    let pageURL: String
    let title: String
    let links: [PageLink]
    let headers: [String: String]
    let cookies: [BrowserCookie]

    /// From the extension's "links" message: every <a href> and media source on the page.
    init(_ msg: [String: Any], headers: [String: String], cookies: [BrowserCookie]) {
        pageURL = msg["pageUrl"] as? String ?? ""
        title = msg["title"] as? String ?? ""
        self.headers = headers
        self.cookies = cookies
        let page = pageURL.components(separatedBy: "#").first ?? pageURL
        var seen = Set<String>()
        var out: [PageLink] = []
        for item in msg["items"] as? [[String: Any]] ?? [] {
            guard var url = item["url"] as? String else { continue }
            url = url.components(separatedBy: "#").first ?? url
            guard url != page, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  seen.insert(url).inserted else { continue }
            let last = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
            let name = last.isEmpty || last == "/" ? (u.host ?? url) : last
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(PageLink(url: url, text: text, name: name, group: LinkGroup.of(u.pathExtension)))
        }
        links = out
    }
}

@MainActor
final class LinkWindowController {
    private var windows: [UUID: NSWindow] = [:]

    func show(_ req: LinkRequest) {
        let view = LinkPickerView(request: req) { [weak self] in self?.close(req.id) }
        let w = NSPanel(contentViewController: NSHostingController(rootView: view))
        w.title = L("Sayfadaki linkler")
        w.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 640, height: 560))
        w.center()
        windows[req.id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: UUID) {
        windows[id]?.close()
        windows[id] = nil
    }
}

/// Like IDM's "Download all links": pick file types, tick the links, queue them in one go.
struct LinkPickerView: View {
    let request: LinkRequest
    let dismiss: () -> Void

    @State private var shown: Set<LinkGroup>
    @State private var picked: Set<String>
    @State private var filter = ""

    init(request: LinkRequest, dismiss: @escaping () -> Void) {
        self.request = request
        self.dismiss = dismiss
        // Files are ticked from the start; links to other pages are listed under "Diğer" but left out.
        let files = request.links.filter { $0.group != .other }
        _shown = State(initialValue: Set(LinkGroup.allCases.filter { $0 != .other }))
        _picked = State(initialValue: Set(files.map(\.url)))
    }

    private var groups: [(group: LinkGroup, count: Int)] {
        LinkGroup.allCases.compactMap { g -> (group: LinkGroup, count: Int)? in
            let n = request.links.filter { $0.group == g }.count
            return n > 0 ? (g, n) : nil
        }
    }

    private var visible: [PageLink] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return request.links.filter { l in
            shown.contains(l.group) && (q.isEmpty || l.url.lowercased().contains(q) || l.text.lowercased().contains(q))
        }
    }

    private var chosen: [PageLink] { visible.filter { picked.contains($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title.isEmpty ? request.pageURL : request.title).font(.headline).lineLimit(1)
                Text("\(request.links.count) link bulundu").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(groups, id: \.group) { item in
                    Toggle("\(item.group.title) (\(item.count))", isOn: Binding(
                        get: { shown.contains(item.group) },
                        set: { on in if on { shown.insert(item.group) } else { shown.remove(item.group) } }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
            TextField("Süz: ad, uzantı ya da adresin bir parçası (ör. .zip)", text: $filter)
                .textFieldStyle(.roundedBorder)
            List(visible) { l in
                Toggle(isOn: Binding(
                    get: { picked.contains(l.url) },
                    set: { on in if on { picked.insert(l.url) } else { picked.remove(l.url) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(l.name).lineLimit(1).truncationMode(.middle)
                            Text(l.group.title).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        Text(l.text.isEmpty || l.text == l.name ? l.url : "\(l.text) · \(l.url)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Görünenleri seç") { picked.formUnion(visible.map(\.url)) }
                Button("Hiçbirini") { picked.subtract(visible.map(\.url)) }
                Spacer()
                Button("İptal", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Seçilenleri indir (\(chosen.count))") {
                    AppModel.shared.addLinks(chosen, from: request)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
    }
}
