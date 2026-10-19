import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var safariWatcher = SafariWatcher.shared
    @AppStorage("downloadDirectory") private var downloadDirectory: String = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage("connections") private var connections: Int = 8
    @AppStorage("maxParallel") private var maxParallel: Int = 3
    @AppStorage("notify") private var notify: Bool = true
    @AppStorage("safariTakeover") private var safariTakeover: Bool = true
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
                Toggle("Safari'nin kendi başlattığı indirmeleri devral", isOn: $safariTakeover)
                    .help("Başka bir uygulamadan açılan linkler de dahil, Safari bir dosya indirmeye başlayınca MDM onu alır.")
                HStack {
                    Text("Safari izleme: " + safariWatcher.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Kaydı göster") { NSWorkspace.shared.activateFileViewerSelecting([SafariWatcher.logFile]) }
                        .controlSize(.small)
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
        .frame(width: 520)
        .padding()
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: downloadDirectory)
        if p.runModal() == .OK, let u = p.url { downloadDirectory = u.path }
    }
}
