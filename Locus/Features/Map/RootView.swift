import CoreLocation
import SwiftUI
import NetworkExtension

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showPlaces = false

    var body: some View {
        // Bottom chrome is a sibling overlay aligned to the bottom — no full-screen
        // Spacer layer that can steal / pass map taps through the tray.
        ZStack(alignment: .bottom) {
            MapHomeView(onShowPlaces: { showPlaces = true })

            BottomControlsView(
                showSettings: $showSettings,
                showPlaces: $showPlaces
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView()
        }
        .sheet(isPresented: $session.showCellularConnect) {
            CellularConnectView()
                .environmentObject(session)
                .environmentObject(pairing)
        }
        .alert("Mocus", isPresented: Binding(
            get: { session.lastError != nil },
            set: { if !$0 { session.lastError = nil } }
        )) {
            // Every error that has a fix offers it, so nobody is left with only "OK".
            switch session.lastErrorAction {
            case .some(.openLocalDevVPN):
                Button("Open LocalDevVPN") { dismissError(); LocalDevVPN.openOrInstall() }
            case .some(.openSettings):
                Button("Settings") { dismissError(); showSettings = true }
            case .some(.openCellularConnect):
                Button("Connect with mobile data") { dismissError(); session.showCellularConnect = true }
            case .none:
                EmptyView()
            }
            Button("OK", role: .cancel) { dismissError() }
        } message: {
            Text(session.lastError ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.appBecameActive(pairing: pairing) }
        }
    }

    private func dismissError() {
        session.lastError = nil
        session.lastErrorAction = nil
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ConnectionMode.defaultsKey) private var connectionMode: ConnectionMode = .wifi

    @State private var tunnelConnected = LocalDevVPN.isConnected

    private enum Display {
        case notSpoofing
        case connectVPN
        case connectCellular
        case cellularReady
        case status(String)
    }

    private var display: Display {
        switch session.status {
        case .idle:
            if connectionMode == .cellular {
                return session.tunnelReady ? .cellularReady : .connectCellular
            }
            return tunnelConnected ? .notSpoofing : .connectVPN
        case .connecting:
            return .status(String(localized: "Connecting…", bundle: .appLanguage))
        case .active:
            return .status(String(localized: "Spoofing", bundle: .appLanguage))
        case .reconnecting:
            return .status(String(localized: "Reconnecting…", bundle: .appLanguage))
        case .dropped:
            // The full reason is one tap away (alert); a one-line pill stays readable.
            return .status(String(localized: "Disconnected", bundle: .appLanguage))
        }
    }

    private var color: Color {
        switch display {
        case .notSpoofing:
            return Color.primary.opacity(0.55)
        case .connectVPN, .connectCellular:
            return LocusTheme.statusWarn
        case .cellularReady:
            return LocusTheme.statusGood
        case .status:
            switch session.status {
            case .active: return LocusTheme.statusGood
            case .connecting, .reconnecting: return LocusTheme.statusWarn
            case .dropped: return LocusTheme.statusBad
            case .idle: return Color.primary.opacity(0.55)
            }
        }
    }

    private var title: String {
        switch display {
        case .notSpoofing: return String(localized: "Not Spoofing", bundle: .appLanguage)
        case .connectVPN: return String(localized: "Connect LocalDevVPN", bundle: .appLanguage)
        case .connectCellular: return String(localized: "Connect with mobile data", bundle: .appLanguage)
        case .cellularReady: return String(localized: "Connected — ready to teleport", bundle: .appLanguage)
        case .status(let text): return text
        }
    }

    var body: some View {
        Group {
            if connectionMode == .cellular {
                // Any state opens the checklist: connect, reconnect after a drop, or disconnect.
                Button {
                    session.showCellularConnect = true
                } label: {
                    statusContent
                }
                .buttonStyle(.plain)
            } else if case .connectVPN = display {
                Button(action: LocalDevVPN.openOrInstall) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else if session.status.isDropped {
                Button(action: session.showDropDetails) {
                    statusContent
                }
                .buttonStyle(.plain)
            } else {
                statusContent
            }
        }
        .onAppear { refreshTunnel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshTunnel() }
        }
        .onChange(of: session.status) { _, _ in
            refreshTunnel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            // LocalDevVPN connection changes show up here even though we don’t own the VPN.
            refreshTunnel()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshTunnel()
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            if case .connectVPN = display {
                Image(systemName: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            } else if case .active = session.status, let sim = session.simulated {
                Text(String(format: "%.4f, %.4f", sim.latitude, sim.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if connectionMode == .cellular {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .locusGlass(.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func refreshTunnel() {
        tunnelConnected = LocalDevVPN.isConnected
    }
}

struct BottomControlsView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Binding var showSettings: Bool
    @Binding var showPlaces: Bool

    private let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    /// The user dropped or picked a new spot while already spoofing somewhere else.
    private var pinDiffersFromSpoof: Bool {
        guard let pin = session.pin, let sim = session.simulated else { return false }
        return CLLocation(latitude: pin.latitude, longitude: pin.longitude)
            .distance(from: CLLocation(latitude: sim.latitude, longitude: sim.longitude)) > 3
    }

    var body: some View {
        VStack(spacing: 12) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases) { mode in
                    let selected = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(selected ? .black : .primary)
                            .frame(width: 44, height: 40)
                            .background(
                                Capsule().fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                trayIcon("gearshape.fill", label: "Settings") { showSettings = true }
                trayIcon("star.fill", label: "Places") { showPlaces = true }

                Button {
                    if session.joystickActive {
                        session.stopJoystick()
                    } else {
                        session.startJoystick(pairing: pairing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                        // With both Stop and Teleport showing there's no room for the label.
                        if !pinDiffersFromSpoof {
                            Text(session.joystickActive ? "On" : "Joy")
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.joystickActive ? .black : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(session.joystickActive ? LocusTheme.accentSecondary : Color.primary.opacity(0.08))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Movement joystick")

                if session.simulated != nil && !pinDiffersFromSpoof {
                    Button {
                        session.stop(pairing: pairing)
                    } label: {
                        Text("Stop")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 72)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(Capsule().fill(LocusTheme.danger))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    if session.simulated != nil {
                        // A new pin while spoofing: keep Stop reachable next to Teleport.
                        Button {
                            session.stop(pairing: pairing)
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(LocusTheme.danger))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop")
                    }
                    Button {
                        guard let pin = session.pin else {
                            session.lastError = String(localized: "Tap the map to drop a pin first.", bundle: .appLanguage)
                            session.lastErrorAction = nil
                            return
                        }
                        session.teleport(to: pin, pairing: pairing)
                    } label: {
                        Text("Teleport")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(minWidth: 96)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(LocusTheme.accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isBusy)
                }
            }
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        // Whole tray absorbs taps so near-misses don't fall through to the map.
        .contentShape(trayShape)
    }

    private func trayIcon(_ systemName: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
    }
}
