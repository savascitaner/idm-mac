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
        w.title = "Videoyu indir"
        w.styleMask = [.titled, .closable, .utilityWindow]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 460, height: 380))
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
                    Button("İndir") {
                        AppModel.shared.addVideo(info: info, option: selection ?? info.options[0],
                                                 headers: request.headers, cookies: usedCookies ? request.cookies : [])
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 380)
        .onAppear(perform: load)
    }

    /// Tries the page without cookies first (yt-dlp advises against cookies unless a site needs them,
    /// and sending them can make YouTube rotate the browser session), then with the browser cookies,
    /// then the media URL the extension saw.
    private func load() {
        let cookieFile = YtDlp.cookieFile(for: request.id, cookies: request.cookies)
        var attempts: [(url: String, cookies: URL?)] = [(request.pageURL, nil)]
        if let c = cookieFile { attempts.append((request.pageURL, c)) }
        if let m = request.mediaURL, !m.isEmpty, !m.hasPrefix("blob:"), m != request.pageURL {
            attempts.append((m, cookieFile))
        }
        run(attempts, firstError: nil) { result in
            if let f = cookieFile { try? FileManager.default.removeItem(at: f) }
            switch result {
            case .success(let (i, withCookies)):
                info = i
                usedCookies = withCookies
                selection = i.options.first
            case .failure(let e):
                error = e.localizedDescription
            }
            loading = false
        }
    }

    private func run(_ attempts: [(url: String, cookies: URL?)], firstError: Error?,
                     done: @escaping (Result<(VideoInfo, Bool), Error>) -> Void) {
        guard let a = attempts.first else {
            done(.failure(firstError ?? YtDlp.Failure("Video bilgisi alınamadı")))
            return
        }
        YtDlp.probe(url: a.url, cookieFile: a.cookies, headers: request.headers) { r in
            switch r {
            case .success(let i): done(.success((i, a.cookies != nil)))
            case .failure(let e): run(Array(attempts.dropFirst()), firstError: firstError ?? e, done: done)
            }
        }
    }

    private func cleanup(_ f: URL?) {
        if let f { try? FileManager.default.removeItem(at: f) }
    }
}
