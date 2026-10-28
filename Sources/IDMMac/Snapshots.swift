import AppKit
import SwiftUI

/// `--demo --snapshots <dir>`: draws the main window and the other windows (setup guide, settings,
/// link picker, torrent search, menu bar panel) to PNG files with sample data. CI uses it to refresh
/// the pictures in the installation guide.
@MainActor
enum Snapshots {
    private static var windows: [NSWindow] = []

    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") ?? false }) {
            main.makeKeyAndOrderFront(nil)
            write(main, dir, "main")
        }
        let links = LinkRequest(sampleLinks, headers: [:], cookies: [])
        let steps: [(String, AnyView, NSSize, Double)] = [
            ("setup-chrome", AnyView(ExtensionHelpSheet(browser: 0).environmentObject(model)), NSSize(width: 560, height: 470), 1),
            ("setup-safari", AnyView(ExtensionHelpSheet(browser: 1).environmentObject(model)), NSSize(width: 560, height: 470), 1),
            ("settings", AnyView(SettingsView().environmentObject(model)), NSSize(width: 600, height: 520), 1),
            ("linkpicker", AnyView(LinkPickerView(request: links, dismiss: {})), NSSize(width: 640, height: 520), 1),
            ("search", AnyView(TorrentSearchView(initialQuery: "night of the living dead").environmentObject(model)), NSSize(width: 820, height: 520), 12),
            ("menubar", AnyView(MenuBarPanel().environmentObject(model)), NSSize(width: 340, height: 420), 1),
        ]
        next(steps[...], dir)
    }

    private static func next(_ rest: ArraySlice<(String, AnyView, NSSize, Double)>, _ dir: String) {
        guard let (name, view, size, wait) = rest.first else {
            try? "ok".write(toFile: dir + "/done", atomically: true, encoding: .utf8)
            exit(0)
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(size)
        w.center()
        w.orderFrontRegardless()
        windows.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            write(w, dir, name)
            next(rest.dropFirst(), dir)
        }
    }

    private static func write(_ w: NSWindow, _ dir: String, _ name: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
    }

    private static let sampleLinks: [String: Any] = [
        "pageUrl": "https://ornek.com/indirmeler", "title": L("Örnek Yazılım: Sürümler"),
        "items": [
            ["url": "https://ornek.com/dl/ornek-2.4.0-arm64.dmg", "text": "macOS (Apple Silicon)"],
            ["url": "https://ornek.com/dl/ornek-2.4.0-x64.dmg", "text": "macOS (Intel)"],
            ["url": "https://ornek.com/dl/ornek-2.4.0-win.zip", "text": "Windows"],
            ["url": "https://ornek.com/dl/kullanim-kilavuzu.pdf", "text": L("Kullanım kılavuzu")],
            ["url": "https://ornek.com/dl/tanitim.mp4", "text": L("Tanıtım videosu")],
            ["url": "https://ornek.com/dl/ses-paketi.mp3", "text": L("Ses paketi")],
            ["url": "https://ornek.com/dl/kaynak.tar.gz", "text": L("Kaynak kodu")],
            ["url": "https://ornek.com/ekran-1.png", "text": L("Ekran görüntüsü")],
            ["url": "https://ornek.com/hakkinda", "text": L("Hakkında")],
            ["url": "https://ornek.com/iletisim", "text": L("İletişim")],
        ],
    ]
}
