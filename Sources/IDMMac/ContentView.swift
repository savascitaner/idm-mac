import AppKit
import SafariServices
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showExtensionHelp = false
    @State private var selection = Set<UUID>()
    @State private var sidebar: SidebarItem? = .all
    @State private var query = ""
    @AppStorage("showInspector") private var showInspector = true

    private var filtered: [DownloadRecord] {
        let f = sidebar ?? .all
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.downloads.filter { f.matches($0) }.filter {
            q.isEmpty || $0.fileName.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedRecord: DownloadRecord? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return model.downloads.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            if sidebar == .search {
                TorrentSearchView()
                    .navigationTitle("Torrent ara")
            } else {
                downloadsPane
            }
        }
        .sheet(isPresented: $showAdd) { AddURLSheet() }
        .sheet(isPresented: $showExtensionHelp) { ExtensionHelpSheet() }
        .onAppear {
            // First launch: walk through the browser setup once, without being asked.
            guard !model.isDemo, !UserDefaults.standard.bool(forKey: "setupShown") else { return }
            UserDefaults.standard.set(true, forKey: "setupShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showExtensionHelp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddURL)) { _ in showAdd = true }
        .onDeleteCommand { selection.forEach { model.remove($0) } }
        .onReceive(model.$downloads) { list in
            if model.isDemo, selection.isEmpty, let first = list.first { selection = [first.id] }
        }
    }

    /// The download list with the dashboard, inspector and toolbar.
    private var downloadsPane: some View {
        VStack(spacing: 0) {
            DashboardHeader()
            Divider()
            NoticeBar()
            HStack(spacing: 0) {
                Group {
                    if model.downloads.isEmpty {
                        EmptyState(showExtensionHelp: $showExtensionHelp)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty ? "Bu bölümde indirme yok" : "Aramayla eşleşen indirme yok").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selection) {
                            ForEach(filtered) { d in
                                DownloadRow(record: d).tag(d.id)
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                        // A tap gesture on the rows would swallow the clicks that select them,
                        // so double-click and the context menu go through the list itself.
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if ids.count == 1, let id = ids.first, let d = model.downloads.first(where: { $0.id == id }) {
                                rowMenu(d)
                            }
                        } primaryAction: { ids in
                            for id in ids {
                                if let d = model.downloads.first(where: { $0.id == id }), d.state == .completed { model.open(d) }
                            }
                        }
                        .animation(.default, value: filtered.map(\.id))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    if let rec = selectedRecord {
                        DownloadInspector(record: rec)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "sidebar.right").font(.system(size: 30)).foregroundStyle(.tertiary)
                            Text("Ayrıntıları görmek için bir indirme seç").font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(width: 330)
                        .frame(maxHeight: .infinity)
                    }
                }
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
        .searchable(text: $query, placement: .toolbar, prompt: "İndirmelerde ara")
        .toolbar {
            ToolbarItemGroup {
                Button { showAdd = true } label: { Label("Adres ekle", systemImage: "plus") }
                Button { model.resumeAll() } label: { Label("Tümünü sürdür", systemImage: "play.fill") }
                Button { model.pauseAll() } label: { Label("Tümünü duraklat", systemImage: "pause.fill") }
                Button { model.clearCompleted() } label: { Label("Bitenleri temizle", systemImage: "checkmark.circle") }
                Button { showExtensionHelp = true } label: { Label("Tarayıcı eklentisi", systemImage: "puzzlepiece.extension") }
                Button { showInspector.toggle() } label: { Label("Ayrıntı paneli", systemImage: "sidebar.right") }
                    .help("Ayrıntı panelini aç/kapat")
            }
        }
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
            FileThumb(record: record, size: 36)
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
            if record.connections > 1 { parts.append(record.kind == .torrent ? "\(record.connections) eş" : "\(record.connections) bağlantı") }
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
            Text("YouTube, Vimeo, X gibi video sayfaları için kalite seçimi açılır. Magnet linki ve .torrent adresi de olur.").font(.caption).foregroundStyle(.secondary)
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
            if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") || s.hasPrefix("magnet:") { text = s }
        }
    }
}

struct ExtensionHelpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var browser: Int
    init(browser: Int = 0) { _browser = State(initialValue: browser) }
    @State private var safariReport = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $browser) {
                Text("Chrome").tag(0)
                Text("Safari").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if browser == 0 { chrome } else { safari }
            HStack {
                Spacer()
                Button("Tamam") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var safari: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Safari uzantısını aç").font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Safari > Ayarlar > **Gelişmiş** sekmesinde **Web geliştiricileri için özellikleri göster** kutusunu işaretle.")
                Text("2. Safari > Ayarlar > **Geliştirici** sekmesinde **İmzasız uzantılara izin ver** kutusunu işaretle.")
                Text("3. Safari > Ayarlar > **Uzantılar**'da **MDM**'yi işaretle, sonra **Tüm web sitelerinde her zaman izin ver**'i seç.")
                Text("Uygulama Apple imzalı olmadığı için 2. adım Safari her kapanınca sıfırlanır; Safari'yi her açtığında yeniden işaretle. Uzantı Ayarlar > Uzantılar listesinde yoksa Safari'yi bir kez Cmd+Q ile kapatıp aç; yine yoksa aşağıdaki \"Yeniden kaydet\" düğmesine bas.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Safari'de linke tıklayınca yakalama sadece .dmg, .zip, .mp4 gibi uzantısı belli linklerde çalışır. Video butonu ve sağ tık menüsü Chrome'daki gibi çalışır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Safari'de uzantı ayarlarını aç") {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: SafariBridge.extensionID) { _ in }
                }
                Button("Uzantı listede yok mu? Yeniden kaydet") {
                    safariReport = "Kaydediliyor…"
                    DispatchQueue.global().async {
                        let r = SafariBridge.registerExtension()
                        DispatchQueue.main.async {
                            safariReport = r + "\nSafari'yi Cmd+Q ile tamamen kapat, yeniden aç, sonra Ayarlar > Uzantılar'a bak."
                        }
                    }
                }
            }
            if !safariReport.isEmpty {
                Text(safariReport).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func openChromeExtensions() {
        _ = HostInstaller.exportExtension()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Paths.extensionDir.path, forType: .string)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Google Chrome", "chrome://extensions"]
        try? p.run()
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chrome eklentisini kur").font(.title3.bold())
            Label(model.chromeConnected ? "Eklenti bağlı, kurulum tamam" : "Eklenti henüz bağlanmadı",
                  systemImage: model.chromeConnected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.chromeConnected ? .green : .orange)
            Button {
                openChromeExtensions()
            } label: {
                Label("Chrome'u eklenti sayfasında aç ve klasör yolunu kopyala", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Yukarıdaki düğme Chrome'u **chrome://extensions** sayfasında açtı ve klasör yolunu panoya kopyaladı. Geriye üç tıklama kaldı:")
                Text("1. Sağ üstteki **Geliştirici modu** anahtarını aç.")
                Text("2. **Paketlenmemiş öğe yükle**'ye bas, açılan pencerede **Cmd + Shift + G**, **Cmd + V**, **Enter**, sonra **Seç**.")
                Text("3. İsteğe bağlı: eklentinin simgesini araç çubuğuna sabitle.")
                Text("Chrome mağaza dışı eklentilerin kendiliğinden kurulmasına izin vermediği için bu adım bir kez elle yapılır; sonraki güncellemeleri eklenti kendi yapar.")
                    .font(.caption).foregroundStyle(.secondary)
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
        }
    }
}

/// One-line notices above the list: a newer MDM, or downloads waiting for the scheduler.
struct NoticeBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @AppStorage("scheduleOn") private var scheduleOn = false

    var body: some View {
        VStack(spacing: 0) {
            if let v = updater.available {
                bar("arrow.down.app.fill", .blue, "MDM'nin yeni sürümü hazır (\(v)).") {
                    Button(updater.installing ? "Kuruluyor…" : "Güncelle ve yeniden aç") { updater.install() }
                        .disabled(updater.installing)
                }
            }
            if scheduleOn, !Schedule.allowsNow, model.queuedCount > 0 {
                bar("clock.fill", .orange,
                    "\(model.queuedCount) indirme zamanlayıcıyı bekliyor, saat \(Schedule.clock(Schedule.start)) olunca başlayacak.") {
                    Button("Zamanlayıcıyı kapat") { scheduleOn = false; model.pump() }
                }
            }
        }
    }

    private func bar<B: View>(_ icon: String, _ tint: Color, _ text: String, @ViewBuilder button: () -> B) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.callout)
                Spacer()
                button().controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(tint.opacity(0.08))
            Divider()
        }
    }
}
