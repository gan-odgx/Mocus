import Foundation
import idevice
import UniformTypeIdentifiers
import UIKit

@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var hasPairingFile = false
    @Published var lastError: String?

    static let fileName = "rp_pairing_file.plist"
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [
            .item,          // anything — sideloaded plists often lack a proper UTI
            .data,
            .propertyList,
            .xml,
        ]
        for ext in ["plist", "mobiledevicepairing", "mobiledevicepair"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        if let custom = UTType("com.chrismack.locus.rppairing") {
            types.append(custom)
        }
        return types
    }()

    private var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    var pairingURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    var pairingPath: String { pairingURL.path }

    init() {
        refresh()
    }

    func refresh() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        hasPairingFile = FileManager.default.fileExists(atPath: pairingURL.path)
    }

    /// Validated pairing data waiting for the user to confirm it may replace the current file.
    @Published private(set) var pendingReplacement: Data?

    func importPairing(from sourceURL: URL) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: sourceURL)
        try stage(data)
    }

    /// LiveContainer / broken pickers: copy the plist text (or file) then paste here.
    func importPairingFromClipboard() throws {
        let board = UIPasteboard.general

        if let url = board.url ?? board.urls?.first {
            if url.isFileURL {
                try importPairing(from: url)
                return
            }
        }

        let candidates: [Data?] = [
            board.data(forPasteboardType: "com.apple.property-list"),
            board.data(forPasteboardType: UTType.propertyList.identifier),
            board.data(forPasteboardType: UTType.xml.identifier),
            board.data(forPasteboardType: UTType.data.identifier),
            board.string?.data(using: .utf8),
        ]

        guard let data = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw PairingImportError.emptyClipboard
        }
        try stage(data)
        // The pairing record is a credential for this iPhone; don't leave it on the clipboard.
        board.items = []
    }

    func confirmReplacement() throws {
        guard let data = pendingReplacement else { return }
        pendingReplacement = nil
        try install(data)
    }

    func cancelReplacement() {
        pendingReplacement = nil
    }

    func removePairing() throws {
        if FileManager.default.fileExists(atPath: pairingURL.path) {
            try FileManager.default.removeItem(at: pairingURL)
        }
        hasPairingFile = false
    }

    /// Validates first, so a wrong file never touches a working one; replacing asks first.
    private func stage(_ data: Data) throws {
        try validate(data)
        if hasPairingFile {
            pendingReplacement = data
        } else {
            try install(data)
        }
    }

    /// A plist isn't enough: idevice itself must be able to read it as an RPPairing record.
    private func validate(_ data: Data) throws {
        guard looksLikePairingPlist(data) else {
            throw PairingImportError.invalidContents
        }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("rp-check-\(UUID().uuidString).plist")
        try data.write(to: probe, options: .atomic)
        defer { try? FileManager.default.removeItem(at: probe) }
        var handle: OpaquePointer?
        if let error = probe.path.withCString({ rp_pairing_file_read($0, &handle) }) {
            idevice_error_free(error)
            throw PairingImportError.invalidContents
        }
        guard let handle else { throw PairingImportError.invalidContents }
        rp_pairing_file_free(handle)
    }

    /// Writes next to the old file, then swaps it in, so a failed write can't leave no file at all.
    private func install(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let incoming = directoryURL.appendingPathComponent("incoming-\(UUID().uuidString).plist")
        try data.write(to: incoming, options: .atomic)
        if FileManager.default.fileExists(atPath: pairingURL.path) {
            _ = try FileManager.default.replaceItemAt(pairingURL, withItemAt: incoming)
        } else {
            try FileManager.default.moveItem(at: incoming, to: pairingURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURL.path)
        // Device-specific credential: keep it out of iCloud/computer backups.
        var url = pairingURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        hasPairingFile = true
        lastError = nil
    }

    private func looksLikePairingPlist(_ data: Data) -> Bool {
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return obj is [AnyHashable: Any] || obj is [Any]
        }
        // XML plist often starts with these markers when copied as text.
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.hasPrefix("<?xml") || text.hasPrefix("bplist") || text.contains("<plist")
    }
}

enum PairingImportError: LocalizedError {
    case emptyClipboard
    case invalidContents

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            return String(localized: "Clipboard is empty. Copy your RPPairing plist text (or the file), then try Paste again.", bundle: .appLanguage)
        case .invalidContents:
            return String(localized: "That doesn’t look like an RPPairing plist. Copy the full pairing file contents and try again.", bundle: .appLanguage)
        }
    }
}
