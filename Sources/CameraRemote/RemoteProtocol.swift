import Foundation
import Darwin

enum RemoteProtocolError: Error {
    case invalidIdentifier, invalidResponse, rejected, unavailable, authentication, streamUnavailable
}

struct RemoteLiveConfiguration: Sendable {
    let serial: String
    let channel: Int
    let substream: Bool
    let username: String
    let password: String

    init(serial: String, channel: Int, substream: Bool, username: String, password: String) throws {
        _ = try RemoteProtocol.lookupRequest(serial: serial)
        guard (1...256).contains(channel), !username.isEmpty else { throw RemoteProtocolError.invalidIdentifier }
        self.serial = serial; self.channel = channel; self.substream = substream
        self.username = username; self.password = password
    }
}

enum RemoteLookup {
    // Blocking socket: invoke from a background task, not the UI thread.
    static func exchange(host: String, port: UInt16, request: Data, timeout: Int, allowPrivate: Bool = false) throws -> Data {
        guard port > 0, !request.isEmpty, request.count <= 1024, (1...10).contains(timeout) else {
            throw RemoteProtocolError.invalidIdentifier
        }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
            throw RemoteProtocolError.unavailable
        }
        defer { freeaddrinfo(first) }
        let address = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var copy = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &text, socklen_t(text.count)) != nil,
              allowPrivate || RemoteProtocol.publicIPv4(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else {
            throw RemoteProtocolError.invalidResponse
        }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RemoteProtocolError.unavailable }
        defer { Darwin.close(fd) }
        var duration = timeval(tv_sec: timeout, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &duration, socklen_t(MemoryLayout<timeval>.size)) == 0,
              connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { throw RemoteProtocolError.unavailable }
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { throw RemoteProtocolError.unavailable }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { throw RemoteProtocolError.unavailable }
        return Data(buffer.prefix(count))
    }
}

