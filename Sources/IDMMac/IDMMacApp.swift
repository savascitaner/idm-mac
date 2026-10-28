import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // These can take seconds on a first start; the window must not wait for them.
        DispatchQueue.global(qos: .utility).async {
            Self.clearQuarantine()
            _ = SignatureInfo.developer
        }
        if let i = CommandLine.arguments.firstIndex(of: "--search-test"), i + 1 < CommandLine.arguments.count {
            // Used by the CI smoke test: run the torrent search once, print what came back, quit.
            let q = CommandLine.arguments[i + 1]
            Task {
                let (found, errors) = await TorrentSearch.run(q, in: TorrentSearch.sources)
                for r in found.prefix(40) { print("RESULT\t\(r.source)\t\(r.title)\t\(r.link)") }
                for e in errors { print("ERROR\t\(e)") }
                exit(found.isEmpty ? 1 : 0)
            }
            return
        }
        AppModel.shared.boot()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count,
           AppModel.shared.isDemo {
            // Used by CI for the guide's screenshots: draws each window to a PNG and quits.
            let dir = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Snapshots.run(into: dir) }
        }
    }

    /// Once the user has allowed the app ("Yine de Aç"), drop the quarantine flag from the whole bundle
    /// so the bundled tools and the Safari extension run without further prompts and no Terminal step is needed.
    nonisolated static func clearQuarantine() {
        let path = Bundle.main.bundlePath
        guard getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    /// idmmac:// links come from the Safari extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let msg = SafariBridge.message(from: url) {
                Log.write("safari", "extension message: \(msg["type"] as? String ?? "?") \(msg["url"] as? String ?? msg["pageUrl"] as? String ?? "")")
                AppModel.shared.receive(msg)
            } else if url.scheme == "idmmac" {
                // A bridge link with the wrong token: the extension Safari runs is from another build.
                Log.write("safari", "extension message rejected (token mismatch: an old copy of the extension is registered)")
            } else if url.scheme?.lowercased() == "magnet" {
                AppModel.shared.receive(["type": "torrent", "url": url.absoluteString])
            } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                AppModel.shared.receive(["type": "torrent", "url": url.path])
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.pauseAll()
        AppModel.shared.save()
        TorrentService.shared.stop()
    }

    /// Clicking the Dock icon brings the main window back, whether it was minimised or closed.
    /// The menu bar panel counts as a window for AppKit, so `hasVisibleWindows` cannot be trusted here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.window("dock reopen (AppKit says visible windows: \(flag), main window found: \(MainWindow.window != nil))")
        MainWindow.show()
        // With no main window to show, let SwiftUI open one as well.
        return MainWindow.window == nil
    }

    // Keep running in the menu bar when the window is closed, like IDM in the tray.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct IDMMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("MDM - Mac Download Manager", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("MDM Hakkında") { AboutPanel.show() }
                Button("Güncellemeleri denetle…") { Updater.shared.checkWithAnswer() }
            }
            CommandGroup(replacing: .newItem) {
                AddURLCommand()
            }
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// The menu bar icon. It lives as long as the app, so it can open the main window again after it was closed.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                Log.window("opening a new main window")
                openWindow(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainWindow.window?.makeKeyAndOrderFront(nil) }
            }
    }
}

struct AddURLCommand: View {
    var body: some View {
        Button("Adres ekle…") {
            NotificationCenter.default.post(name: .showAddURL, object: nil)
        }
        .keyboardShortcut("n")
    }
}

extension Notification.Name {
    static let showAddURL = Notification.Name("IDMMacShowAddURL")
}

/// Who signed this copy of MDM, read from the app's own code signature.
enum SignatureInfo {
    /// "Developer ID Application: NAME (TEAM)" when the app carries an Apple Developer ID signature.
    static let developer: String? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", Bundle.main.bundlePath]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").lazy
            .compactMap { $0.hasPrefix("Authority=Developer ID Application:") ? String($0.dropFirst("Authority=".count)) : nil }
            .first
    }()

    static var summary: String {
        developer.map { "İmza: \($0) · Apple tarafından doğrulanmış" } ?? "İmza: Apple Developer ID yok (imzasız derleme)"
    }
}

enum AboutPanel {
    static let owner = "Enes Savaşçı"

    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        credits.append(NSAttributedString(string: "Bu uygulama \(owner) tarafından, kendi kullanımı için yaptırılmıştır. Tüm hakları \(owner)'ya aittir; izinsiz dağıtılamaz.\n\n", attributes: body))
        credits.append(NSAttributedString(string: SignatureInfo.summary + "\n\n", attributes: body))
        credits.append(NSAttributedString(string: "İçindeki açık kaynak bileşenler: yt-dlp (Unlicense), FFmpeg (GPL/LGPL), Deno (MIT). Ayrıntılar uygulama paketindeki THIRD_PARTY.md dosyasında.", attributes: small))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MDM - Mac Download Manager",
            .credits: credits,
        ])
    }
}
