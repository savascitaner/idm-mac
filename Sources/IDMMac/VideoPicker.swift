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
                                                 headers: request.headers, cookies: request.cookies)
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

    private func load() {
        let cookieFile = YtDlp.cookieFile(for: request.id, cookies: request.cookies)
        YtDlp.probe(url: request.pageURL, cookieFile: cookieFile, headers: request.headers) { result in
            switch result {
            case .success(let i):
                cleanup(cookieFile)
                info = i
                selection = i.options.first
                loading = false
            case .failure(let e):
                // The page itself may not be supported; try the media URL the extension saw.
                if let m = request.mediaURL, !m.isEmpty, !m.hasPrefix("blob:"), m != request.pageURL {
                    YtDlp.probe(url: m, cookieFile: cookieFile, headers: request.headers) { r2 in
                        cleanup(cookieFile)
                        if case .success(let i) = r2 {
                            info = i
                            selection = i.options.first
                        } else {
                            error = e.localizedDescription
                        }
                        loading = false
                    }
                } else {
                    cleanup(cookieFile)
                    error = e.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func cleanup(_ f: URL?) {
        if let f { try? FileManager.default.removeItem(at: f) }
    }
}
