import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

enum TravelMode: String, CaseIterable, Identifiable {
    case walk, run, cycle, drive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    var icon: String {
        switch self {
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Base meters per second before natural variation.
    var baseSpeed: CLLocationSpeed {
        switch self {
        case .walk: return 1.4
        case .run: return 3.3
        case .cycle: return 6.5
        case .drive: return 13.4
        }
    }

    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .run: return .walking
        case .cycle, .drive: return .automobile
        }
    }
}

enum SpoofStatus: Equatable {
    case idle
    case connecting
    case active
    case reconnecting
    case dropped(String)

    var label: String {
        switch self {
        case .idle: return "Not Spoofing"
        case .connecting: return "Starting…"
        case .active: return "Spoofing"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Interrupted"
        }
    }

    var isDropped: Bool {
        if case .dropped = self { return true }
        return false
    }
}

/// What the error alert offers besides OK.
enum ErrorAction {
    case openLocalDevVPN
    case openSettings
    case openCellularConnect
}

@MainActor
final class SpoofSession: ObservableObject {
    @Published var status: SpoofStatus = .idle
    @Published var pin: CLLocationCoordinate2D?
    @Published var simulated: CLLocationCoordinate2D?
    @Published var travelMode: TravelMode = .walk
    @Published var mapStyleIndex: Int = 0
    @Published var lastError: String?
    @Published var lastErrorAction: ErrorAction?
    @Published var isBusy = false
    @Published var joystickActive = false
    /// Tunnel open (spoofing or not). Mobile-data mode shows this as "ready".
    @Published private(set) var tunnelReady = false
    @Published var showCellularConnect = false

    @Published var favorites: [SavedPlace] = []
    @Published var recents: [SavedPlace] = []

    private var resendTimer: Timer?
    private var healthTimer: Timer?
    private var idleProbeTimer: Timer?
    private var joystickTimer: Timer?
    private var routeTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var joystickVector: CGVector = .zero
    private let locationKeeper = BackgroundKeepAlive()

    /// One engine call at a time; joystick/route steps that arrive meanwhile keep only the newest.
    private var engineBusy = false
    private var pending: (coordinate: CLLocationCoordinate2D, markRecent: Bool, userInitiated: Bool)?
    /// Bumped by Stop and Disconnect so answers that arrive afterwards are ignored.
    private var generation = 0
    private var dropNotified = false
    private var retryDelay: TimeInterval = 12
    private var nextRetry = Date.distantFuture
    /// Stop couldn't reach the device; finish it as soon as the connection is back.
    private var stopPending = false
    private var askedForNotifications = false

    private let favoritesKey = "locus.favorites"
    private let recentsKey = "locus.recents"
    private static let dropNotificationID = "mocus.drop"

    init() {
        favorites = SavedPlace.load(key: favoritesKey)
        recents = SavedPlace.load(key: recentsKey)
    }

    var isSpoofing: Bool {
        if case .active = status { return true }
        if case .reconnecting = status { return true }
        return false
    }

    /// Runs blocking engine work off the main thread; the engine serialises calls itself.
    private nonisolated static func engine<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: - User actions

