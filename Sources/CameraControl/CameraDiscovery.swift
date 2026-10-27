import Darwin
import Foundation

struct DiscoveredCamera: Identifiable, Equatable, Sendable {
    let host: String
    let onvifPort: Int
    let onvifPath: String
    let name: String
    var id: String { host }
}

struct DiscoveryInterface: Sendable {
    let address: String
    private let value: UInt32
    private let mask: UInt32
    init?(address: String, netmask: String) {
        guard let value = Self.ipv4(address), let mask = Self.ipv4(netmask), mask != 0 else { return nil }
        self.address = address; self.value = value; self.mask = mask
    }
    func contains(_ host: String) -> Bool {
        guard let candidate = Self.ipv4(host), candidate != 0,
              candidate >> 24 < 224, candidate >> 24 != 0,
              candidate != 0xa9fea9fe,
              candidate & mask == value & mask else { return false }
        // A loopback sender must never be accepted through a LAN interface.
        if candidate >> 24 == 127 { return value >> 24 == 127 }
        let suffix = candidate & ~mask
        return suffix != 0 && suffix != ~mask
    }
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let value = UInt8(part) else { return nil }
            result = result << 8 | UInt32(value)
        }
        return result
    }
    static func active() -> [DiscoveryInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [DiscoveryInterface] = []
        var seen = Set<String>()
        var current = head
        while let item = current, result.count < 32 {
            defer { current = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_MULTICAST != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = item.pointee.ifa_netmask else { continue }
            let host = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { string($0.pointee.sin_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { string($0.pointee.sin_addr) }
            if seen.insert(host).inserted, let interface = DiscoveryInterface(address: host, netmask: netmask) { result.append(interface) }
        }
        return result
    }
    static func string(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

enum CameraDiscoveryError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        String(localized: "Could not search the local network. Check your connection and Local Network permission in System Settings.")
    }
}

// A socket belongs to one scan and closes on completion, cancellation or failure.
final class DiscoverySocket {
    private let fd: Int32
    private var destination: sockaddr_in
    init(interface: DiscoveryInterface, destination: String = "239.255.255.250", port: UInt16 = 3702) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw CameraDiscoveryError.unavailable }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, destination, &target.sin_addr)
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, interface.address, &local.sin_addr)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var multicastAddress = local.sin_addr
        var ttl: UInt8 = 1
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &multicastAddress, socklen_t(MemoryLayout<in_addr>.size)) == 0,
              setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0 else {
            Darwin.close(fd)
            throw CameraDiscoveryError.unavailable
        }
        self.fd = fd
        self.destination = target
    }
    deinit { Darwin.close(fd) }
    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == data.count
                }
            }
        }
    }
    func receive() -> (Data, String)? {
        var bytes = [UInt8](repeating: 0, count: 32769)
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
        }
        guard count > 0 else { return nil }
        return (Data(bytes.prefix(count)), DiscoveryInterface.string(source.sin_addr))
    }
}

enum CameraDiscovery {
    static func scan() async throws -> [DiscoveredCamera] {
        try Task.checkCancellation()
        let interfaces = DiscoveryInterface.active()
        let sockets = interfaces.compactMap { try? DiscoverySocket(interface: $0) }
        guard !sockets.isEmpty else { throw CameraDiscoveryError.unavailable }
        return try await scan(sockets: sockets, interfaces: interfaces, duration: .seconds(5))
    }
    static func scan(sockets: [DiscoverySocket], interfaces: [DiscoveryInterface], duration: Duration) async throws -> [DiscoveredCamera] {
        let messageID = "urn:uuid:\(UUID().uuidString)"
        let probe = Data("""
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><s:Header><a:MessageID>\(messageID)</a:MessageID><a:To s:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action s:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header><s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>
        """.utf8)
        let start = ContinuousClock.now
        let deadline = start.advanced(by: min(duration, .seconds(5)))
        var nextProbe = start
        var attempts = 0
        var sent = false
        var packets = 0
        var devices: [String: DiscoveredCamera] = [:]
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if attempts < 3, ContinuousClock.now >= nextProbe {
                for socket in sockets { if socket.send(probe) { sent = true } }
                attempts += 1
                nextProbe = start.advanced(by: .seconds(attempts))
            }
            for socket in sockets {
                while packets < 256, let (packet, source) = socket.receive() {
                    try Task.checkCancellation()
                    packets += 1
                    for device in DiscoveryResponse.parse(packet, source: source, interfaces: interfaces, messageID: messageID) {
                        if devices.count < 64 || devices[device.id] != nil { devices[device.id] = device }
                    }
                }
            }
            if packets >= 256 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard sent else { throw CameraDiscoveryError.unavailable }
        return devices.values.sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }
}

