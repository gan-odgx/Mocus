import Darwin
import Foundation
import UIKit

enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to Locus via `locus://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=locus")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// Whether LocalDevVPN's tunnel interface is up. Only a hint for the UI: connecting never waits on it.
    /// LocalDevVPN 1.3+ gives the utun `10.7.1.1` and routes the device at `10.7.0.1`; older builds used
    /// `10.7.0.x` for both. So accept any utun address in the target's /16 (or the target itself).
    static var isConnected: Bool {
        let interfaces = ipv4InterfaceAddresses()
        let target = TunnelConfig.targetIP
        if interfaces.contains(where: { $0.address == target }) { return true }

        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.prefix(2).joined(separator: ".") + "."
        return interfaces.contains { $0.name.hasPrefix("utun") && $0.address.hasPrefix(prefix) }
    }

    static func openInstalled() {
        UIApplication.shared.open(enableURL)
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// Open LocalDevVPN to connect if installed; otherwise App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }

    private static func ipv4InterfaceAddresses() -> [(name: String, address: String)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [(name: String, address: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            // Some interfaces (e.g. a VPN mid-teardown) have no address; this is polled every second or two.
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(
                    addr,
                    nameLen,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    results.append((name: String(cString: interface.ifa_name), address: String(cString: host)))
                }
            }
            ptr = interface.ifa_next
        }
        return results
    }
}
