import Darwin

struct LocalNetwork {
    static func contains(host: String, networks: [(address: UInt32, mask: UInt32)]) -> Bool {
        var target = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &target) }) == 1 else { return false }
        let address = UInt32(bigEndian: target.s_addr)
        return networks.contains { $0.mask != 0 && (address & $0.mask) == ($0.address & $0.mask) }
    }

    static func contains(host: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var networks: [(address: UInt32, mask: UInt32)] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            networks.append((ip, netmask))
        }
        return contains(host: host, networks: networks)
    }
}