enum RemoteProtocol {
    private static func fixedIdentifier(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= 99,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteProtocolError.invalidIdentifier }
        return Data(value.utf8) + Data(repeating: 0, count: 100 - value.utf8.count)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data(stride(from: 0, through: 24, by: 8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    static func proxyRegistration(client: String, clientID: UInt32, serial: String, peerID: UInt32) throws -> Data {
        Data([0x12, 0x20, 0xb9, 0x0b]) + (try fixedIdentifier(client)) + littleEndian(clientID)
            + (try fixedIdentifier(serial)) + littleEndian(peerID)
    }

    static func hello(client: String, clientID: UInt32) throws -> Data {
        Data([0x12, 0x20, 0xd0, 0x07]) + littleEndian(clientID) + (try fixedIdentifier(client)) + Data(repeating: 0, count: 4)
    }
    static func heartbeat(counter: UInt16) -> Data {
        Data([0x12, 0x20, 0xd2, 0x07, UInt8(truncatingIfNeeded: counter), UInt8(counter >> 8), 0, 0])
    }
    static func keepAliveInterval(seconds: Double?) -> TimeInterval {
        guard let seconds, seconds.isFinite else { return 14 }
        return min(3600, max(1, seconds * 0.7))
    }
    static func checkLoginStatus(_ status: Int) throws {
        if status == 100 { return }
        if [104, 105, 106, 202, 203, 204, 205, 206, 207].contains(status) { throw RemoteProtocolError.authentication }
        throw RemoteProtocolError.rejected
    }

    static func connectRequest(client: String, clientID: UInt32, serial: String, externalAddress: String,
                               externalPort: UInt16, localAddress: String, localPort: UInt16, timestamp: UInt32) throws -> Data {
        var local = in_addr()
        guard publicIPv4(externalAddress), externalPort != 0, localPort != 0,
              localAddress.utf8.count < 100,
              localAddress.withCString({ inet_pton(AF_INET, $0, &local) }) == 1 else { throw RemoteProtocolError.invalidIdentifier }
        var bytes = Data(repeating: 0, count: 360)
        bytes.replaceSubrange(0..<4, with: [0x12, 0x20, 0xec, 0x03])
        bytes.replaceSubrange(4..<8, with: littleEndian(clientID))
        bytes.replaceSubrange(8..<108, with: try fixedIdentifier(client))
        bytes.replaceSubrange(108..<208, with: try fixedIdentifier(serial))
        bytes.replaceSubrange(208..<(208 + externalAddress.utf8.count), with: externalAddress.utf8)
        bytes.replaceSubrange(224..<228, with: [UInt8(truncatingIfNeeded: externalPort), UInt8(externalPort >> 8), UInt8(truncatingIfNeeded: localPort), UInt8(localPort >> 8)])
        bytes.replaceSubrange(228..<(228 + localAddress.utf8.count), with: localAddress.utf8)
        bytes.replaceSubrange(352..<356, with: littleEndian(timestamp))
        return bytes
    }

    static func peerRequest(_ bytes: some DataProtocol, clientID: UInt32) throws -> (address: String, port: UInt16, peerID: UInt32, proxyAddress: String?, proxyPort: UInt16?) {
        let data = Data(bytes)
        guard data.count >= 360, data.prefix(4) == Data([0x12, 0x20, 0xec, 0x03]) else { throw RemoteProtocolError.invalidResponse }
        func number(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        guard number(328) == clientID,
              let address = String(bytes: data[208..<224].prefix { $0 != 0 }, encoding: .ascii), publicIPv4(address),
              let proxy = String(bytes: data[332..<348].prefix { $0 != 0 }, encoding: .ascii) else {
            throw RemoteProtocolError.invalidResponse
        }
        let port = UInt16(data[224]) | UInt16(data[225]) << 8
        let proxyPort = number(348)
        guard port != 0 else { throw RemoteProtocolError.invalidResponse }
        if proxy.isEmpty && proxyPort == 0 { return (address, port, number(4), nil, nil) }
        guard publicIPv4(proxy), (1...65535).contains(proxyPort) else { throw RemoteProtocolError.invalidResponse }
        return (address, port, number(4), proxy, UInt16(proxyPort))
    }

    static func registration(client: String, timestamp: UInt32, natType: UInt32) throws -> Data {
        guard !client.isEmpty, client.utf8.count <= 99,
              client.utf8.allSatisfy({ (33...126).contains($0) }) else { throw RemoteProtocolError.invalidIdentifier }
        var bytes = Data([0x12, 0x20, 0xea, 0x03]) + Data(client.utf8) + Data([0])
        for value in [timestamp, natType] {
            for shift in stride(from: 0, through: 24, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        return bytes
    }

    private static func reliable(sequence: UInt32, flags: UInt8, payload: Data) throws -> Data {
        guard payload.count <= 1388 else { throw RemoteProtocolError.invalidIdentifier }
        let length = payload.count + 12
        var bytes = Data([0x12, 0x20, 0xd3, 0x07, 0, 0, UInt8(length & 255), UInt8(length >> 8), 0, 0, 0, 0, 0x58, 0x4d, 0x49, 0x50])
        for shift in stride(from: 0, through: 24, by: 8) { bytes.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        bytes.append(contentsOf: [1, flags, 0, 0])
        bytes.append(payload)
        return bytes
    }

    static func reliableData(sequence: UInt32, payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw RemoteProtocolError.invalidIdentifier }
        return try reliable(sequence: sequence, flags: 14, payload: payload)
    }

    static func reliableAck(sequence: UInt32) throws -> Data {
        try reliable(sequence: sequence, flags: 1, payload: Data())
    }

    static func reliablePacket(_ bytes: some DataProtocol) throws -> (sequence: UInt32, flags: UInt8, payload: Data) {
        let data = Data(bytes)
        guard data.count >= 24, data.count <= 1412,
              data.prefix(6) == Data([0x12, 0x20, 0xd3, 0x07, 0, 0]),
              Int(data[6]) | Int(data[7]) << 8 == data.count - 12,
              data[8..<12].allSatisfy({ $0 == 0 }), data[12..<16] == Data("XMIP".utf8) else { throw RemoteProtocolError.invalidResponse }
        let sequence = data[16..<20].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return (sequence, data[21], Data(data.dropFirst(24)))
    }

    struct ReliableReceiver {
        private var next: UInt64 = 0
        private var pending: [UInt32: (flags: UInt8, payload: Data)] = [:]
        private var message: Data?
        private var pendingBytes = 0

        mutating func accept(sequence: UInt32, flags: UInt8, payload: Data) throws -> [Data] {
            guard flags & 3 == 2, !payload.isEmpty, payload.count <= 1388 else { throw RemoteProtocolError.invalidResponse }
            let number = UInt64(sequence)
            if number < next { return [] }
            guard number - next < 256 else { throw RemoteProtocolError.invalidResponse }
            if let existing = pending[sequence] {
                guard existing.flags == flags && existing.payload == payload else { throw RemoteProtocolError.invalidResponse }
                return []
            }
            guard pendingBytes <= 2 * 1024 * 1024 - payload.count else { throw RemoteProtocolError.invalidResponse }
            pending[sequence] = (flags, payload)
            pendingBytes += payload.count
            var complete: [Data] = []
            while next <= UInt64(UInt32.max), let fragment = pending.removeValue(forKey: UInt32(next)) {
                pendingBytes -= fragment.payload.count
                let starts = fragment.flags & 4 != 0, ends = fragment.flags & 8 != 0
                if starts {
                    guard message == nil else { throw RemoteProtocolError.invalidResponse }
                    message = Data()
                }
                guard var current = message, current.count <= 2 * 1024 * 1024 - fragment.payload.count else { throw RemoteProtocolError.invalidResponse }
                current.append(fragment.payload)
                if ends { complete.append(current); message = nil } else { message = current }
                next += 1
            }
            return complete
        }
    }

    struct ReliableSender {
        // shortcut: one fragment per request; add segmentation for commands over 1388 bytes.
        private var next: UInt64 = 0
        private var pending: (sequence: UInt32, packet: Data, sentAt: TimeInterval)?
        var isPending: Bool { pending != nil }
        var pendingPacket: Data? { pending?.packet }

        mutating func start(_ payload: Data, at now: TimeInterval) throws -> Data {
            guard pending == nil, now.isFinite, next <= UInt64(UInt32.max) else { throw RemoteProtocolError.invalidResponse }
            let sequence = UInt32(next)
            let packet = try RemoteProtocol.reliableData(sequence: sequence, payload: payload)
            pending = (sequence, packet, now)
            next += 1
            return packet
        }

        mutating func retry(at now: TimeInterval) -> Data? {
            guard let current = pending, now.isFinite, now - current.sentAt >= 1 else { return nil }
            pending?.sentAt = now
            return current.packet
        }

        func teardown(_ payload: Data) throws -> Data {
            guard next <= UInt64(UInt32.max) else { throw RemoteProtocolError.invalidResponse }
            return try RemoteProtocol.reliableData(sequence: UInt32(next), payload: payload)
        }

        mutating func acknowledge(sequence: UInt32, count: UInt8) throws {
            guard count > 0 else { throw RemoteProtocolError.invalidResponse }
            guard let current = pending else { return }
            let start = UInt64(sequence), end = start + UInt64(count)
            if start <= UInt64(current.sequence), UInt64(current.sequence) < end { pending = nil }
        }
    }

    struct LiveMedia {
        private var buffer = Data()
        private var codec: UInt8?
        private let keyMarker = Data([0, 0, 1, 0xfc])

        mutating func append(_ data: Data) throws -> [(codec: UInt8, payload: Data)] {
            guard data.count <= 2 * 1024 * 1024, buffer.count <= 16 * 1024 * 1024 - data.count else { throw RemoteProtocolError.invalidResponse }
            buffer.append(data)
            var frames: [(codec: UInt8, payload: Data)] = []
            if codec == nil {
                guard let marker = buffer.range(of: keyMarker) else {
                    if buffer.count > 3 { buffer = Data(buffer.suffix(3)) }
                    return []
                }
                buffer = Data(buffer[marker.lowerBound...])
            }
            while buffer.count >= 8 {
                let header = [UInt8](buffer.prefix(16))
                guard header[0] == 0, header[1] == 0, header[2] == 1,
                      [0xfc, 0xfd, 0xfe, 0xfa, 0xf9].contains(header[3]) else { throw RemoteProtocolError.invalidResponse }
                let kind = header[3], headerSize = (kind == 0xfc || kind == 0xfe) ? 16 : 8
                guard header.count >= headerSize else { break }
                let length: Int
                if kind == 0xfc || kind == 0xfe {
                    length = (0..<4).reduce(0) { $0 | Int(header[12 + $1]) << ($1 * 8) }
                } else if kind == 0xfd {
                    length = (0..<4).reduce(0) { $0 | Int(header[4 + $1]) << ($1 * 8) }
                } else {
                    length = Int(header[6]) | Int(header[7]) << 8
                }
                guard length > 0, length <= 16 * 1024 * 1024 else { throw RemoteProtocolError.invalidResponse }
                guard buffer.count >= headerSize + length else { break }
                if kind == 0xfc {
                    let format = header[4] & 15
                    guard format == 2 || format == 3 else { throw RemoteProtocolError.invalidResponse }
                    codec = format
                }
                if (kind == 0xfc || kind == 0xfd), let codec {
                    frames.append((codec, Data(buffer.dropFirst(headerSize).prefix(length))))
                }
                buffer = Data(buffer.dropFirst(headerSize + length))
            }
            return frames
        }
    }

    static func publicIPv4(_ address: String) -> Bool {
        var parsed = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1 else { return false }
        let value = UInt32(bigEndian: parsed.s_addr)
        let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
        guard a != 0, a != 10, a != 127, a < 224,
              !(a == 100 && (64...127).contains(b)), !(a == 169 && b == 254),
              !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168),
              !(a == 192 && b == 0 && (c == 0 || c == 2)),
              !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))),
              !(a == 203 && b == 0 && c == 113) else { return false }
        return true
    }

    static func bootstrapRequest() -> Data {
        Data([0x14, 0x20, 0xf4, 0x05]) + Data("1234567890ab".utf8) + Data(repeating: 0, count: 88)
    }

    static func bootstrapResponse(_ bytes: some DataProtocol) throws -> String {
        let data = Data(bytes)
        guard data.count >= 24, data.prefix(4) == Data([0x14, 0x20, 0xf5, 0x05]),
              let address = String(bytes: data[4..<24].prefix { $0 != 0 }, encoding: .ascii) else {
            throw RemoteProtocolError.invalidResponse
        }
        guard publicIPv4(address) else { throw RemoteProtocolError.invalidResponse }
        return address
    }

    static func lookupRequest(serial: String) throws -> Data {
        guard !serial.isEmpty, serial.utf8.count <= 64,
              serial.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw RemoteProtocolError.invalidIdentifier
        }
        return Data([0x15, 0x20, 0x00, 0xb0]) + Data(serial.utf8)
    }

    static func lookupResponse(_ bytes: some DataProtocol) throws -> (address: String, port: Int) {
        let data = Data(bytes)
        guard data.count >= 140, data.prefix(4) == Data([0x15, 0x20, 0x01, 0xb0]) else {
            throw RemoteProtocolError.invalidResponse
        }
        guard data[4..<8].elementsEqual([1, 0, 0, 0]) else { throw RemoteProtocolError.rejected }
        let addressBytes = data[108..<128].prefix { $0 != 0 }
        guard let address = String(bytes: addressBytes, encoding: .ascii) else { throw RemoteProtocolError.invalidResponse }
        guard publicIPv4(address) else { throw RemoteProtocolError.invalidResponse }
        let port = data[128..<132].enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard (1...65535).contains(port) else { throw RemoteProtocolError.invalidResponse }
        return (address, port)
    }

}
