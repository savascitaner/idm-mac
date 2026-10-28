import AppKit
import Foundation

/// Times are stored as seconds since midnight; a window like 23:00–07:00 runs over midnight.
enum Schedule {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "scheduleOn") }
    static var start: Int { UserDefaults.standard.object(forKey: "scheduleStart") as? Int ?? 2 * 3600 }
    static var stop: Int { UserDefaults.standard.object(forKey: "scheduleStop") as? Int ?? 8 * 3600 }

    /// Whether downloads may run now (always, when the schedule is off).
    static var allowsNow: Bool {
        guard isOn, start != stop else { return true }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60
        return start < stop ? (now >= start && now < stop) : (now >= start || now < stop)
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    /// What to do once every download has finished. It runs once, then goes back to "none".
    enum AfterAll: String, CaseIterable, Identifiable {
        case none, sleep, shutdown, quit
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return L("Bir şey yapma")
            case .sleep: return L("Mac'i uyut")
            case .shutdown: return L("Mac'i kapat")
            case .quit: return L("MDM'den çık")
            }
        }

        /// "Mac 60 saniye içinde uyutulacak."
        var future: String {
            switch self {
            case .none: return ""
            case .sleep: return L("Mac uyutulacak")
            case .shutdown: return L("Mac kapatılacak")
            case .quit: return L("MDM kapanacak")
            }
        }

        static var current: AfterAll { AfterAll(rawValue: UserDefaults.standard.string(forKey: "afterAll") ?? "") ?? .none }
    }
}

extension AppModel {
    /// Runs every second: starts the queue when the window opens, holds running downloads when it closes.
    func checkSchedule() {
        let open = Schedule.allowsNow
        guard open != scheduleWasOpen else { return }
        scheduleWasOpen = open
        if open {
            if queuedCount > 0 { notifyUser("Zamanlayıcı", "Sıradaki indirmeler başlıyor") }
            pump()
        } else {
            let running = downloads.filter { $0.state == .downloading }
            running.forEach { hold($0.id) }
            if !running.isEmpty {
                notifyUser("Zamanlayıcı", L("İndirmeler durdu, saat %@ olunca sürecek", Schedule.clock(Schedule.start)))
            }
        }
    }

    /// Called when a download ends; once nothing is left, runs the "when all are done" action.
    func checkAllDone() {
        let action = Schedule.AfterAll.current
        guard action != .none, !downloads.contains(where: { $0.isActive }) else { return }
        UserDefaults.standard.set(Schedule.AfterAll.none.rawValue, forKey: "afterAll")
        DispatchQueue.main.async { self.countDown(action) }
    }

    /// Asks for 60 seconds before acting, so someone at the Mac can cancel.
    private func countDown(_ action: Schedule.AfterAll) {
        let alert = NSAlert()
        alert.messageText = L("İndirmelerin hepsi bitti")
        alert.addButton(withTitle: L("Şimdi"))
        alert.addButton(withTitle: L("Vazgeç"))
        let shown = ModalFlag()
        func tick(_ left: Int) {
            guard shown.open else { return }
            alert.informativeText = L("%lld saniye içinde %@.", left, action.future)
            guard left > 0 else {
                // The alert is a sheet on the main window (or, as a last resort, a modal alert).
                if let parent = alert.window.sheetParent {
                    parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                } else {
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(left - 1) }
        }
        tick(60)
        MainWindow.present(alert) { [weak self] answer in
            shown.open = false
            guard answer == .alertFirstButtonReturn else { return }
            self?.perform(action)
        }
    }

    private func perform(_ action: Schedule.AfterAll) {
        save()
        switch action {
        case .none:
            break
        case .sleep:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            try? p.run()
        case .shutdown:
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
            if error != nil {
                notifyUser("Mac kapatılamadı", "Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon'da MDM'nin System Events'i denetlemesine izin ver.")
            }
        case .quit:
            NSApp.terminate(nil)
        }
    }
}

/// Tells the countdown the alert is gone, so it doesn't stop some other modal window.
private final class ModalFlag: @unchecked Sendable {
    var open = true
}
