import Foundation
import idevice

struct LocationEngineError: LocalizedError {
    enum Kind {
        case invalidIP
        case pairingRead
        /// LocalDevVPN isn't connected, so there's no route to the device.
        case vpnOff
        /// The tunnel couldn't be reached (network, VPN, or the device's service is down).
        case tunnelUnreachable
        /// The device answered but refused the pairing record (often after an iOS update).
        case pairingRejected
        case remoteServer
        case simulationCreate
        case locationSet
        case locationClear
        /// No open session, and the caller didn't allow opening one.
        case notActive
    }

    let kind: Kind
    /// idevice's own message, shown in small print so a failure can be diagnosed.
    let detail: String?

    init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    /// One-line cause for the status bar and notifications.
    var summary: String {
        switch kind {
        case .invalidIP: return String(localized: "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1).", bundle: .appLanguage)
        case .pairingRead: return String(localized: "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode.", bundle: .appLanguage)
        case .vpnOff: return String(localized: "LocalDevVPN is off. Turn it on, then try again.", bundle: .appLanguage)
        case .tunnelUnreachable:
            if ConnectionMode.current == .cellular {
                return String(localized: "Could not open the developer tunnel. Turn mobile data on, check LocalDevVPN is connected, then tap Connect again.", bundle: .appLanguage)
            }
            return String(localized: "Could not open the developer tunnel. Is LocalDevVPN connected on Wi‑Fi?", bundle: .appLanguage)
        case .pairingRejected: return String(localized: "This iPhone rejected the pairing file. It may be out of date after an iOS update: pair again in Settings.", bundle: .appLanguage)
        case .remoteServer: return String(localized: "Connected to the tunnel but RemoteXPC handshake failed.", bundle: .appLanguage)
        case .simulationCreate: return String(localized: "Could not open Apple’s location simulation service.", bundle: .appLanguage)
        case .locationSet: return String(localized: "Failed to set simulated coordinates.", bundle: .appLanguage)
        case .locationClear: return String(localized: "Failed to clear simulated location.", bundle: .appLanguage)
        case .notActive: return String(localized: "No active simulation session.", bundle: .appLanguage)
        }
    }

    var errorDescription: String? {
        guard let detail, !detail.isEmpty else { return summary }
        return "\(summary)\n\n(\(detail))"
    }

    var needsPairing: Bool { kind == .pairingRead || kind == .pairingRejected }
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
/// Every call blocks on a serial queue, so call it off the main thread.
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.chrismack.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?
    /// Message of the last idevice error, attached to the next returned error.
    private static var lastMessage: String?

    /// A dead tunnel used to hang until the library's default timeout; 5 s is plenty on loopback.
    private static let configured: Void = idevice_set_global_timeout(5)

    static var isSessionActive: Bool { locationSimulation != nil }

    /// `canOpen: false` only reuses an open session (heartbeats) and never dials the tunnel.
    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String, canOpen: Bool = true) -> Result<Void, LocationEngineError> {
        run { setLocked(latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP, canOpen: canOpen) }
    }

    /// Opens the tunnel and location service without moving the GPS. An existing session is
    /// probed first, so a dead one is replaced instead of reported as ready.
    static func connect(pairingPath: String, deviceIP: String) -> Result<Void, LocationEngineError> {
        run {
            if locationSimulation != nil, probeLocked() { return nil }
            return openLocked(pairingPath: pairingPath, deviceIP: deviceIP)
        }
    }

    /// Checks an idle session is still alive. Clears the simulated fix, so only call it while not spoofing.
    static func probe() -> Bool {
        var alive = false
        queue.sync {
            _ = configured
            alive = probeLocked()
        }
        return alive
    }

    /// `keepSession` leaves the tunnel open so the next teleport needs no network. With a pairing
    /// path, a lost session is reopened first, so a pending Stop can finish after a drop.
    static func clear(keepSession: Bool = false, reopenWith pairingPath: String? = nil, deviceIP: String? = nil) -> Result<Void, LocationEngineError> {
        run {
            if locationSimulation == nil, let pairingPath, let deviceIP {
                if let failure = openLocked(pairingPath: pairingPath, deviceIP: deviceIP) { return failure }
            }
            return clearLocked(keepSession: keepSession)
        }
    }

    static func disconnect() {
        queue.sync { cleanup() }
    }

    // MARK: - Locked (engine queue)

    private static func run(_ work: () -> LocationEngineError.Kind?) -> Result<Void, LocationEngineError> {
        var result: Result<Void, LocationEngineError> = .success(())
        queue.sync {
            _ = configured
            lastMessage = nil
            if let kind = work() {
                result = .failure(LocationEngineError(kind, detail: lastMessage))
            }
        }
        return result
    }

    /// Records idevice's message, then frees the error.
    private static func take(_ error: UnsafeMutablePointer<IdeviceFfiError>) {
        if let message = error.pointee.message {
            lastMessage = String(cString: message)
        }
        idevice_error_free(error)
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String, canOpen: Bool) -> LocationEngineError.Kind? {
        var sessionFailure: LocationEngineError.Kind?
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                take(err)
                cleanup()
                sessionFailure = .locationSet
            } else {
                return nil
            }
        }
        guard canOpen else { return sessionFailure ?? .notActive }

        if let failure = openLocked(pairingPath: pairingPath, deviceIP: deviceIP) { return failure }

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            take(setError)
            cleanup()
            return .locationSet
        }
        return nil
    }

    private static func probeLocked() -> Bool {
        guard let locationSimulation else { return false }
        if let err = location_simulation_clear(locationSimulation) {
            take(err)
            cleanup()
            return false
        }
        return true
    }

    /// Tunnel → RemoteXPC → location simulation service. Leaves `locationSimulation` set on success.
    private static func openLocked(pairingPath: String, deviceIP: String) -> LocationEngineError.Kind? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(49152).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return .invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            take(pairingError)
            return .pairingRead
        }
        guard let pairingHandle else { return .pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            take(providerError)
            cleanup()
            return classifyTunnelFailure(lastMessage)
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            take(remoteServerError)
            cleanup()
            return .remoteServer
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            take(simError)
            cleanup()
            return .simulationCreate
        }
        // location_simulation_new consumes/owns remote server lifecycle alongside handle
        remoteServer = nil
        return nil
    }

    private static func clearLocked(keepSession: Bool) -> LocationEngineError.Kind? {
        guard let locationSimulation else { return .locationClear }
        let err = location_simulation_clear(locationSimulation)
        if let err {
            take(err)
            cleanup()
            return .locationClear
        }
        if !keepSession { cleanup() }
        return nil
    }

    /// Network failures read as "unreachable"; a refused pair-verify means the pairing file is stale.
    private static func classifyTunnelFailure(_ message: String?) -> LocationEngineError.Kind {
        let m = (message ?? "").lowercased()
        let network = ["connect", "refused", "timed out", "timeout", "unreachable", "no route", "network", "broken pipe", "reset", "eof"]
        if network.contains(where: { m.contains($0) }) { return .tunnelUnreachable }
        let pairing = ["pair", "verify", "srp", "auth", "decrypt", "signature", "key"]
        if pairing.contains(where: { m.contains($0) }) { return .pairingRejected }
        return .tunnelUnreachable
    }
}
