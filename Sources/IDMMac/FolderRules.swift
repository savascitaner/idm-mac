import Foundation

/// Optionally files downloads into sub-folders of the download folder by type (Video, Müzik, Arşivler, ...).
enum FolderRules {
    static let key = "folderRulesOn"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    private static let groups: [(String, Set<String>)] = [
        ("Video", ["mp4", "m4v", "mkv", "avi", "mov", "wmv", "flv", "webm", "mpg", "mpeg", "ts"]),
        ("Müzik", ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]),
        ("Arşivler", ["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz"]),
        ("Uygulamalar", ["dmg", "pkg", "iso", "img", "exe", "msi", "apk", "deb", "rpm", "appimage"]),
        ("Belgeler", ["pdf", "epub", "djvu", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt"]),
    ]

    static func subfolder(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return groups.first { $0.1.contains(ext) }?.0
    }

    /// The folder a download is saved to. Only the default download folder is sorted; a folder picked by hand stays as chosen.
    static func directory(base: String, fileName: String) -> String {
        guard enabled, let sub = subfolder(for: fileName),
              base == UserDefaults.standard.string(forKey: "downloadDirectory") else { return base }
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(sub, isDirectory: true).path
    }
}
