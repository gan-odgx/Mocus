import Foundation

enum TunnelConfig {
    /// LocalDevVPN / SideStore-style loopback tunnel endpoint.
    static let defaultIP = "10.7.0.1"
    static let defaultsKey = "locus.targetDeviceIP"

    static var targetIP: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultIP }
        return stored
    }

    static func setTargetIP(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }
}

/// How the first connection to the developer tunnel is made.
enum ConnectionMode: String, CaseIterable, Identifiable {
    /// Original flow: start the first teleport on Wi‑Fi.
    case wifi
    /// No Wi‑Fi: open the tunnel while mobile data is on, then turn data off.
    /// The open session keeps working, and Stop keeps it open.
    case cellular

    static let defaultsKey = "locus.connectionMode"

    var id: String { rawValue }

    static var current: ConnectionMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ConnectionMode.init(rawValue:)) ?? .wifi
    }
}
