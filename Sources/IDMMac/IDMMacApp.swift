import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.clearQuarantine()
        AppModel.shared.boot()
    }

    /// Once the user has allowed the app ("Yine de Aç"), drop the quarantine flag from the whole bundle
    /// so the bundled tools and the Safari extension run without further prompts and no Terminal step is needed.
    static func clearQuarantine() {
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
            if let msg = SafariBridge.message(from: url) { AppModel.shared.receive(msg) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.pauseAll()
        AppModel.shared.save()
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
            }
            CommandGroup(replacing: .newItem) {
                AddURLCommand()
            }
        }

        MenuBarExtra {
            MenuBarPanel().environmentObject(model)
        } label: {
            Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
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

enum AboutPanel {
    static let owner = "Enes Savaşçı"

    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        credits.append(NSAttributedString(string: "Bu uygulama \(owner) tarafından, kendi kullanımı için yaptırılmıştır. Tüm hakları \(owner)'ya aittir; izinsiz dağıtılamaz.\n\n", attributes: body))
        credits.append(NSAttributedString(string: "İçindeki açık kaynak bileşenler: yt-dlp (Unlicense), FFmpeg (GPL/LGPL), Deno (MIT). Ayrıntılar uygulama paketindeki THIRD_PARTY.md dosyasında.", attributes: small))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MDM - Mac Download Manager",
            .credits: credits,
        ])
    }
}
