import Foundation

@main struct LocalNetworkTest {
    static func main() {
        let networks: [(address: UInt32, mask: UInt32)] = [(0xc0a80001, 0xffffff00)]
        precondition(LocalNetwork.contains(host: "192.168.0.116", networks: networks))
        precondition(!LocalNetwork.contains(host: "192.168.1.116", networks: networks))
        precondition(!LocalNetwork.contains(host: "", networks: networks))
        precondition(!LocalNetwork.contains(host: "camera.example", networks: networks))
        precondition(!LocalNetwork.contains(host: "127.0.0.1", networks: networks))
        print("PASS: camera IP is checked against local subnet")
    }
}
