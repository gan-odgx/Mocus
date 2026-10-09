import SwiftUI

/// Mobile-data mode checklist: Wi‑Fi off → data on → LocalDevVPN → Connect → data off → teleport.
/// The tunnel opened while data is on keeps working after data goes off.
struct CellularConnectView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var network = NetworkStatus()
    @State private var vpnConnected = LocalDevVPN.isConnected
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled

    private var connected: Bool { session.tunnelReady }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Use Mocus without Wi‑Fi. Connect once while mobile data is on, then turn data off and teleport as usual.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    checklist
                    statusCard
                    actions
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Mobile data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { refreshVPN() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshVPN() }
        }
        .task {
            // LocalDevVPN state has no callback we own; poll while the sheet is up.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshVPN()
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            checkRow(1, "Turn Wi‑Fi off", done: !network.wifiOn,
                     hint: network.wifiOn ? "Wi‑Fi is on — the normal Wi‑Fi mode works too." : nil)
            checkRow(2, "Turn mobile data on", done: network.cellularOn || connected)
            checkRow(3, "Connect LocalDevVPN", done: vpnConnected)
            checkRow(4, "Tap Connect", done: connected)
            checkRow(5, "Turn mobile data off", done: connected && !network.cellularOn,
                     hint: connected && network.cellularOn ? "Control Center → tap the mobile data icon." : nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func checkRow(_ n: Int, _ title: LocalizedStringKey, done: Bool, hint: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? LocusTheme.statusGood : Color.white.opacity(0.12))
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                } else {
                    Text("\(n)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(done ? .regular : .semibold))
                    .foregroundStyle(done ? .secondary : .primary)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(LocusTheme.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 10) {
            if !connected {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusWarn)
                Text("Not connected yet")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Mobile data and LocalDevVPN must be on while you connect.")
            } else if network.cellularOn {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.statusGood)
                Text("Connected")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Pick your destinations now and star them (★): the map and search need data. Then turn mobile data off in Control Center.")
            } else {
                Image(systemName: "location.north.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(LocusTheme.accent)
                Text("Ready to teleport")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Open saved places (★) and tap one to teleport. The map may stay blank without data. Stop keeps the connection, so you can teleport again without data.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(22)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if connected {
                primaryButton("Done") { dismiss() }

                Button(role: .destructive) {
                    session.disconnectTunnel(pairing: pairing)
                } label: {
                    Text("Disconnect")
                        .font(.headline)
                        .foregroundStyle(LocusTheme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .locusGlass(.interactive, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Text("If the connection drops, turn data on briefly and tap Connect again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    session.connectTunnel(pairing: pairing)
                } label: {
                    Group {
                        if session.isBusy {
                            ProgressView().tint(.black)
                        } else {
                            Text("Connect")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(LocusTheme.accent))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.isBusy)

                if !vpnConnected {
                    Button {
                        if localDevVPNInstalled {
                            LocalDevVPN.openInstalled()
                        } else {
                            LocalDevVPN.openAppStore()
                        }
                    } label: {
                        Label(
                            localDevVPNInstalled ? "Open LocalDevVPN" : "Get LocalDevVPN",
                            systemImage: localDevVPNInstalled ? "lock.shield.fill" : "arrow.down.app.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .locusGlass(.interactive, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(LocusTheme.accent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func refreshVPN() {
        vpnConnected = LocalDevVPN.isConnected
        localDevVPNInstalled = LocalDevVPN.isInstalled
    }
}
