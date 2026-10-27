import Foundation

enum DiscoveryTestSupport {
    static func scan(port: UInt16, duration: Duration = .milliseconds(350)) async throws -> [DiscoveredCamera] {
        let interface = DiscoveryInterface(address: "127.0.0.1", netmask: "255.0.0.0")!
        let socket = try DiscoverySocket(interface: interface, destination: "127.0.0.1", port: port)
        return try await CameraDiscovery.scan(sockets: [socket], interfaces: [interface], duration: duration)
    }
}
