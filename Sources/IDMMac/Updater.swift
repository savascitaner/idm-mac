import AppKit
import Foundation

/// Checks the "latest" GitHub release (rebuilt on every push to main) and installs it in place:
/// the new MDM.app is copied over this one after MDM quits, then opened again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "savascitaner/idm-mac"

    /// Short commit of a newer build, when there is one.
    @Published private(set) var available: String?
    @Published private(set) var status = ""
    @Published private(set) var installing = false
    private var dmgURL: URL?
    private var notified: String?
    private var started = false

    /// The commit this build was made from (filled in by package.sh).
    static var currentCommit: String { Bundle.main.object(forInfoDictionaryKey: "MDMCommit") as? String ?? "" }
    static var isReleaseBuild: Bool { currentCommit.count >= 7 && currentCommit != "dev" && !currentCommit.hasPrefix("__") }

    func start() {
        guard !started else { return }
        started = true
        loop()
    }

    private func loop() {
        if UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true { check() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 3600) { [weak self] in self?.loop() }
    }

    func check() {
        guard Self.isReleaseBuild else {
            status = "Bu bir geliştirici derlemesi; güncelleme denetlenmiyor"
            return
        }
        guard !installing else { return }
        status = "Denetleniyor…"
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/tags/latest")!,
                                     timeoutInterval: 30)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sha = json["target_commitish"] as? String, sha.count >= 7 else {
                    throw TorrentService.Failure(errorDescription: "sürüm bilgisi okunamadı")
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let dmg = assets.first { $0["name"] as? String == "MDM.dmg" }?["browser_download_url"] as? String
                let mine = Self.currentCommit
                if sha.hasPrefix(mine) || mine.hasPrefix(sha) {
                    self.available = nil
                    self.status = "Güncel (\(mine.prefix(7)))"
                    return
                }
                self.available = String(sha.prefix(7))
                self.dmgURL = dmg.flatMap { URL(string: $0) }
                self.status = "Yeni sürüm var (\(sha.prefix(7)))"
                if self.notified != sha {
                    self.notified = sha
                    AppModel.shared.notifyUser("MDM için yeni sürüm var", "Ayarlar'dan ya da ana penceredeki düğmeyle kurabilirsin.")
                }
            } catch {
                self.status = "Denetlenemedi: \(error.localizedDescription)"
            }
        }
    }

    /// Downloads the DMG, copies MDM.app out of it, and swaps it in once MDM has quit.
    func install() {
        guard let dmgURL, !installing else { return }
        installing = true
        status = "Yeni sürüm indiriliyor…"
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
                    NSWorkspace.shared.open(dmg)
                    self.installing = false
                    self.status = "MDM bu klasörde kendini güncelleyemiyor; açılan pencereden MDM'yi Uygulamalar'a sürükle"
                    return
                }
                self.status = "Kuruluyor…"
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
                self.status = "Güncellenemedi: \(error.localizedDescription)"
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
