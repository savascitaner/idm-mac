import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showExtensionHelp = false
    @State private var selection = Set<UUID>()
    @State private var sidebar: SidebarItem? = .all

    private var filtered: [DownloadRecord] {
        let f = sidebar ?? .all
        return model.downloads.filter { f.matches($0) }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.downloads.isEmpty {
                    EmptyState(showExtensionHelp: $showExtensionHelp)
                } else if filtered.isEmpty {
                    Text("Bu bölümde indirme yok").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(filtered) { d in
                            DownloadRow(record: d).tag(d.id)
                                .contextMenu { rowMenu(d) }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
                Divider()
                HStack {
                    Text(model.activeCount > 0 ? "\(model.activeCount) etkin indirme · \(Format.speed(model.totalSpeed))" : "Hazır")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.browsersLinked.isEmpty {
                        Text("Chrome bulunamadı").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .navigationTitle((sidebar ?? .all).title)
            .toolbar {
                ToolbarItemGroup {
                    Button { showAdd = true } label: { Label("Adres ekle", systemImage: "plus") }
                    Button { model.resumeAll() } label: { Label("Tümünü sürdür", systemImage: "play.fill") }
                    Button { model.pauseAll() } label: { Label("Tümünü duraklat", systemImage: "pause.fill") }
                    Button { model.clearCompleted() } label: { Label("Bitenleri temizle", systemImage: "checkmark.circle") }
                    Button { showExtensionHelp = true } label: { Label("Chrome eklentisi", systemImage: "puzzlepiece.extension") }
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddURLSheet() }
        .sheet(isPresented: $showExtensionHelp) { ExtensionHelpSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .showAddURL)) { _ in showAdd = true }
        .onDeleteCommand { selection.forEach { model.remove($0) } }
    }

    @ViewBuilder
    private func rowMenu(_ d: DownloadRecord) -> some View {
        if d.state == .completed {
            Button("Aç") { model.open(d) }
            Button("Finder'da göster") { model.reveal(d) }
        }
        if d.isActive { Button("Duraklat") { model.pause(d.id) } }
        if d.state == .paused || d.state == .failed { Button("Sürdür") { model.resume(d.id) } }
        Button("Adresi kopyala") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(d.url, forType: .string)
        }
        Divider()
        Button("Listeden kaldır") { model.remove(d.id) }
        if d.state == .completed { Button("Dosyayı çöpe at") { model.remove(d.id, deleteFile: true) } }
    }
}

struct DownloadRow: View {
    @EnvironmentObject var model: AppModel
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 10) {
            let cat = Category.of(record)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(cat.color.gradient)
                Image(systemName: cat.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .overlay(alignment: .bottomTrailing) { stateBadge }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.fileName.isEmpty ? record.url : record.fileName).lineLimit(1).truncationMode(.middle)
                if record.state == .downloading || record.state == .paused {
                    if record.totalBytes > 0 {
                        SegmentBar(record: record, tint: record.state == .paused ? .gray : Category.of(record).color)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(statusLine).font(.caption).foregroundStyle(record.state == .failed ? .red : .secondary).lineLimit(1)
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 4)
        .onTapGesture(count: 2) { if record.state == .completed { model.open(record) } }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch record.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).font(.system(size: 13)).offset(x: 4, y: 4)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.system(size: 13)).offset(x: 4, y: 4)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.white, .gray).font(.system(size: 13)).offset(x: 4, y: 4)
        default:
            EmptyView()
        }
    }

    private var statusLine: String {
        switch record.state {
        case .queued: return "Sırada"
        case .downloading:
            var parts = ["\(Format.bytes(record.receivedBytes)) / \(Format.bytes(record.totalBytes))"]
            if record.totalBytes > 0 { parts.append(String(format: "%%%.0f", record.progress * 100)) }
            let sp = Format.speed(record.speed)
            if !sp.isEmpty { parts.append(sp) }
            let eta = Format.eta(remaining: record.totalBytes - record.receivedBytes, speed: record.speed)
            if !eta.isEmpty { parts.append("kalan \(eta)") }
            if record.connections > 1 { parts.append("\(record.connections) bağlantı") }
            return parts.joined(separator: " · ")
        case .paused: return "Duraklatıldı · \(Format.bytes(record.receivedBytes)) / \(Format.bytes(record.totalBytes))"
        case .completed: return "Tamamlandı · \(Format.bytes(record.totalBytes))"
        case .failed: return "Hata: \(record.error ?? "bilinmiyor")"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 6) {
            switch record.state {
            case .downloading, .queued:
                Button { model.pause(record.id) } label: { Image(systemName: "pause.fill") }.help("Duraklat")
            case .paused, .failed:
                Button { model.resume(record.id) } label: { Image(systemName: "play.fill") }.help("Sürdür")
            case .completed:
                Button { model.open(record) } label: { Image(systemName: "arrow.up.forward.app") }.help("Aç")
                Button { model.reveal(record) } label: { Image(systemName: "folder") }.help("Finder'da göster")
            }
            Button { model.remove(record.id) } label: { Image(systemName: "xmark") }.help("Kaldır")
        }
        .buttonStyle(.borderless)
    }
}

struct EmptyState: View {
    @Binding var showExtensionHelp: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Henüz indirme yok").font(.title3)
            Text("Chrome'da bir indirme linkine tıkla ya da bir videonun üstündeki \"Bu videoyu indir\" butonunu kullan.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Chrome eklentisini kur") { showExtensionHelp = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct AddURLSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("İndirilecek adres").font(.headline)
            TextField("https://…", text: $text).textFieldStyle(.roundedBorder).frame(width: 460)
            Text("YouTube, Vimeo, X gibi video sayfaları için kalite seçimi açılır.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("İndir") {
                    model.addFromUserInput(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: text.trimmingCharacters(in: .whitespaces))?.scheme == nil)
            }
        }
        .padding(20)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { text = s }
        }
    }
}

struct ExtensionHelpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chrome eklentisini kur").font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Chrome'da adres çubuğuna **chrome://extensions** yaz ve aç.")
                Text("2. Sağ üstteki **Geliştirici modu** anahtarını aç.")
                Text("3. **Paketlenmemiş öğe yükle** düğmesine bas. Açılan pencerede **Cmd + Shift + G** tuşlarına bas, aşağıdaki yolu yapıştır (\"Yolu kopyala\") ve **Seç**'e bas.")
                Text("Not: Yolu Chrome'un adres çubuğuna yapıştırmak eklentiyi yüklemez, sadece klasörü listeler.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("4. Eklentinin simgesini araç çubuğuna sabitle. Hepsi bu.")
            }
            HStack {
                Text(Paths.extensionDir.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Klasörü göster") {
                    if let dir = HostInstaller.exportExtension() {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                Button("Yolu kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Paths.extensionDir.path, forType: .string)
                }
            }
            Text(model.browsersLinked.isEmpty
                 ? "Uyarı: Chrome profili bulunamadı. Chrome'u bir kez açıp bu uygulamayı yeniden başlat."
                 : "Bağlanan tarayıcılar: " + model.browsersLinked.joined(separator: ", "))
                .font(.caption).foregroundStyle(model.browsersLinked.isEmpty ? .orange : .secondary)
            HStack {
                Spacer()
                Button("Tamam") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
