import AppKit
import Foundation

/// Checks the "latest" GitHub release (rebuilt on every push to main) and installs it in place:
/// the new MDM.app is copied over this one after MDM quits, then opened again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    /// Repository whose "latest" release holds the built MDM.pkg / MDM.dmg (must be public for the updater).
    static let repo = "savascitaner/idm-mac"

    /// Short commit of a newer build, when there is one.
    @Published private(set) var available: String?
    @Published private(set) var status = ""
    @Published private(set) var installing = false
    private var dmgURL: URL?
    private var notified: String?
    private var started = false
    private var autoPending = false
    private var autoBlocked = false

    /// Install new versions by itself when no download is running (Settings can switch this off).
    static var autoInstall: Bool { UserDefaults.standard.object(forKey: "autoInstallUpdate") as? Bool ?? true }

    /// The commit this build was made from (filled in by package.sh).
    static var currentCommit: String { Bundle.main.object(forInfoDictionaryKey: "MDMCommit") as? String ?? "" }
    static var isReleaseBuild: Bool { currentCommit.count >= 7 && currentCommit != "dev" && !currentCommit.hasPrefix("__") }

    func start() {
        guard !started else { return }
        started = true
        announceUpdateDone()
        loop()
    }

    /// After a self-update the new copy tells once that it is the new version.
    private func announceUpdateDone() {
        let key = "lastRunCommit"
        let mine = Self.currentCommit
        guard Self.isReleaseBuild else { return }
        let previous = UserDefaults.standard.string(forKey: key) ?? ""
        UserDefaults.standard.set(mine, forKey: key)
        if !previous.isEmpty, previous != mine {
            Log.update("updated from \(previous.prefix(7)) to \(mine.prefix(7))")
            AppModel.shared.notifyUser("MDM güncellendi", L("Yeni sürüme geçildi (%@)", String(mine.prefix(7))))
        }
    }

    private func loop() {
        if UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true { check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * 3600) { [weak self] in self?.loop() }
    }

    func check() {
        Task { await performCheck() }
    }

    /// "MDM'yi güncelle…" menu item: checks now and answers in a dialog either way.
    func checkWithAnswer() {
        Task {
            await performCheck()
            let alert = NSAlert()
            if let available {
                alert.messageText = L("Yeni sürüm var (%@)", available)
                alert.informativeText = L("Şimdi kurulsun mu? MDM kapanıp yeniden açılır; sürmekte olan indirmeler kaldığı yerden devam eder.")
                alert.addButton(withTitle: L("Güncelle ve yeniden aç"))
                alert.addButton(withTitle: L("Sonra"))
                MainWindow.present(alert) { [weak self] answer in
                    if answer == .alertFirstButtonReturn { self?.install() }
                }
            } else if status.hasPrefix(L("Güncel")) {
                alert.messageText = L("MDM güncel")
                alert.informativeText = L("Uygulamanız en son sürümde (%@).", String(Self.currentCommit.prefix(7)))
                MainWindow.present(alert) { _ in }
            } else {
                alert.messageText = L("Güncelleme denetlenemedi")
                alert.informativeText = status
                MainWindow.present(alert) { _ in }
            }
        }
    }

    /// The build's commit: a "commit: <sha>" line in the release notes, else the release's target.
    private static func commit(in release: [String: Any]) -> String? {
        if let body = release["body"] as? String,
           let r = body.range(of: #"commit: ([0-9a-f]{7,40})"#, options: .regularExpression) {
            return String(body[r].dropFirst("commit: ".count))
        }
        return release["target_commitish"] as? String
    }

    private func performCheck() async {
        guard Self.isReleaseBuild else {
            status = L("Bu bir geliştirici derlemesi; güncelleme denetlenmiyor")
            return
        }
        guard !installing else { return }
        status = L("Denetleniyor…")
        // The release is deleted and recreated while a build publishes, so a missing one gets a second try.
        var lastCode = 0
        for attempt in 0..<3 {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/tags/latest")!,
                                     timeoutInterval: 30)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: req)
                lastCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard lastCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sha = Self.commit(in: json), sha.count >= 7 else {
                    if attempt < 2 { try await Task.sleep(nanoseconds: 8_000_000_000) }
                    continue
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first { $0["name"] as? String == "MDM.dmg" }?["browser_download_url"] as? String
                let mine = Self.currentCommit
                if sha.hasPrefix(mine) || mine.hasPrefix(sha) {
                    available = nil
                    status = L("Güncel") + " (\(mine.prefix(7)))"
                    return
                }
                available = String(sha.prefix(7))
                dmgURL = dmg.flatMap { URL(string: $0) }
                status = L("Yeni sürüm var (%@)", String(sha.prefix(7)))
                if notified != sha {
                    notified = sha
                    Log.update("new version \(sha.prefix(7)) found (running \(mine.prefix(7)))")
                    if !Self.autoInstall {
                        AppModel.shared.notifyUser("MDM için yeni sürüm var", "Ayarlar'dan ya da ana penceredeki düğmeyle kurabilirsin.")
                    }
                }
                scheduleAutoInstall()
                return
            } catch {
                status = L("Denetlenemedi: %@", error.localizedDescription)
                return
            }
        }
        status = lastCode == 404 || lastCode == 200
            ? "Sürüm bilgisi şu an alınamıyor (yeni sürüm yayınlanıyor olabilir); birkaç dakika sonra tekrar dene"
            : "Sürüm bilgisi okunamadı (GitHub yanıtı \(lastCode))"
    }

    /// Installs a found update on its own, but only while no download is running; otherwise it asks again later.
    private func scheduleAutoInstall() {
        guard Self.autoInstall, available != nil, !installing, !autoPending, !autoBlocked else { return }
        autoPending = true
        attemptAutoInstall()
    }

    private func attemptAutoInstall() {
        guard Self.autoInstall, available != nil, !installing, !autoBlocked else { autoPending = false; return }
        if AppModel.shared.downloads.contains(where: { $0.isActive }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.attemptAutoInstall() }
            return
        }
        autoPending = false
        Log.update("installing \(available ?? "") automatically")
        install(auto: true)
    }

    /// Downloads the DMG, copies MDM.app out of it, and swaps it in once MDM has quit.
    func install(auto: Bool = false) {
        guard let dmgURL, !installing else { return }
        installing = true
        status = L("Yeni sürüm indiriliyor…")
        Task {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("mdm-update-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let (tmp, _) = try await URLSession.shared.download(from: dmgURL)
                let dmg = work.appendingPathComponent("MDM.dmg")
                try fm.moveItem(at: tmp, to: dmg)
                let dest = Bundle.main.bundlePath
                let parent = (dest as NSString).deletingLastPathComponent
                guard !dest.contains("/AppTranslocation/"), !dest.hasPrefix("/Volumes/"), fm.isWritableFile(atPath: parent) else {
                    // MDM runs from somewhere it can't replace itself (the DMG, a read-only folder): open the DMG instead.
                    // An automatic attempt only notes it, so a window does not pop up every few hours.
                    if auto { self.autoBlocked = true } else { NSWorkspace.shared.open(dmg) }
                    self.installing = false
                    self.status = L("MDM bu klasörde kendini güncelleyemiyor; açılan pencereden MDM'yi Uygulamalar'a sürükle")
                    return
                }
                self.status = L("Kuruluyor…")
                let mount = work.appendingPathComponent("mnt", isDirectory: true)
                let newApp = work.appendingPathComponent("MDM.app", isDirectory: true)
                try await Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                        "-mountpoint", mount.path])
                var copyError: Error?
                do {
                    try await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("MDM.app").path, newApp.path])
                } catch {
                    copyError = error
                }
                try? await Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                if let copyError { throw copyError }
                guard fm.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/IDMMac").path) else {
                    throw TorrentService.Failure(errorDescription: "DMG içinde MDM bulunamadı")
                }
                try self.relaunch(newApp: newApp, dest: dest, work: work)
            } catch {
                try? fm.removeItem(at: work)
                self.installing = false
                Log.update("update failed: \(error.localizedDescription)")
                self.status = L("Güncellenemedi: %@", error.localizedDescription)
            }
        }
    }

    /// A small script waits for MDM to quit, swaps the bundles (putting the old one back if the copy fails)
    /// and opens the new MDM.
    private func relaunch(newApp: URL, dest: String, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && /usr/bin/ditto "$1" "$2"; then
          rm -rf "$2.old"
        else
          rm -rf "$2"; mv "$2.old" "$2"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
        /usr/bin/open "$2"
        rm -rf "$3"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, newApp.path, dest, work.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let name = (tool as NSString).lastPathComponent
                    cont.resume(throwing: TorrentService.Failure(errorDescription: "\(name) hata verdi (\(p.terminationStatus))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