    func teleport(to coordinate: CLLocationCoordinate2D, pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = String(localized: "Import an RPPairing file in Settings first.", bundle: .appLanguage)
            lastErrorAction = .openSettings
            return
        }
        askForNotificationsOnce()
        stopPending = false
        pin = coordinate
        apply(coordinate, pairing: pairing, markRecent: true, userInitiated: true)
    }

    /// Mobile-data mode: open the tunnel while data is on, without moving the GPS.
    func connectTunnel(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = String(localized: "Import an RPPairing file in Settings first.", bundle: .appLanguage)
            lastErrorAction = .openSettings
            return
        }
        guard !isBusy else { return }
        askForNotificationsOnce()
        guard LocalDevVPN.isConnected else {
            show(LocationEngineError(.vpnOff))
            return
        }
        isBusy = true
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        let gen = generation
        Task {
            let result = await Self.engine { LocationEngine.connect(pairingPath: path, deviceIP: ip) }
            isBusy = false
            guard gen == generation else { return }
            switch result {
            case .success:
                tunnelReady = true
                lastError = nil
                lastErrorAction = nil
                // Stay alive while the user leaves to turn data off.
                beginBackground()
                locationKeeper.start()
                if stopPending {
                    finishPendingStop(pairing: pairing)
                } else if let sim = simulated {
                    // Reconnecting after a drop puts the last spoof back.
                    apply(sim, pairing: pairing, markRecent: false, userInitiated: true)
                } else {
                    startIdleProbe(pairing: pairing)
                }
            case .failure(let error):
                tunnelReady = false
                show(error)
            }
        }
    }

    /// Clears any spoof and closes the tunnel; the next teleport needs a network again.
    func disconnectTunnel(pairing: PairingStore) {
        generation += 1
        pending = nil
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        stopHealth()
        stopIdleProbe()
        let hadSpoof = simulated != nil
        isBusy = true
        Task {
            var restored = true
            if hadSpoof, case .failure = await Self.engine({ LocationEngine.clear() }) {
                restored = false
            }
            await Self.engine { LocationEngine.disconnect() }
            isBusy = false
            simulated = nil
            status = .idle
            tunnelReady = false
            dropNotified = false
            stopPending = false
            endBackground()
            clearDropNotification()
            if !restored {
                lastError = String(localized: "Couldn't turn the simulated location off before disconnecting. Restart the iPhone to get your real location back.", bundle: .appLanguage)
                lastErrorAction = nil
            }
        }
    }

    func stop(pairing: PairingStore) {
        generation += 1
        pending = nil
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        let keep = ConnectionMode.current == .cellular
        // While dropped, Stop may reopen the tunnel (if the VPN is up) just to turn the spoof off.
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        let reopen = status.isDropped && LocalDevVPN.isConnected
        isBusy = true
        engineBusy = true
        let gen = generation
        Task {
            let result = await Self.engine {
                reopen
                    ? LocationEngine.clear(keepSession: keep, reopenWith: path, deviceIP: ip)
                    : LocationEngine.clear(keepSession: keep)
            }
            isBusy = false
            engineBusy = false
            guard gen == generation else { return }
            switch result {
            case .success:
                didStop(pairing: pairing)
            case .failure(let error):
                // The device may still report the fake spot: keep it on screen and finish later.
                stopPending = true
                tunnelReady = LocationEngine.isSessionActive
                handleDrop(error, pairing: pairing)
                lastError = String(localized: "Couldn't reach the iPhone to turn the simulated location off. Mocus turns it off as soon as the connection is back, or restart the iPhone.", bundle: .appLanguage)
                lastErrorAction = ConnectionMode.current == .cellular ? .openCellularConnect : .openLocalDevVPN
            }
        }
    }

    /// Re-shows why the connection dropped (the status bar keeps it short).
    func showDropDetails() {
        guard case .dropped(let reason) = status else { return }
        lastError = reason
        lastErrorAction = ConnectionMode.current == .cellular ? .openCellularConnect : .openLocalDevVPN
    }

    /// Back in the foreground: confirm the connection is what the screen says.
    func appBecameActive(pairing: PairingStore) {
        if status == .active {
            heartbeat(pairing: pairing)
        } else if tunnelReady, simulated == nil {
            probeIdle()
        }
    }

    /// Best-known real device coordinate (not the teleport pin).
    var realCoordinate: CLLocationCoordinate2D? {
        locationKeeper.lastKnownCoordinate
    }

    /// Start lightweight GPS updates for the map puck / locate button.
    func startLocationUpdates() {
        locationKeeper.start()
    }

    func startJoystick(pairing: PairingStore) {
        guard pairing.hasPairingFile else {
            lastError = String(localized: "Import an RPPairing file in Settings first.", bundle: .appLanguage)
            lastErrorAction = .openSettings
            return
        }
        let start = simulated ?? pin ?? locationKeeper.lastKnownCoordinate
        guard let start else {
            lastError = String(localized: "Drop a pin or teleport somewhere before using the joystick.", bundle: .appLanguage)
            lastErrorAction = nil
            return
        }
        if simulated == nil {
            askForNotificationsOnce()
            apply(start, pairing: pairing, markRecent: false, userInitiated: true)
        }
        joystickActive = true
        joystickTimer?.invalidate()
        joystickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickJoystick(pairing: pairing)
            }
        }
    }

    func updateJoystick(vector: CGVector) {
        joystickVector = vector
    }

    func stopJoystick() {
        joystickActive = false
        joystickVector = .zero
        joystickTimer?.invalidate()
        joystickTimer = nil
    }

    func followRoute(_ coordinates: [CLLocationCoordinate2D], pairing: PairingStore) {
        guard pairing.hasPairingFile, coordinates.count >= 2 else { return }
        routeTask?.cancel()
        stopJoystick()
        askForNotificationsOnce()
        let mode = travelMode
        routeTask = Task { [weak self] in
            guard let self else { return }
            var previous = coordinates[0]
            await MainActor.run {
                self.apply(previous, pairing: pairing, markRecent: true, userInitiated: true)
            }
            for next in coordinates.dropFirst() {
                if Task.isCancelled { break }
                let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
                var speed = mode.baseSpeed * Double.random(in: 0.88...1.12)
                speed = max(0.8, speed)
                let stepMeters: CLLocationDistance = min(12, max(4, speed * 0.5))
                let steps = max(1, Int(ceil(distance / stepMeters)))
                for i in 1...steps {
                    if Task.isCancelled { break }
                    let t = Double(i) / Double(steps)
                    let coord = CLLocationCoordinate2D(
                        latitude: previous.latitude + (next.latitude - previous.latitude) * t,
                        longitude: previous.longitude + (next.longitude - previous.longitude) * t
                    )
                    let delay = stepMeters / speed
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await MainActor.run {
                        self.apply(coord, pairing: pairing, markRecent: false, userInitiated: false)
                    }
                }
                previous = next
            }
        }
    }

    // MARK: - Places

    func addFavorite(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        // Don't let a generic star overwrite a named favorite for the same spot.
        if let existing = favorites.first(where: { $0.id == place.id }),
           Self.isGenericFavoriteName(place.name),
           !Self.isGenericFavoriteName(existing.name) {
            return
        }
        favorites.removeAll { $0.id == place.id }
        favorites.insert(place, at: 0)
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func renameFavorite(_ place: SavedPlace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = favorites.firstIndex(where: { $0.id == place.id }) else { return }
        favorites[index].name = trimmed
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeFavorite(_ place: SavedPlace) {
        favorites.removeAll { $0.id == place.id }
        SavedPlace.save(favorites, key: favoritesKey)
    }

    func removeRecent(_ place: SavedPlace) {
        recents.removeAll { $0.id == place.id }
        SavedPlace.save(recents, key: recentsKey)
    }

    /// Best display name for starring the current pin (search title, matching recent, etc.).
    func suggestedFavoriteName(for coordinate: CLLocationCoordinate2D, fallback: String? = nil) -> String {
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let favorite = favorites.first(where: { $0.id == SavedPlace(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude).id }),
           !Self.isGenericFavoriteName(favorite.name) {
            return favorite.name
        }
        if let recent = recents.first(where: {
            abs($0.latitude - coordinate.latitude) < 0.00015 && abs($0.longitude - coordinate.longitude) < 0.00015
        }), !Self.isGenericFavoriteName(recent.name) {
            return recent.name
        }
        return Self.coordinateLabel(coordinate)
    }

    private static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func isGenericFavoriteName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Favorite" { return true }
        // Coordinate-looking labels from older teleports.
        let parts = trimmed.split(separator: ",")
        if parts.count == 2,
           Double(parts[0].trimmingCharacters(in: .whitespaces)) != nil,
           Double(parts[1].trimmingCharacters(in: .whitespaces)) != nil {
            return true
        }
        return false
    }

    // MARK: - Engine calls

    private func apply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool, userInitiated: Bool) {
        if engineBusy {
            // Joystick and route steps come faster than the device answers; only the newest matters.
            pending = (coordinate, markRecent || (pending?.markRecent ?? false), userInitiated || (pending?.userInitiated ?? false))
            return
        }
        if status == .idle {
            status = .connecting
        } else if status.isDropped {
            status = .reconnecting
        }
        engineBusy = true
        isBusy = true
        let gen = generation
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        // Without LocalDevVPN there's no route to the device; don't spend the timeout dialing.
        let vpnUp = LocalDevVPN.isConnected
        Task {
            let result = await Self.engine {
                LocationEngine.set(latitude: lat, longitude: lon, pairingPath: path, deviceIP: ip, canOpen: vpnUp)
            }
            engineBusy = false
            isBusy = false
            guard gen == generation else {
                pending = nil
                return
            }
            switch result {
            case .success:
                didApply(coordinate, pairing: pairing, markRecent: markRecent)
            case .failure(let error):
                applyFailed(vpnUp ? error : LocationEngineError(.vpnOff), pairing: pairing, userInitiated: userInitiated)
            }
            drainPending(pairing: pairing)
        }
    }

    private func drainPending(pairing: PairingStore) {
        guard let next = pending else { return }
        pending = nil
        if status == .active || next.userInitiated {
            apply(next.coordinate, pairing: pairing, markRecent: next.markRecent, userInitiated: next.userInitiated)
        }
    }

    private func didApply(_ coordinate: CLLocationCoordinate2D, pairing: PairingStore, markRecent: Bool) {
        simulated = coordinate
        pin = coordinate
        status = .active
        tunnelReady = true
        lastError = nil
        lastErrorAction = nil
        dropNotified = false
        retryDelay = 12
        clearDropNotification()
        stopIdleProbe()
        beginBackground()
        locationKeeper.start()
        startResend(pairing: pairing)
        startHealth(pairing: pairing)
        if markRecent {
            pushRecent(coordinate)
        }
    }

    private func applyFailed(_ error: LocationEngineError, pairing: PairingStore, userInitiated: Bool) {
        tunnelReady = LocationEngine.isSessionActive
        if simulated != nil {
            handleDrop(error, pairing: pairing)
            if userInitiated { show(error) }
        } else {
            status = .idle
            show(error)
        }
    }

    /// The one place a lost connection is handled: stop moving, tell the user once, retry with backoff.
    private func handleDrop(_ error: LocationEngineError, pairing: PairingStore) {
        status = .dropped(error.summary)
        routeTask?.cancel()
        routeTask = nil
        stopJoystick()
        stopResend()
        startHealth(pairing: pairing)
        if !dropNotified {
            dropNotified = true
            retryDelay = 12
            nextRetry = Date().addingTimeInterval(retryDelay)
            postDropNotification(error.summary)
        }
    }

    private func show(_ error: LocationEngineError) {
        lastError = error.localizedDescription
        if error.needsPairing {
            lastErrorAction = .openSettings
        } else if [.vpnOff, .tunnelUnreachable].contains(error.kind) {
            lastErrorAction = ConnectionMode.current == .cellular ? .openCellularConnect : .openLocalDevVPN
        } else {
            lastErrorAction = nil
        }
    }

    private func didStop(pairing: PairingStore) {
        simulated = nil
        status = .idle
        stopPending = false
        dropNotified = false
        stopHealth()
        clearDropNotification()
        tunnelReady = LocationEngine.isSessionActive
        if tunnelReady {
            startIdleProbe(pairing: pairing)
        } else {
            endBackground()
        }
        // Keep location updates running so the map puck / locate button
        // can return to the real GPS fix (not the leftover pin).
        locationKeeper.start()
    }

    private func finishPendingStop(pairing: PairingStore) {
        guard !engineBusy else { return }
        engineBusy = true
        let keep = ConnectionMode.current == .cellular
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        let gen = generation
        Task {
            let result = await Self.engine { LocationEngine.clear(keepSession: keep, reopenWith: path, deviceIP: ip) }
            engineBusy = false
            guard gen == generation else { return }
            if case .success = result {
                didStop(pairing: pairing)
            }
        }
    }

    private func tickJoystick(pairing: PairingStore) {
        guard joystickActive, status == .active, let current = simulated else { return }
        let magnitude = hypot(joystickVector.dx, joystickVector.dy)
        guard magnitude > 0.08 else { return }
        let nx = joystickVector.dx / magnitude
        let ny = -joystickVector.dy / magnitude
        let speed = travelMode.baseSpeed * min(1.0, magnitude) * Double.random(in: 0.9...1.1)
        let dt = 0.25
        let meters = speed * dt
        let next = offset(coordinate: current, eastMeters: nx * meters, northMeters: ny * meters)
        apply(next, pairing: pairing, markRecent: false, userInitiated: false)
    }

    /// Keeps locationd fed while spoofing. Never dials: a dead session is a drop, handled once.
    private func startResend(pairing: PairingStore) {
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.heartbeat(pairing: pairing)
            }
        }
    }

    private func heartbeat(pairing: PairingStore) {
        guard status == .active, let sim = simulated, !engineBusy else { return }
        engineBusy = true
        let gen = generation
        let lat = sim.latitude
        let lon = sim.longitude
        let path = pairing.pairingPath
        let ip = TunnelConfig.targetIP
        Task {
            let result = await Self.engine {
                LocationEngine.set(latitude: lat, longitude: lon, pairingPath: path, deviceIP: ip, canOpen: false)
            }
            engineBusy = false
            guard gen == generation else { return }
            if case .failure(let error) = result {
                tunnelReady = false
                handleDrop(error, pairing: pairing)
            }
            drainPending(pairing: pairing)
        }
    }

    private func stopResend() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    /// While dropped: retry on a growing delay (12 s → 2 min), and only when LocalDevVPN is up.
    /// Retries are silent; the drop was announced once.
    private func startHealth(pairing: PairingStore) {
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.healthTick(pairing: pairing)
            }
        }
    }

    private func healthTick(pairing: PairingStore) {
        guard status.isDropped, simulated != nil, !engineBusy, Date() >= nextRetry else { return }
        retryDelay = min(retryDelay * 2, 120)
        nextRetry = Date().addingTimeInterval(retryDelay)
        guard LocalDevVPN.isConnected else { return }
        if stopPending {
            finishPendingStop(pairing: pairing)
        } else if let sim = simulated {
            apply(sim, pairing: pairing, markRecent: false, userInitiated: false)
        }
    }

    private func stopHealth() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    /// Mobile-data mode's "ready" must stay true: check an idle tunnel every 30 s.
    private func startIdleProbe(pairing: PairingStore) {
        idleProbeTimer?.invalidate()
        idleProbeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.probeIdle()
            }
        }
    }

    private func probeIdle() {
        guard tunnelReady, simulated == nil, !engineBusy else { return }
        engineBusy = true
        let gen = generation
        Task {
            let alive = await Self.engine { LocationEngine.probe() }
            engineBusy = false
            guard gen == generation, simulated == nil else { return }
            if !alive {
                tunnelReady = false
                stopIdleProbe()
                endBackground()
            }
        }
    }

    private func stopIdleProbe() {
        idleProbeTimer?.invalidate()
        idleProbeTimer = nil
    }

    private func pushRecent(_ coordinate: CLLocationCoordinate2D) {
        pushNamedRecent(
            name: Self.coordinateLabel(coordinate),
            coordinate: coordinate
        )
    }

    func pushNamedRecent(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(
            name: trimmed.isEmpty ? Self.coordinateLabel(coordinate) : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        recents.removeAll {
            abs($0.latitude - place.latitude) < 0.00015 && abs($0.longitude - place.longitude) < 0.00015
        }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        SavedPlace.save(recents, key: recentsKey)
    }

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Notifications

    /// Ask while the user is in the app; asking at the moment of a drop can't show a prompt.
    private func askForNotificationsOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A fixed identifier, so a later drop replaces the banner instead of stacking another.
    private func postDropNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Mocus spoof dropped", bundle: .appLanguage)
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.dropNotificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func clearDropNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.dropNotificationID])
    }

    private func offset(coordinate: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let earth = 6378137.0
        let dLat = northMeters / earth * (180 / .pi)
        let dLon = eastMeters / (earth * cos(coordinate.latitude * .pi / 180)) * (180 / .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat, longitude: coordinate.longitude + dLon)
    }
}
