import Darwin
import Foundation

/// Unix-domain socket the native messaging host connects to. Messages are JSON, one per line.
/// Only the current user can connect (the socket file is 0600 inside ~/Library/Application Support).
final class IPCServer {
    typealias Reply = ([String: Any]) -> Void
    private let path: String
    private let onMessage: ([String: Any], @escaping Reply) -> Void
    private var listenFD: Int32 = -1
    private let clientsLock = NSLock()
    private var clients: [Int32: Reply] = [:]

    /// How many browser hosts are connected (a host only runs while its Chrome extension is alive).
    var clientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    /// Sends a message to every connected browser host. Returns false if none is connected.
    @discardableResult
    func broadcast(_ obj: [String: Any]) -> Bool {
        clientsLock.lock()
        let all = Array(clients.values)
        clientsLock.unlock()
        all.forEach { $0(obj) }
        return !all.isEmpty
    }

    init(path: String, onMessage: @escaping ([String: Any], @escaping Reply) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
            guard bytes.count < buf.count else { return false }
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
            return true
        }
        guard fits else { NSLog("IDMMac: socket path too long"); return }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard r == 0 else { NSLog("IDMMac: bind failed \(errno)"); return }
        chmod(path, 0o600)
        listen(listenFD, 8)

        let fd = listenFD
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                self?.serve(client)
            }
        }.start()
    }

    private func serve(_ fd: Int32) {
        let lock = NSLock()
        let reply: Reply = { obj in
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            lock.lock()
            defer { lock.unlock() }
            data.withUnsafeBytes { raw in
                var p = raw.baseAddress!
                var left = raw.count
                while left > 0 {
                    let n = write(fd, p, left)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    left -= n
                    p += n
                }
            }
        }
        clientsLock.lock()
        clients[fd] = reply
        clientsLock.unlock()
        Thread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                        self?.onMessage(obj, reply)
                    }
                }
            }
            if let self {
                self.clientsLock.lock()
                self.clients[fd] = nil
                self.clientsLock.unlock()
            }
            close(fd)
        }.start()
    }
}

/// Registers the native messaging host with every Chromium-based browser that is installed.
enum HostInstaller {
    static let hostName = "com.savascitaner.idmmac"
    static let extensionID = "pmbpnoekfadmikgamnhkbmohcjkbllie"
    /// The ID before the extension was packed as a CRX; kept so a copy loaded by hand still works.
    static let legacyExtensionIDs = ["mnanilgkappdlfepnjifibfalbblnbcc"]

    static let browserDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
        "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    @discardableResult
    static func install() -> [String] {
        let fm = FileManager.default
        guard let hostExe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("IDMMacHost"),
              fm.isExecutableFile(atPath: hostExe.path) else { return [] }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "MDM native messaging host",
            "path": hostExe.path,
            "type": "stdio",
            "allowed_origins": ([extensionID] + legacyExtensionIDs).map { "chrome-extension://\($0)/" },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return [] }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var installed: [String] = []
        for dir in browserDirs {
            let browser = base.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try? fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            if (try? data.write(to: hosts.appendingPathComponent("\(hostName).json"))) != nil {
                installed.append(dir)
            }
        }
        return installed
    }

    /// Offers the bundled, signed extension (mdm-extension.crx) to every installed Chromium browser through its
    /// "External Extensions" folder. The browser finds it on its next start and asks before turning it on,
    /// so nothing has to be loaded by hand. Returns the browsers that were given the offer.
    @discardableResult
    static func offerExtension() -> [String] {
        let fm = FileManager.default
        guard let crx = Bundle.main.resourceURL?.appendingPathComponent("mdm-extension.crx"), fm.fileExists(atPath: crx.path),
              let manifest = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension/manifest.json"),
              let m = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest))) as? [String: Any],
              let version = m["version"] as? String else { return [] }
        // The browser reads the file from a path that survives app updates and moves.
        let stable = Paths.support.appendingPathComponent("mdm-extension.crx")
        try? fm.removeItem(at: stable)
        guard (try? fm.copyItem(at: crx, to: stable)) != nil,
              let json = try? JSONSerialization.data(withJSONObject: ["external_crx": stable.path, "external_version": version],
                                                     options: [.prettyPrinted, .withoutEscapingSlashes]) else { return [] }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var offered: [String] = []
        for dir in browserDirs {
            let browser = base.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: browser.path) else { continue }
            let external = browser.appendingPathComponent("External Extensions", isDirectory: true)
            try? fm.createDirectory(at: external, withIntermediateDirectories: true)
            if (try? json.write(to: external.appendingPathComponent("\(extensionID).json"))) != nil { offered.append(dir) }
        }
        return offered
    }

    /// Copies the bundled extension to a stable folder that Chrome can load ("Load unpacked").
    static func exportExtension() -> URL? {
        let fm = FileManager.default
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true),
              fm.fileExists(atPath: src.path) else { return nil }
        let dst = Paths.extensionDir
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
            return dst
        } catch {
            return nil
        }
    }
}
