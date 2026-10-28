import AppKit
import Foundation
import UserNotifications

/// Like IDM's clipboard monitor: when a download or video link is copied anywhere,
/// a notification asks whether MDM should download it.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    /// File types the browser extensions capture by default.
    static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz", "zst", "dmg", "pkg", "iso", "img", "exe", "msi", "apk",
        "deb", "rpm", "appimage", "bin", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "mp4", "m4v", "mkv", "avi",
        "mov", "wmv", "flv", "webm", "mpg", "mpeg", "pdf", "epub", "djvu", "torrent", "psd", "ai",
    ]

    private var count = 0
    private var offered: [String: Date] = [:]
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        count = NSPasteboard.general.changeCount // whatever was copied before MDM opened is ignored
        loop()
    }

    private func loop() {
        check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loop() }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != count else { return }
        count = pb.changeCount
        guard UserDefaults.standard.object(forKey: "clipboardWatch") as? Bool ?? true,
              let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count < 4000, !s.contains("\n"), Self.isDownloadable(s) else { return }
        offered = offered.filter { $0.value.timeIntervalSinceNow > -600 }
        let known = AppModel.shared.downloads.contains { $0.url == s || $0.originalURL == s }
        guard offered[s] == nil, !known else { return }
        offered[s] = Date()
        NotificationHandler.offer(s)
    }

    /// A magnet link, a link to a file, or a page with a single video yt-dlp can fetch.
    static func isDownloadable(_ s: String) -> Bool {
        if s.lowercased().hasPrefix("magnet:?") { return true }
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host?.lowercased() else { return false }
        if fileExtensions.contains(u.pathExtension.lowercased()) { return true }
        let p = u.path.lowercased()
        func on(_ site: String) -> Bool { host == site || host.hasSuffix("." + site) }
        if on("youtube.com") { return p == "/watch" || p.hasPrefix("/shorts/") || p == "/playlist" }
        if host == "youtu.be" { return p.count > 1 }
        if on("vimeo.com") { return p.range(of: #"^/\d+"#, options: .regularExpression) != nil }
        if on("x.com") || on("twitter.com") { return p.contains("/status/") }
        if on("instagram.com") { return p.hasPrefix("/reel") || p.hasPrefix("/p/") }
        if on("tiktok.com") { return p.contains("/video/") }
        return false
    }
}

/// Handles the "İndir" button on the clipboard notification.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    static let clipCategory = "MDM_CLIP"
    static let doneCategory = "MDM_DONE"
    static let failedCategory = "MDM_FAILED"

    static func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let download = UNNotificationAction(identifier: "download", title: "İndir", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: clipCategory, actions: [download], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: doneCategory, actions: [
                UNNotificationAction(identifier: "open", title: "Aç", options: []),
                UNNotificationAction(identifier: "reveal", title: "Finder'da göster", options: []),
            ], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: failedCategory, actions: [
                UNNotificationAction(identifier: "retry", title: "Tekrar dene", options: []),
            ], intentIdentifiers: [], options: []),
        ])
    }

    static func offer(_ url: String) {
        let c = UNMutableNotificationContent()
        c.title = "Kopyaladığın link indirilsin mi?"
        c.body = url
        c.categoryIdentifier = clipCategory
        c.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clip-" + UUID().uuidString, content: c, trigger: nil))
    }

    // Other notifications stay hidden while MDM is in front, as before; the clipboard question always shows.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == Self.clipCategory ? [.banner] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let url = content.userInfo["url"] as? String
        let downloadID = (content.userInfo["id"] as? String).flatMap { UUID(uuidString: $0) }
        completionHandler()
        if let downloadID {
            Task { @MainActor in AppModel.shared.handleNotificationAction(action, downloadID: downloadID) }
            return
        }
        guard content.categoryIdentifier == Self.clipCategory, let url,
              action == "download" || action == UNNotificationDefaultActionIdentifier else { return }
        Task { @MainActor in AppModel.shared.addFromUserInput(url) }
    }
}
