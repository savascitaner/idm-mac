import AppKit
import Network

/// Tells the model when the Mac goes offline or to sleep and when it is back, so downloads wait and
/// continue by themselves instead of failing.
@MainActor
final class NetworkWatcher {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private var pathUp = true
    private var sleeping = false
    private var started = false
    private var pendingUp: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                self?.pathUp = up
                self?.update()
            }
        }
        monitor.start(queue: DispatchQueue(label: "mdm.network"))
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.update()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.update()
            }
        }
    }

    /// Going away is acted on at once; coming back waits a few seconds so Wi-Fi can settle.
    private func update() {
        pendingUp?.cancel()
        if !(pathUp && !sleeping) {
            AppModel.shared.setNetwork(up: false)
            return
        }
        let item = DispatchWorkItem { Task { @MainActor in AppModel.shared.setNetwork(up: true) } }
        pendingUp = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }
}
