import AppKit

extension Notification.Name {
    /// Asks the always-present menu bar item to open the main window when it does not exist (anymore).
    static let openMainWindow = Notification.Name("IDMMacOpenMainWindow")
}

/// One place that finds, restores and fronts the main window, and shows alerts on it.
@MainActor
enum MainWindow {
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") ?? false }
    }

    static func show() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        // A window that was closed may be gone; if nothing is visible shortly after, ask for a new one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let visible = window?.isVisible ?? false
            Log.window("main window visible after show: \(visible)")
            if !visible { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
        }
    }

    /// Shows the alert as a sheet on the main window, so the rest of the app keeps working while it is open.
    /// Only when no window can be found does it fall back to a modal alert.
    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let w = window, w.isVisible {
                alert.beginSheetModal(for: w, completionHandler: completion)
            } else {
                Log.window("no main window for a sheet; running the alert modally")
                completion(alert.runModal())
            }
        }
    }
}
