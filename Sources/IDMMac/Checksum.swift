import AppKit
import CryptoKit
import Foundation

/// SHA-256 of a finished download, computed in the background.
enum Checksum {
    static func sha256(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A 64-character hex string on the clipboard is taken as the checksum the download page published.
    static func expectedFromClipboard() -> String? {
        let s = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.count == 64 && s.allSatisfy({ $0.isHexDigit }) ? s : nil
    }
}

extension AppModel {
    /// Hashes the file, copies the result, and says whether it matches a checksum that was on the clipboard.
    func verifyChecksum(_ rec: DownloadRecord) {
        guard let path = rec.finalPath, FileManager.default.fileExists(atPath: path) else {
            notifyUser("SHA-256", "Dosya bulunamadı.")
            return
        }
        let expected = Checksum.expectedFromClipboard()
        let name = rec.fileName
        notifyUser("SHA-256 hesaplanıyor", name)
        DispatchQueue.global(qos: .utility).async {
            let sum = Checksum.sha256(path: path)
            Task { @MainActor in
                guard let sum else {
                    AppModel.shared.notifyUser("SHA-256", "\(name) okunamadı.")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sum, forType: .string)
                if let expected {
                    AppModel.shared.notifyUser(expected == sum ? "Sağlama toplamı eşleşti ✓" : "Sağlama toplamı EŞLEŞMEDİ ✗",
                                               expected == sum ? name : "\(name): dosya bozuk ya da farklı olabilir.")
                } else {
                    AppModel.shared.notifyUser("SHA-256 panoya kopyalandı", name)
                }
            }
        }
    }
}
