import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.boot()
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
        Window("IDM Mac", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("IDM Mac Hakkında") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                AddURLCommand()
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }

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

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.activeCount > 0 {
            Text("\(model.activeCount) indirme · \(Format.speed(model.totalSpeed))")
            Divider()
        }
        Button("Pencereyi aç") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Panodaki adresi indir") {
            if let s = NSPasteboard.general.string(forType: .string) { model.addFromUserInput(s) }
        }
        Divider()
        Button("Tümünü duraklat") { model.pauseAll() }.disabled(model.activeCount == 0)
        Button("Tümünü sürdür") { model.resumeAll() }
        Divider()
        Button("IDM Mac Hakkında") { AboutPanel.show() }
        Button("Çık") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

enum AboutPanel {
    static let owner = "savascitaner"

    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        credits.append(NSAttributedString(string: "Bu uygulama \(owner) tarafından, kendi kullanımı için yaptırılmıştır ve \(owner)'a aittir. İzinsiz dağıtılamaz.\n\n", attributes: body))
        credits.append(NSAttributedString(string: "İçindeki açık kaynak bileşenler: yt-dlp (Unlicense), FFmpeg (GPL/LGPL), Deno (MIT). Ayrıntılar uygulama paketindeki THIRD_PARTY.md dosyasında.", attributes: small))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "IDM Mac",
            .credits: credits,
        ])
    }
}
