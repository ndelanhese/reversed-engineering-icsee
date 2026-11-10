import Foundation
import Darwin

protocol RemoteStreaming: Sendable {
    func cancel()
    func run(onFrame: (UInt8, Data) throws -> Void) throws
}

final class RemoteLiveClient: RemoteStreaming, @unchecked Sendable {
    private let configuration: RemoteLiveConfiguration
    private let lock = NSLock()
    private var cancelled = false
    #if REMOTE_TESTING
    private var testRoute: (@Sendable (String, UInt16) -> (String, UInt16))?
    init(configuration: RemoteLiveConfiguration, testRoute: @escaping @Sendable (String, UInt16) -> (String, UInt16)) {
        self.configuration = configuration; self.testRoute = testRoute
    }
    #endif
    private var currentStage = "starting"
    var stage: String { lock.withLock { currentStage } }
    private func mark(_ value: String) { lock.withLock { currentStage = value } }

    init(configuration: RemoteLiveConfiguration) { self.configuration = configuration }
    private func route(_ host: String, _ port: UInt16) -> (String, UInt16) {
        #if REMOTE_TESTING
        if let testRoute { return testRoute(host, port) }
        #endif
        return (host, port)
    }
    private func exchange(_ host: String, _ port: UInt16, _ request: Data) throws -> Data {
        let target = route(host, port)
        #if REMOTE_TESTING
        return try RemoteLookup.exchange(host: target.0, port: target.1, request: request, timeout: 4, allowPrivate: testRoute != nil)
        #else
        return try RemoteLookup.exchange(host: target.0, port: target.1, request: request, timeout: 4)
        #endif
    }
    private func connect(_ socket: Datagram, _ host: String, _ port: UInt16) throws {
        let target = route(host, port)
        try socket.connect(target.0, port: target.1)
    }
    func cancel() { lock.withLock { cancelled = true } }
    private func sendIfActive(_ socket: Datagram, _ packet: Data) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try socket.send(packet)
        }
    }
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func run(onFrame: (UInt8, Data) throws -> Void) throws {
        try checkCancellation()
        mark("bootstrap")
        let bootstrap = try exchange("secu100.net", 7999, RemoteProtocol.bootstrapRequest())
        try checkCancellation()
        let server = try RemoteProtocol.bootstrapResponse(bootstrap)
        let lookup = try exchange(server, 8777, RemoteProtocol.lookupRequest(serial: configuration.serial))
        try checkCancellation()
        let destination = try RemoteProtocol.lookupResponse(lookup)
        guard destination.port == 8765 else { throw RemoteProtocolError.invalidResponse }
        let registration = try Datagram()
        let socket = try Datagram()
        func wait(_ channel: Datagram, timeout: TimeInterval = 8) throws -> Data {
            let limit = Date().addingTimeInterval(timeout)
            while Date() < limit {
                try checkCancellation()
                if let packet = try channel.receive() { try checkCancellation(); return packet }
            }
            throw RemoteProtocolError.unavailable
        }
        let client = "!xmnatuuid-PhoneClient-" + String(format: "%04d%04d%04d", Int(Date().timeIntervalSince1970 * 1000) % 10000, Int.random(in: 0..<10000), Int.random(in: 0..<10000))
        let clientID: UInt32 = 1000
        let timestamp = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
        let registrationPacket = try RemoteProtocol.registration(client: client, timestamp: timestamp, natType: 3)
        mark("registration")
        try connect(registration, server, 8765)
        try sendIfActive(registration, registrationPacket)
        guard try wait(registration).starts(with: [0x12, 0x20, 0xeb, 0x03]) else { throw RemoteProtocolError.unavailable }
        try connect(socket, server, 8765)
        mark("external")
        try sendIfActive(socket, Data([0x12, 0x20, 0xe8, 0x03]))
        let external = try wait(socket)
        guard external.count >= 24, external.starts(with: [0x12, 0x20, 0xe9, 0x03]),
              let publicAddress = String(bytes: external[4..<20].prefix { $0 != 0 }, encoding: .ascii) else { throw RemoteProtocolError.invalidResponse }
        let externalPort = Self.uint32(external, at: 20)
        guard (1...65535).contains(externalPort) else { throw RemoteProtocolError.invalidResponse }
        let local = try socket.localAddress()
        let request = try RemoteProtocol.connectRequest(client: client, clientID: clientID, serial: configuration.serial,
            externalAddress: publicAddress, externalPort: UInt16(externalPort), localAddress: local.address, localPort: local.port, timestamp: timestamp)
        try connect(socket, destination.address, UInt16(destination.port))
        mark("rendezvous")
        try sendIfActive(socket, request)
        let deadline = Date().addingTimeInterval(20)
        var peer: (address: String, port: UInt16, peerID: UInt32, proxyAddress: String?, proxyPort: UInt16?)?
        while Date() < deadline && peer == nil {
            try checkCancellation()
            if let packet = try socket.receive(), packet.starts(with: [0x12, 0x20, 0xec, 0x03]) {
                peer = try RemoteProtocol.peerRequest(packet, clientID: clientID)
            }
        }
        guard let peer else { throw RemoteProtocolError.unavailable }
        let hello = try RemoteProtocol.hello(client: client, clientID: clientID)
        func handshake(timeout: TimeInterval) throws {
            try sendIfActive(socket, hello)
            let greeting = try wait(socket, timeout: timeout)
            guard greeting.count >= 112, greeting.starts(with: [0x12, 0x20, 0xd0, 0x07]),
                  Data(greeting[8..<108].prefix { $0 != 0 }) == Data(configuration.serial.utf8) else { throw RemoteProtocolError.invalidResponse }
            var answer = hello
            answer.replaceSubrange(0..<4, with: [0x12, 0x20, 0xd1, 0x07])
            answer.replaceSubrange(108..<110, with: greeting[108..<110])
            try sendIfActive(socket, answer); try sendIfActive(socket, hello)
            let limit = Date().addingTimeInterval(timeout)
            while Date() < limit {
                let accepted = try wait(socket, timeout: limit.timeIntervalSinceNow)
                if accepted.starts(with: [0x12, 0x20, 0xd1, 0x07]) || accepted.starts(with: [0x12, 0x20, 0xd2, 0x07]) { return }
                if accepted.starts(with: [0x12, 0x20, 0xd0, 0x07]), accepted.count >= 112,
                   Data(accepted[8..<108].prefix { $0 != 0 }) == Data(configuration.serial.utf8) {
                    try sendIfActive(socket, answer)
                }
            }
            throw RemoteProtocolError.unavailable
        }
        mark("direct")
        var connected = false
        do {
            try connect(socket, peer.address, peer.port)
            try handshake(timeout: 2)
            connected = true
        } catch { try checkCancellation() }
        if !connected {
            guard let proxyAddress = peer.proxyAddress, let proxyPort = peer.proxyPort else { throw RemoteProtocolError.unavailable }
            mark("proxy")
            try connect(socket, proxyAddress, proxyPort)
            try sendIfActive(socket, RemoteProtocol.proxyRegistration(client: client, clientID: clientID, serial: configuration.serial, peerID: peer.peerID))
            guard try wait(socket).starts(with: [0x12, 0x20, 0xba, 0x0b]) else { throw RemoteProtocolError.unavailable }
            mark("greeting")
            try handshake(timeout: 8)
        }
        var sender = RemoteProtocol.ReliableSender()
        var receiver = RemoteProtocol.ReliableReceiver()
        var queue: [Data] = []
        var queueBytes = 0
        var heartbeat = Date.distantPast, refresh = Date()
        var heartbeatCounter: UInt16 = 0
        var keepSession: UInt32 = 0, nextSequence: UInt32 = 3
        var keepInterval: TimeInterval = 14
        var keepAt = Date.distantFuture
        var keepDeadline: Date?

        func makeFrame(_ code: UInt16, sequence: UInt32, session: UInt32, object: [String: Any]) throws -> Data {
            var body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            body.append(contentsOf: [10, 0])
            var frame = Data([255, 0, 0, 0]) + Self.le(session) + Self.le(sequence) + Data([0, 0, UInt8(truncatingIfNeeded: code), UInt8(code >> 8)]) + Self.le(UInt32(body.count))
            frame.append(body)
            return frame
        }

        func pump(until limit: Date) throws {
            try checkCancellation()
            guard Date() < limit else { throw RemoteProtocolError.unavailable }
            if Date().timeIntervalSince(heartbeat) >= 1 {
                try sendIfActive(socket, RemoteProtocol.heartbeat(counter: heartbeatCounter))
                heartbeatCounter &+= 1
                heartbeat = Date()
            }
            if Date().timeIntervalSince(refresh) >= 20 {
                let now = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
                try sendIfActive(registration, RemoteProtocol.registration(client: client, timestamp: now, natType: 3)); refresh = Date()
            }
            if let keepDeadline, sender.isPending, Date() >= keepDeadline { throw RemoteProtocolError.unavailable }
            if keepSession != 0, Date() >= keepAt, !sender.isPending {
                let body: [String: Any] = ["Name": "KeepAlive", "SessionID": String(format: "0x%08X", keepSession)]
                let frame = try makeFrame(1006, sequence: nextSequence, session: keepSession, object: body)
                try sendIfActive(socket, sender.start(frame, at: ProcessInfo.processInfo.systemUptime))
                nextSequence &+= 1
                keepAt = Date().addingTimeInterval(keepInterval)
                keepDeadline = Date().addingTimeInterval(15)
            }
            if let retry = sender.retry(at: ProcessInfo.processInfo.systemUptime) { try sendIfActive(socket, retry) }
            guard let packet = try socket.receive(), packet.starts(with: [0x12, 0x20, 0xd3, 0x07]) else { return }
            let item = try RemoteProtocol.reliablePacket(packet)
            if item.flags & 3 == 1 {
                try sender.acknowledge(sequence: item.sequence, count: packet[20])
                if !sender.isPending { keepDeadline = nil }
            } else if item.flags & 3 == 2 {
                try sendIfActive(socket, RemoteProtocol.reliableAck(sequence: item.sequence))
                for frame in try receiver.accept(sequence: item.sequence, flags: item.flags, payload: item.payload) {
                    guard queue.count < 256, frame.count <= 8 * 1024 * 1024 - queueBytes else { throw RemoteProtocolError.invalidResponse }
                    queue.append(frame); queueBytes += frame.count
                }
            }
        }
        func transmit(_ code: UInt16, sequence: UInt32, session: UInt32, object: [String: Any]) throws {
            let frame = try makeFrame(code, sequence: sequence, session: session, object: object)
            try sendIfActive(socket, sender.start(frame, at: ProcessInfo.processInfo.systemUptime))
            let limit = Date().addingTimeInterval(15)
            while sender.isPending { try pump(until: limit) }
        }
        func message(_ wanted: UInt16, timeout: TimeInterval, expectedSession: UInt32? = nil, expectedSequence: UInt32? = nil) throws -> Data {
            let limit = Date().addingTimeInterval(timeout)
            while true {
                while !queue.isEmpty {
                    let frame = queue.removeFirst()
                    queueBytes -= frame.count
                    guard frame.count >= 20, frame[0] == 255, Int(Self.uint32(frame, at: 16)) == frame.count - 20 else { throw RemoteProtocolError.invalidResponse }
                    let code = UInt16(frame[14]) | UInt16(frame[15]) << 8
                    if code == wanted {
                        if let expectedSession, Self.uint32(frame, at: 4) != expectedSession { throw RemoteProtocolError.invalidResponse }
                        if let expectedSequence, Self.uint32(frame, at: 8) != expectedSequence,
                           Self.uint32(frame, at: 8) != expectedSequence &+ 1 { throw RemoteProtocolError.invalidResponse }
                        return frame
                    }
                }
                try pump(until: limit)
            }
        }
        func response(_ frame: Data, login: Bool = false) throws -> [String: Any] {
            let body = Data(frame.dropFirst(20).prefix { $0 != 0 })
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any], let status = object["Ret"] as? Int else { throw RemoteProtocolError.invalidResponse }
            if login { try RemoteProtocol.checkLoginStatus(status) }
            else if status != 100 { throw RemoteProtocolError.rejected }
            return object
        }
        mark("login")
        try transmit(1000, sequence: 0, session: 0, object: ["EncryptType": "MD5", "LoginType": "DVRIP-Web", "UserName": configuration.username, "PassWord": sofiaPassword(configuration.password)])
        mark("login-message")
        let login = try message(1001, timeout: 15, expectedSequence: 0)
        mark("login-response")
        let loginReply = try response(login, login: true)
        let session = Self.uint32(login, at: 4)
        guard session != 0, let rawSession = loginReply["SessionID"] as? String,
              let bodySession = UInt32(rawSession.hasPrefix("0x") ? String(rawSession.dropFirst(2)) : rawSession, radix: rawSession.hasPrefix("0x") ? 16 : 10),
              bodySession == session else { throw RemoteProtocolError.invalidResponse }
        let sessionText = String(format: "0x%08X", session)
        let parameters: [String: Any] = ["Channel": configuration.channel - 1, "CombinMode": "NONE", "StreamType": configuration.substream ? "Extra" : "Main", "TransMode": "TCP"]
        mark("claim")
        try transmit(1413, sequence: 1, session: session, object: ["Name": "OPMonitor", "SessionID": sessionText, "OPMonitor": ["Action": "Claim", "Parameter": parameters]])
        _ = try response(message(1414, timeout: 15, expectedSession: session, expectedSequence: 1))
        mark("start")
        defer {
            if let stop = try? makeFrame(1410, sequence: nextSequence, session: session, object: ["Name": "OPMonitor", "SessionID": sessionText, "OPMonitor": ["Action": "Stop", "Parameter": parameters]]),
               let packet = try? sender.teardown(stop) {
                let pendingKeepAlive = keepDeadline == nil ? nil : sender.pendingPacket
                for _ in 0..<3 {
                    if let pendingKeepAlive { try? socket.send(pendingKeepAlive) }
                    try? socket.send(packet)
                    usleep(100_000)
                }
            }
        }
        try transmit(1410, sequence: 2, session: session, object: ["Name": "OPMonitor", "SessionID": sessionText, "OPMonitor": ["Action": "Start", "Parameter": parameters]])
        keepInterval = RemoteProtocol.keepAliveInterval(seconds: (loginReply["AliveInterval"] as? NSNumber)?.doubleValue)
        keepAt = Date().addingTimeInterval(keepInterval)
        keepSession = session
        var media = RemoteProtocol.LiveMedia()
        mark("media")
        while true {
            let frame = try message(1412, timeout: 20)
            guard Self.uint32(frame, at: 4) == session else { throw RemoteProtocolError.invalidResponse }
            for sample in try media.append(Data(frame.dropFirst(20))) { try onFrame(sample.codec, sample.payload) }
        }
    }

    private static func le(_ value: UInt32) -> Data {
        Data(stride(from: 0, through: 24, by: 8).map { UInt8(truncatingIfNeeded: value >> $0) })
    }
    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
}

private final class Datagram {
    private let fd: Int32
    init() throws {
        fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw RemoteProtocolError.unavailable }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { Darwin.close(fd); throw RemoteProtocolError.unavailable }
    }
    deinit { Darwin.close(fd) }
    func connect(_ host: String, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1,
              withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw RemoteProtocolError.unavailable }
    }
    func send(_ data: Data) throws {
        guard data.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == data.count else { throw RemoteProtocolError.unavailable }
    }
    func receive() throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return nil }
        guard count > 0 else { throw RemoteProtocolError.unavailable }
        return Data(bytes.prefix(count))
    }
    func localAddress() throws -> (address: String, port: UInt16) {
        var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw RemoteProtocolError.unavailable }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address.sin_addr, &text, socklen_t(text.count)) != nil else { throw RemoteProtocolError.unavailable }
        return (String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), UInt16(bigEndian: address.sin_port))
    }
}
