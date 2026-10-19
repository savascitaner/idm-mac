import Foundation

/// The download speed cap. "Yavaş mod" (in the menu bar) swaps in its own, lower cap.
enum SpeedLimit {
    /// Bytes per second, 0 = no limit. Safe to read from any thread.
    static var bytesPerSecond: Int {
        let d = UserDefaults.standard
        let kb = d.bool(forKey: "slowMode") ? (d.object(forKey: "slowModeKB") as? Int ?? 256) : d.integer(forKey: "speedLimitKB")
        return max(0, kb) * 1024
    }
}

/// One token bucket shared by every file download, so the cap covers MDM as a whole
/// rather than each download or connection.
final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()

    private let lock = NSLock()
    private var rate: Double = 0
    private var tokens: Double = 0
    private var last = Date()

    func set(_ bytesPerSecond: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard Double(bytesPerSecond) != rate else { return }
        rate = Double(bytesPerSecond)
        tokens = 0
        last = Date()
    }

    /// Takes `n` received bytes from the budget; returns how long the connection should stop
    /// reading so the average stays under the cap (0 = keep going).
    func take(_ n: Int) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard rate > 0 else { return 0 }
        let now = Date()
        // At most one second of unused budget is saved up, so bursts stay short.
        tokens = min(rate, tokens + now.timeIntervalSince(last) * rate)
        last = now
        tokens -= Double(n)
        return tokens < 0 ? -tokens / rate : 0
    }
}
