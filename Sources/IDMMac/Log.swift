import Foundation
import os

/// Diagnostic log: goes to the unified log and to a small file that Settings can show in Finder,
/// so a problem seen on a Mac can be looked at afterwards.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.savascitaner.idmmac", category: "app")
    private static let queue = DispatchQueue(label: "mdm.log", qos: .utility)
    static var file: URL { Paths.support.appendingPathComponent("mdm.log") }

    static func window(_ message: String) { write("window", message) }
    static func download(_ message: String) { write("download", message) }
    static func update(_ message: String) { write("update", message) }

    static func write(_ category: String, _ message: String) {
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        let now = Date()
        queue.async {
            let line = "\(ISO8601DateFormatter().string(from: now)) [\(category)] \(message)\n"
            let fm = FileManager.default
            let url = file
            // Keep the file small: one older copy is enough for diagnosis.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                let old = url.appendingPathExtension("old")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
