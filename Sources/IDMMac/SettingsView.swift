import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Taller only for the guide's snapshot, so every section shows.
    static var height: CGFloat = 780

    @EnvironmentObject var model: AppModel
    @ObservedObject private var safariWatcher = SafariWatcher.shared
    @AppStorage("downloadDirectory") private var downloadDirectory: String = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage("connections") private var connections: Int = 8
    @AppStorage("maxParallel") private var maxParallel: Int = 3
    @AppStorage("notify") private var notify: Bool = true
    @AppStorage("safariTakeover") private var safariTakeover: Bool = true
    @AppStorage("clipboardWatch") private var clipboardWatch: Bool = true
    @AppStorage("speedLimitKB") private var speedLimitKB: Int = 0
    @AppStorage("slowMode") private var slowMode: Bool = false
    @AppStorage("slowModeKB") private var slowModeKB: Int = 256
    @AppStorage("scheduleOn") private var scheduleOn: Bool = false
    @AppStorage("scheduleStart") private var scheduleStart: Int = 2 * 3600
    @AppStorage("scheduleStop") private var scheduleStop: Int = 8 * 3600
    @AppStorage("afterAll") private var afterAll: String = Schedule.AfterAll.none.rawValue
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck: Bool = true
    @AppStorage("autoInstallUpdate") private var autoInstallUpdate: Bool = true
    @AppStorage("glassLook") private var glassLook: Bool = true
    @AppStorage("menuBarInfo") private var menuBarInfo: String = "icon"
    @ObservedObject private var updater = Updater.shared
    @State private var updateOutput = ""

    var body: some View {
        Form {
            Section("İndirme") {
                HStack {
                    Text("Klasör")
                    Text(downloadDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Değiştir…") { chooseFolder() }
                }
                Stepper("Dosya başına bağlantı: \(connections)", value: $connections, in: 1...32)
                Stepper("Aynı anda indirme: \(maxParallel)", value: $maxParallel, in: 1...10)
                Toggle("Bitince bildirim göster", isOn: $notify)
                Toggle("Kopyalanan indirme linklerini sor (pano izleme)", isOn: $clipboardWatch)
                    .help("Bir dosya, video ya da magnet linki kopyaladığında MDM 'İndirilsin mi?' diye bildirim gösterir.")
                Toggle("Safari'nin kendi başlattığı indirmeleri devral", isOn: $safariTakeover)
                    .help("Başka bir uygulamadan açılan linkler de dahil, Safari bir dosya indirmeye başlayınca MDM onu alır.")
                HStack {
                    Text("Magnet linkleri ve .torrent dosyaları").font(.callout)
                    Spacer()
                    Button("MDM ile açılsın") { Self.claimTorrentLinks() }
                        .help("Başka bir uygulamada ya da tarayıcıda tıklanan magnet linklerini MDM açar.")
                }
                HStack {
                    Text("Safari izleme: " + safariWatcher.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Kaydı göster") { NSWorkspace.shared.activateFileViewerSelecting([SafariWatcher.logFile]) }
                        .controlSize(.small)
                }
            }
            Section("Hız") {
                HStack {
                    Text("Hız sınırı")
                    Spacer()
                    TextField("", value: $speedLimitKB, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                    Text("KB/sn")
                }
                Toggle("Yavaş mod", isOn: $slowMode)
                    .help("Menü çubuğundan da açılıp kapanır. Açıkken aşağıdaki hız geçerli olur.")
                HStack {
                    Text("Yavaş modda hız").foregroundStyle(slowMode ? .primary : .secondary)
                    Spacer()
                    TextField("", value: $slowModeKB, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                    Text("KB/sn")
                }
                Text("0 = sınırsız. Sınır dosya ve torrent indirmelerinin toplamına uygulanır; videolarda her video başlarken kendi payını alır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zamanlayıcı") {
                Toggle("İndirmeleri yalnızca bu saatlerde yap", isOn: $scheduleOn)
                HStack {
                    DatePicker("Başlangıç", selection: time($scheduleStart), displayedComponents: .hourAndMinute)
                    DatePicker("Bitiş", selection: time($scheduleStop), displayedComponents: .hourAndMinute)
                }
                .disabled(!scheduleOn)
                Text("Bu saatlerin dışında eklenen indirmeler sırada bekler ve başlangıç saatinde kendiliğinden başlar; bitiş saatinde süren indirmeler durup ertesi gün devam eder.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Hepsi bitince", selection: $afterAll) {
                    ForEach(Schedule.AfterAll.allCases) { a in Text(a.title).tag(a.rawValue) }
                }
                Text("Bir kez uygulanır, ardından \"Bir şey yapma\"ya döner. Yapmadan önce 60 saniye boyunca vazgeçme şansı verir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Görünüm") {
                Toggle("Cam görünüm", isOn: $glassLook)
                Picker("Menü çubuğunda göster", selection: $menuBarInfo) {
                    Text("Yalnızca simge").tag("icon")
                    Text("Hız").tag("speed")
                    Text("Yüzde").tag("percent")
                }
            }
            Section("Güncelleme") {
                Toggle("Yeni sürümleri kendiliğinden denetle", isOn: $autoUpdateCheck)
                Toggle("Yeni sürümü kendiliğinden kur (indirme yokken)", isOn: $autoInstallUpdate)
                    .disabled(!autoUpdateCheck)
                Button("Tanı kaydını göster") { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
                HStack {
                    Text(updater.status.isEmpty ? "Sürüm: \(Updater.currentCommit.prefix(7))" : updater.status)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if updater.available != nil {
                        Button(updater.installing ? "Kuruluyor…" : "Güncelle ve yeniden aç") { updater.install() }
                            .disabled(updater.installing)
                    }
                    Button("Şimdi denetle") { updater.check() }.disabled(updater.installing)
                }
            }
            Section("Video") {
                HStack {
                    Text("yt-dlp: " + (Tools.ytdlp?.path ?? "bulunamadı")).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Şimdi güncelle") {
                        updateOutput = "Güncelleniyor…"
                        Tools.updateYtdlpIfNeeded(force: true) { updateOutput = $0 }
                    }
                }
                Text("ffmpeg: " + (Tools.ffmpeg?.path ?? "bulunamadı")).font(.caption)
                if !updateOutput.isEmpty { Text(updateOutput).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: Self.height)
        .padding()
    }

    /// Seconds since midnight shown as a time of day.
    private func time(_ seconds: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(seconds.wrappedValue)) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                seconds.wrappedValue = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60
            })
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: downloadDirectory)
        if p.runModal() == .OK, let u = p.url { downloadDirectory = u.path }
    }

    /// Makes MDM the app that opens magnet: links and .torrent files.
    static func claimTorrentLinks() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "magnet") { _ in }
        if let t = UTType(filenameExtension: "torrent") {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { _ in }
        }
    }
}