enum DiscoveryResponse {
    static func parse(_ data: Data, source: String, interfaces: [DiscoveryInterface], messageID: String) -> [DiscoveredCamera] {
        guard data.count <= 32768, interfaces.contains(where: { $0.contains(source) }),
              let xml = String(data: data, encoding: .utf8), !xml.contains("<!"), !xml.contains("\0") else { return [] }
        let reader = DiscoveryXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.failed, reader.relatesTo == messageID else { return [] }
        var result: [DiscoveredCamera] = []
        for match in reader.matches {
            guard match.types.split(whereSeparator: \.isWhitespace).contains(where: { $0.split(separator: ":").last == "NetworkVideoTransmitter" }) else { continue }
            for address in match.addresses.split(whereSeparator: \.isWhitespace).prefix(16) {
                guard address.utf8.count <= 2048, let url = URLComponents(string: String(address)),
                      url.scheme == "http", url.host == source, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil, (1...65535).contains(url.port ?? 80),
                      url.path.hasPrefix("/"), !url.path.hasPrefix("//"), url.path.utf8.count <= 1024,
                      !url.path.contains(where: { $0.isNewline || "?#\\".contains($0) }) else { continue }
                let nameScope = match.scopes.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("onvif://www.onvif.org/name/") }
                let name = nameScope.flatMap { String($0.dropFirst("onvif://www.onvif.org/name/".count)).removingPercentEncoding } ?? ""
                let cleanName = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
                result.append(DiscoveredCamera(host: source, onvifPort: url.port ?? 80, onvifPath: url.path, name: cleanName.isEmpty ? source : cleanName))
                break
            }
        }
        return result
    }
}

private final class DiscoveryXMLReader: NSObject, XMLParserDelegate {
    struct Match { var addresses = ""; var scopes = ""; var types = "" }
    private struct Element { let name: String; let namespace: String; var text = "" }
    private let soap = "http://www.w3.org/2003/05/soap-envelope"
    private let discovery = "http://schemas.xmlsoap.org/ws/2005/04/discovery"
    private let addressing = ["http://schemas.xmlsoap.org/ws/2004/08/addressing", "http://www.w3.org/2005/08/addressing"]
    private var stack: [Element] = []
    private var nodes = 0
    private var match: Match?
    private(set) var matches: [Match] = []
    private(set) var relatesTo: String?
    private(set) var failed = false
    private func abort(_ parser: XMLParser) { failed = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        nodes += 1
        guard stack.count < 24, nodes <= 512, attributes.count <= 32 else { abort(parser); return }
        stack.append(Element(name: elementName, namespace: namespaceURI ?? ""))
        if stack.count == 1, elementName != "Envelope" || namespaceURI != soap { abort(parser); return }
        if isPath([("Envelope", soap), ("Body", soap), ("ProbeMatches", discovery), ("ProbeMatch", discovery)]) {
            guard matches.count < 64 else { abort(parser); return }
            match = Match()
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let last = stack.indices.last else { return }
        guard stack[last].text.utf8.count + string.utf8.count <= 16384 else { abort(parser); return }
        stack[last].text += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let element = stack.last else { abort(parser); return }
        if stack.count == 3, stack[1].name == "Header", stack[1].namespace == soap,
           elementName == "RelatesTo", addressing.contains(element.namespace) {
            guard relatesTo == nil else { abort(parser); return }
            relatesTo = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stack.count == 5, stack[3].name == "ProbeMatch", element.namespace == discovery {
            switch elementName {
            case "XAddrs": match?.addresses = element.text
            case "Scopes": match?.scopes = element.text
            case "Types": match?.types = element.text
            default: break
            }
        }
        if isPath([("Envelope", soap), ("Body", soap), ("ProbeMatches", discovery), ("ProbeMatch", discovery)]), let match {
            matches.append(match); self.match = nil
        }
        stack.removeLast()
    }
    private func isPath(_ path: [(String, String)]) -> Bool {
        stack.count == path.count && zip(stack, path).allSatisfy { $0.name == $1.0 && $0.namespace == $1.1 }
    }
}
