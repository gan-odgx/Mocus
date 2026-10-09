import Network
import SwiftUI

/// Live Wi‑Fi / mobile-data state for the mobile-data connect checklist.
/// Hints only: iOS doesn't expose the Control Center toggles themselves.
@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var wifiOn = false
    @Published private(set) var cellularOn = false

    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private let cellular = NWPathMonitor(requiredInterfaceType: .cellular)

    init() {
        let queue = DispatchQueue(label: "locus.network-status")
        wifi.pathUpdateHandler = { [weak self] path in
            let on = path.status == .satisfied
            Task { @MainActor [weak self] in self?.wifiOn = on }
        }
        cellular.pathUpdateHandler = { [weak self] path in
            let on = path.status == .satisfied
            Task { @MainActor [weak self] in self?.cellularOn = on }
        }
        wifi.start(queue: queue)
        cellular.start(queue: queue)
    }

    deinit {
        wifi.cancel()
        cellular.cancel()
    }
}
