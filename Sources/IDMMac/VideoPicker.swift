import AppKit
import SwiftUI

struct VideoRequest: Identifiable {
    let id = UUID()
    var pageURL: String
    var mediaURL: String?
    var title: String
    var headers: [String: String]
    var cookies: [BrowserCookie]
}

/// Shows the "download this video" dialog in its own floating window, like IDM's popup.
@MainActor
final class VideoWindowController {
    private var windows: [UUID: NSWindow] = [:]

    func show(_ req: VideoRequest) {
        let view = VideoPickerView(request: req) { [weak self] in self?.close(req.id) }
        let host = NSHostingController(rootView: view)
        let w = NSPanel(contentViewController: host)
        w.title = L("Videoyu indir")
        w.styleMask = [.titled, .closable, .utilityWindow]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 520, height: 620))
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

struct VideoPickerView: View {
    let request: VideoRequest
    let dismiss: () -> Void

    @State private var info: VideoInfo?
    @State private var error: String?
    @State private var selection: VideoOption?
    @State private var loading = true
    @State private var usedCookies = false
    @State private var playlist: PlaylistInfo?
    @State private var wholeList = false
    @State private var track: AudioTrack?
    @State private var picked: Set<String> = []

    private var query: [URLQueryItem] { URLComponents(string: request.pageURL)?.queryItems ?? [] }
    private var listID: String? { query.first { $0.name == "list" }?.value }
    /// A watch page inside a playlist has both v= and list=; a playlist page has only list=.
    private var hasVideo: Bool {
        query.contains { $0.name == "v" } || request.pageURL.contains("/shorts/") || request.pageURL.contains("youtu.be/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Video bilgisi alınıyor…")
                }
                Text(request.title.isEmpty ? request.pageURL : request.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            } else if let info {
                HStack(alignment: .top, spacing: 12) {
                    if let t = info.thumbnail, let u = URL(string: t) {
                        AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 128, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).font(.headline).lineLimit(3)
                        if let d = info.duration, d > 0 {
                            Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let playlist {
                    if hasVideo {
                        Picker("", selection: $wholeList) {
                            Text("Sadece bu video").tag(false)
                            Text("Tüm liste (\(playlist.entries.count) video)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } else {
                        Label("Oynatma listesi: \(playlist.title) · \(playlist.entries.count) video", systemImage: "list.bullet.rectangle")
                            .font(.callout).lineLimit(1)
                    }
                    if wholeList {
                        Text("İşaretlediğin videolar İndirilenler'de \"\(FileMeta.sanitize(playlist.title))\" klasörüne sırayla iner; seçtiğin kalite ve dil hepsine uygulanır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if info.audioTracks.count > 1 {
                    Picker("Ses dili (dublaj)", selection: $track) {
                        ForEach(info.audioTracks) { t in Text(t.label).tag(Optional(t)) }
                    }
                }
                if wholeList, let playlist {
                    Picker("Kalite", selection: $selection) {
                        ForEach(info.options) { opt in Text("\(opt.label)  \(opt.detail)").tag(Optional(opt)) }
                    }
                    entryList(playlist)
                } else {
                    Text("Kalite").font(.subheadline.bold())
                    List(info.options, selection: $selection) { opt in
                        HStack {
                            Text(opt.label)
                            Spacer()
                            Text(opt.detail).foregroundStyle(.secondary)
                        }
                        .tag(opt)
                    }
                    .frame(minHeight: 150)
                }
            } else {
                Label("Bu sayfada indirilebilir video bulunamadı.", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer()
            }

            HStack {
                Text(AppModel.shared.downloadDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                if info == nil, !loading, let m = request.mediaURL, !m.isEmpty {
                    Button("Dosyayı doğrudan indir") {
                        AppModel.shared.addFile(url: m, headers: request.headers, cookies: request.cookies)
                        dismiss()
                    }
                }
                if let info {
                    Button(wholeList ? L("Seçilenleri indir (%lld)", picked.count) : L("İndir")) {
                        let option = selection ?? info.options[0]
                        let cookies = usedCookies ? request.cookies : []
                        if wholeList, let playlist {
                            AppModel.shared.addPlaylist(playlist, only: picked, option: option, track: track,
                                                        headers: request.headers, cookies: cookies)
                        } else {
                            AppModel.shared.addVideo(info: info, option: option, track: track,
                                                     headers: request.headers, cookies: cookies)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wholeList && picked.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 620)
        .onAppear(perform: load)
    }

    /// Tries the page without cookies first (yt-dlp advises against cookies unless a site needs them,
    /// and sending them can make YouTube rotate the browser session), then with the browser cookies,
    /// then the media URL the extension saw.
    private func load() {
        guard listID != nil else { return probeVideo(request.pageURL) }
        if hasVideo { probeVideo(request.pageURL) }
        YtDlp.probePlaylist(url: request.pageURL, cookieFile: nil, headers: request.headers) { r in
            if case .success(let list) = r {
                playlist = list
                picked = Set(list.entries.map(\.id))
                if !hasVideo { wholeList = true }
            }
            guard !hasVideo else { return }
            // A playlist page has no video of its own: offer the qualities and languages of its first video.
            if let first = playlist?.entries.first {
                probeVideo(first.url)
            } else {
                if case .failure(let e) = r { error = e.localizedDescription }
                loading = false
            }
        }
    }

    private func probeVideo(_ page: String) {
        let cookieFile = YtDlp.cookieFile(for: request.id, cookies: request.cookies)
        var attempts: [(url: String, cookies: URL?)] = [(page, nil)]
        if let c = cookieFile { attempts.append((page, c)) }
        if page == request.pageURL, let m = request.mediaURL, !m.isEmpty, !m.hasPrefix("blob:"), m != page {
            attempts.append((m, cookieFile))
        }
        run(attempts, firstError: nil) { result in
            if let f = cookieFile { try? FileManager.default.removeItem(at: f) }
            switch result {
            case .success(let (i, withCookies)):
                info = i
                usedCookies = withCookies
                selection = i.options.first
                track = i.defaultTrack
            case .failure(let e):
                error = e.localizedDescription
            }
            loading = false
        }
    }

    private func run(_ attempts: [(url: String, cookies: URL?)], firstError: Error?,
                     done: @escaping (Result<(VideoInfo, Bool), Error>) -> Void) {
        guard let a = attempts.first else {
            done(.failure(firstError ?? YtDlp.Failure(L("Video bilgisi alınamadı"))))
            return
        }
        YtDlp.probe(url: a.url, cookieFile: a.cookies, headers: request.headers) { r in
            switch r {
            case .success(let i): done(.success((i, a.cookies != nil)))
            case .failure(let e): run(Array(attempts.dropFirst()), firstError: firstError ?? e, done: done)
            }
        }
    }

    /// The playlist's videos with a checkbox each, so only the wanted ones are queued.
    private func entryList(_ playlist: PlaylistInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Videolar").font(.subheadline.bold())
                Text("\(picked.count) / \(playlist.entries.count) seçili").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Tümünü seç") { picked = Set(playlist.entries.map(\.id)) }
                Button("Hiçbirini") { picked = [] }
            }
            .controlSize(.small)
            List(Array(playlist.entries.enumerated()), id: \.element.id) { i, e in
                Toggle(isOn: Binding(
                    get: { picked.contains(e.id) },
                    set: { on in if on { picked.insert(e.id) } else { picked.remove(e.id) } }
                )) {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        AsyncImage(url: URL(string: e.thumbnail ?? "https://i.ytimg.com/vi/\(e.id)/default.jpg")) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 48, height: 27).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(e.title).lineLimit(1)
                        Spacer()
                        if let d = e.duration, d > 0 {
                            Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 200)
        }
    }

    private func cleanup(_ f: URL?) {
        if let f { try? FileManager.default.removeItem(at: f) }
    }
}
