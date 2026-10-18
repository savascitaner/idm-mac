// Chrome Native Messaging host.
// Chrome launches this process and talks to it over stdin/stdout (4-byte length + JSON).
// The host forwards each message as one JSON line to the app's Unix socket and relays
// the app's replies back to Chrome. If the app is not running, it is launched on demand.

import Darwin
import Foundation

setvbuf(stdout, nil, _IOFBF, 0)

let socketPath: String = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("IDMMac/ipc.sock").path
}()

/// The .app bundle this host lives in (…/IDM Mac.app/Contents/MacOS/IDMMacHost).
let appBundlePath: String = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()

let outLock = NSLock()

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = Darwin.write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            left -= n
            p += n
        }
        return true
    }
}

func readExactly(_ fd: Int32, _ count: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        got += n
    }
    return Data(buf)
}

/// Sends one message to Chrome.
func sendToChrome(_ json: Data) {
    outLock.lock()
    defer { outLock.unlock() }
    var len = UInt32(json.count).littleEndian
    let header = Data(bytes: &len, count: 4)
    _ = writeAll(STDOUT_FILENO, header + json)
}

func sendToChrome(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj) { sendToChrome(data) }
}

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
        guard bytes.count < buf.count else { return false }
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
        return true
    }
    guard fits else { close(fd); return nil }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

func launchApp() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if appBundlePath.hasSuffix(".app") {
        p.arguments = ["-g", appBundlePath]
    } else {
        p.arguments = ["-g", "-b", "com.savascitaner.idmmac"]
    }
    try? p.run()
    p.waitUntilExit()
}

var appFD: Int32? = nil

/// Connects to the app, launching it if needed. Waits up to ~15 s for it to start listening.
func ensureApp() -> Int32? {
    if let fd = appFD { return fd }
    if let fd = connectSocket() { appFD = fd; startReader(fd); return fd }
    launchApp()
    for _ in 0..<60 {
        usleep(250_000)
        if let fd = connectSocket() { appFD = fd; startReader(fd); return fd }
    }
    return nil
}

/// Relays newline-delimited JSON from the app back to Chrome.
func startReader(_ fd: Int32) {
    let t = Thread {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { sendToChrome(Data(line)) }
            }
        }
        // App went away: let Chrome reconnect later.
        exit(0)
    }
    t.start()
}

while true {
    guard let header = readExactly(STDIN_FILENO, 4) else { exit(0) }
    let len = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    guard len > 0, len < 64 * 1024 * 1024, let body = readExactly(STDIN_FILENO, Int(len)) else { exit(0) }

    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let id = obj["id"] as? String ?? ""

    if obj["type"] as? String == "ping" {
        // Answered here so that a status check does not launch the app.
        let running = appFD != nil || {
            if let fd = connectSocket() { appFD = fd; startReader(fd); return true }
            return false
        }()
        sendToChrome(["type": "pong", "id": id, "app": running])
        continue
    }

    guard let fd = ensureApp() else {
        sendToChrome(["type": "error", "id": id, "message": "app-unavailable"])
        continue
    }
    var line = body
    line.append(0x0A)
    if !writeAll(fd, line) {
        sendToChrome(["type": "error", "id": id, "message": "app-write-failed"])
        exit(0)
    }
}
