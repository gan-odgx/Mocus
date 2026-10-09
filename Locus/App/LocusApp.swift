import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var session = SpoofSession()
    @StateObject private var pairing = PairingStore()
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .mn

    init() {
        // Before any UI loads, so the bundle and system prompts pick the right .lproj.
        AppLanguage.apply(AppLanguage.current)
    }

    /// Map when setup finished, or when already paired outside this walkthrough.
    private var showMap: Bool {
        setupComplete || (pairing.hasPairingFile && !SetupGate.isInProgress)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView()
                } else {
                    SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile)) {
                        SetupGate.markComplete()
                        setupComplete = true
                    }
                }
            }
            .environmentObject(session)
            .environmentObject(pairing)
            .environment(\.locale, Locale(identifier: language.rawValue))
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                handleIncoming(url)
            }
            .confirmationDialog(
                "Replace the pairing file?",
                isPresented: Binding(
                    get: { pairing.pendingReplacement != nil },
                    set: { if !$0 { pairing.cancelReplacement() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Replace", role: .destructive) {
                    do {
                        try pairing.confirmReplacement()
                    } catch {
                        session.lastError = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) { pairing.cancelReplacement() }
            } message: {
                Text("This replaces the pairing file Mocus uses now. On iOS 18–26 you need a computer to make a new one.")
            }
            .onAppear {
                if !setupComplete, pairing.hasPairingFile, !SetupGate.isInProgress {
                    SetupGate.markComplete()
                    setupComplete = true
                }
            }
        }
    }

    private func handleIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(ext) {
            do {
                try pairing.importPairing(from: url)
            } catch {
                // Opened from AirDrop / Files: say why it didn't take instead of failing silently.
                session.lastError = error.localizedDescription
            }
        } else if ext == "gpx" {
            NotificationCenter.default.post(name: .locusImportGPX, object: url)
        }
    }
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
}
