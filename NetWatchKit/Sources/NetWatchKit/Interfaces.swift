import Foundation
import Darwin

struct InterfaceAddress {
    let name: String
    let family: String
    let address: String
    let up: Bool
    let running: Bool
}

/// Raw interface addresses via getifaddrs. en0 is Wi-Fi on iPad.
enum Interfaces {
    static func addresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            let len = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }

            let flags = Int32(ifa.ifa_flags)
            result.append(InterfaceAddress(
                name: String(cString: ifa.ifa_name),
                family: family == UInt8(AF_INET) ? "ipv4" : "ipv6",
                address: String(cString: host),
                up: flags & IFF_UP != 0,
                running: flags & IFF_RUNNING != 0))
        }
        return result
    }

    /// Skips loopback and Apple-internal interfaces (AWDL, VPN tunnels, etc.).
    static func isInteresting(_ name: String) -> Bool {
        let noise = ["lo", "utun", "ipsec", "llw", "awdl", "anpi", "ap", "gif", "stf", "XHC"]
        return !noise.contains { name.hasPrefix($0) }
    }

    static func summary() -> [String] {
        addresses()
            .filter { isInteresting($0.name) && !$0.address.hasPrefix("fe80") }
            .map { "\($0.name) \($0.family) \($0.address)\($0.running ? "" : " (not running)")" }
    }

    static func wifiIPv4() -> String? {
        addresses().first { $0.name == "en0" && $0.family == "ipv4" }?.address
    }
}
