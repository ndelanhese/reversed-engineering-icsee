import Foundation

@main enum CameraDiscoveryTest {
    enum Failure: Error { case failed(String) }
    static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw Failure.failed(label) }
    }
    static func reply(_ address: String = "http://192.168.4.8:8080/onvif/device_service", relatesTo: String = "urn:uuid:test") -> Data {
        Data("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><s:Header><a:RelatesTo>\(relatesTo)</a:RelatesTo></s:Header><s:Body><d:ProbeMatches><d:ProbeMatch><a:EndpointReference><a:Address>urn:uuid:camera1</a:Address></a:EndpointReference><d:Types>dn:NetworkVideoTransmitter</d:Types><d:Scopes>onvif://www.onvif.org/name/Front%20Door onvif://www.onvif.org/hardware/Test</d:Scopes><d:XAddrs>\(address)</d:XAddrs></d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>
        """.utf8)
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let start = ContinuousClock.now
            let devices = try await CameraDiscovery.scan()
            for device in devices { print("ONVIF camera: \(device.host):\(device.onvifPort)\(device.onvifPath)") }
            print("Live scan: \(devices.count) devices in \(start.duration(to: .now))")
            return
        }
        let interface = DiscoveryInterface(address: "192.168.4.2", netmask: "255.255.255.0")!
        let valid = DiscoveryResponse.parse(reply(), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test")
        try check(valid.count == 1 && valid[0].host == "192.168.4.8" && valid[0].onvifPort == 8080 && valid[0].name == "Front Door", "ONVIF address, port and scope name")
        try check(valid[0].onvifPath == "/onvif/device_service", "Service path preserved")
        for address in ["http://example.com/onvif", "http://192.168.4.9/onvif", "http://127.0.0.1/onvif", "http://169.254.169.254/onvif", "file:///etc/passwd", "http://user:secret@192.168.4.8/onvif", "http://192.168.4.8/onvif?q=secret", "http://192.168.4.8:0/onvif", "https://192.168.4.8/onvif"] {
            try check(DiscoveryResponse.parse(reply(address), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Reject unsafe or unsupported address: \(address)")
        }
        try check(DiscoveryResponse.parse(reply(), source: "192.168.5.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Reject routed source")
        try check(DiscoveryResponse.parse(reply(), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:other").isEmpty, "Reject unrelated reply")
        for payload in ["<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>", String(repeating: "<x>", count: 30), String(repeating: "x", count: 32769)] {
            try check(DiscoveryResponse.parse(Data(payload.utf8) + reply(), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Reject unsafe or excessive XML")
        }
        let spoofed = String(decoding: reply(), as: UTF8.self).replacingOccurrences(of: "http://schemas.xmlsoap.org/ws/2005/04/discovery", with: "urn:wrong")
        try check(DiscoveryResponse.parse(Data(spoofed.utf8), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Require discovery namespaces")
        let tooDeep = String(decoding: reply(), as: UTF8.self).replacingOccurrences(of: "<d:Types>", with: String(repeating: "<x>", count: 25) + String(repeating: "</x>", count: 25) + "<d:Types>")
        try check(DiscoveryResponse.parse(Data(tooDeep.utf8), source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Reject valid but excessive XML depth")
        let utf16DTD = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".data(using: .utf16)!
        try check(DiscoveryResponse.parse(utf16DTD, source: "192.168.4.8", interfaces: [interface], messageID: "urn:uuid:test").isEmpty, "Reject alternate-encoding DTD")
        if let port = CommandLine.arguments.dropFirst().first.flatMap(UInt16.init) {
            let devices = try await DiscoveryTestSupport.scan(port: port)
            try check(devices.count == 1 && devices[0].host == "127.0.0.1" && devices[0].onvifPort == 8080, "Real UDP probe, correlation, parsing and deduplication")
            try check(devices[0].onvifPath == "/custom/device", "Real advertised path preserved")
            let start = ContinuousClock.now
            let scan = Task { try await DiscoveryTestSupport.scan(port: port, duration: .seconds(5)) }
            try await Task.sleep(for: .milliseconds(80))
            scan.cancel()
            do { _ = try await scan.value; throw Failure.failed("Cancelled discovery returned success") }
            catch is CancellationError { }
            try check(start.duration(to: .now) < .seconds(1), "Cancellation closes sockets promptly")
        }
        print("PASS: native ONVIF discovery, local address validation, bounded XML, real UDP, duplicates and cancellation")
    }
}
