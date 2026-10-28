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
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in NetworkWatcher.shared.set(pathUp: up) }
        }
        monitor.start(queue: DispatchQueue(label: "mdm.network"))
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NetworkWatcher.shared.set(sleeping: true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NetworkWatcher.shared.set(sleeping: false) }
        }
    }

    private func set(pathUp: Bool) {
        self.pathUp = pathUp
        update()
    }

    private func set(sleeping: Bool) {
        self.sleeping = sleeping
        update()
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
