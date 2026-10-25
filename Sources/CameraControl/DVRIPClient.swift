import Foundation
import Network

/// DVRIP uses a 20-byte little-endian header. TCP chunks have no frame boundaries.
struct DVRIPFrame: Equatable, Sendable {
    let session: UInt32
    let sequence: UInt32
    let message: UInt16
    let payload: Data
    func encoded() throws -> Data {
        guard payload.count <= DVRIPFramer.maximumPayload else { throw DVRIPError.responseTooLarge }
        var data = Data([0xff, 0, 0, 0])
        data.appendLE(session); data.appendLE(sequence)
        data.append(contentsOf: [0, 0]); data.appendLE(message); data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

struct DVRIPFramer: Sendable {
    static let maximumPayload = 2 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws {
        // A receive is capped at 64KiB; reserve room for the next coalesced frame.
        guard data.count <= Self.maximumPayload + 20, buffer.count + data.count <= Self.maximumPayload + 20 + 65_536 else { throw DVRIPError.responseTooLarge }
        buffer.append(data)
    }
    mutating func next() throws -> DVRIPFrame? {
        guard buffer.count >= 20 else { return nil }
        let header = Array(buffer.prefix(20))
        guard header[0] == 0xff, header[1] <= 1, header[2] == 0, header[3] == 0 else { throw DVRIPError.malformed }
        guard header[12] == 0, header[13] == 0 else { throw DVRIPError.unsupportedFragment }
        let length = Int(Self.u32(header, 16))
        guard length <= Self.maximumPayload else { throw DVRIPError.responseTooLarge }
        guard buffer.count >= 20 + length else { return nil }
        let frame = DVRIPFrame(session: Self.u32(header, 4), sequence: Self.u32(header, 8), message: UInt16(header[14]) | UInt16(header[15]) << 8, payload: Data(buffer.dropFirst(20).prefix(length)))
        buffer = Data(buffer.dropFirst(20 + length))
        return frame
    }
    private static func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for offset in 0..<MemoryLayout<T>.size { append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
}

/// Transport injection is internal: protocol tests never need real camera connections.
protocol DVRIPTransport: Sendable {
    func connect(deadline: Date) async throws
    func send(_ data: Data, deadline: Date) async throws
    func receive(deadline: Date) async throws -> Data
    func close() async
}

// Network.framework owns socket synchronization. Each callback races only a deadline;
// this tiny locked completion cell guarantees the continuation is resumed once.
private final class DVRIPCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    @discardableResult func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

private final class DVRIPTCPTransport: DVRIPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.CamMac.DVRIP")
    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    func connect(deadline: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion = DVRIPCompletion(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.resolve(.success(()))
                case .failed, .cancelled: completion.resolve(.failure(DVRIPError.disconnected))
                default: break
                }
            }
            armDeadline(deadline, completion: completion)
            connection.start(queue: queue)
        }
    }
    func send(_ data: Data, deadline: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion = DVRIPCompletion(continuation)
            armDeadline(deadline, completion: completion)
            connection.send(content: data, completion: .contentProcessed { error in
                completion.resolve(error == nil ? .success(()) : .failure(DVRIPError.disconnected))
            })
        }
    }
    func receive(deadline: Date) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion = DVRIPCompletion(continuation)
            armDeadline(deadline, completion: completion)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data, !data.isEmpty { completion.resolve(.success(data)) }
                else if complete || error != nil { completion.resolve(.failure(DVRIPError.disconnected)) }
                else { completion.resolve(.failure(DVRIPError.malformed)) }
            }
        }
    }
    func close() async { connection.cancel() }
    private func armDeadline<Value>(_ deadline: Date, completion: DVRIPCompletion<Value>) {
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [connection] in
            if completion.resolve(.failure(DVRIPError.timeout)) { connection.cancel() }
        }
    }
}

/// One session, one FIFO transaction queue. A write holds the permit through
/// fresh read, leaf patch, set acknowledgement and readback despite actor reentrancy.
actor DVRIPClient {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let injectedTransport: (any DVRIPTransport)?
    private var transport: (any DVRIPTransport)?
    private var session: UInt32 = 0
    private var sequence: UInt32 = 0
    private var framer = DVRIPFramer()
    private var generation: UInt64 = 0
    private var keepAlive: Task<Void, Never>?
    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []

    init(host: String, port: Int = 34567, username: String, password: String) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.injectedTransport = nil
    }
    init(host: String, port: Int = 34567, username: String, password: String, transport: any DVRIPTransport) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.injectedTransport = transport
    }

    func connect() async throws {
        let deadline = Date().addingTimeInterval(3)
        try await acquire(deadline: deadline)
        defer { release() }
        try Task.checkCancellation()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.first?.isLetter == true || host.first?.isNumber == true,
              host.unicodeScalars.allSatisfy(allowed.contains), (1...65535).contains(port), !username.isEmpty else { throw DVRIPError.invalidEndpoint }
        await closeSession()
        let current = generation
        let channel: any DVRIPTransport = injectedTransport ?? DVRIPTCPTransport(host: host, port: UInt16(port))
        transport = channel
        do {
            try await channel.connect(deadline: deadline)
            try checkSessionGeneration(current)
            let reply = try await exchange(message: 1000, body: ["EncryptType": .string("MD5"), "LoginType": .string("DVRIP-Web"), "UserName": .string(username), "PassWord": .string(sofiaPassword(password))], deadline: deadline, login: true)
            try checkSessionGeneration(current)
            try checkReturn(reply)
            guard case .string(let token)? = reply["SessionID"], let authenticated = Self.sessionNumber(token), authenticated != 0, authenticated == session else { throw DVRIPError.malformed }
            let interval: Double
            if case .number(let seconds)? = reply["AliveInterval"] { interval = min(3600, max(1, NSDecimalNumber(decimal: seconds).doubleValue * 0.7)) }
            else { interval = 14 }
            keepAlive = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                    guard let self else { return }
                    await self.sendKeepAlive(generation: current)
                }
            }
        } catch {
            await closeSession()
            throw Self.safeError(error)
        }
    }

    func disconnect() async { await closeSession() }

    func read(name: String, capability: Bool = false) async throws -> DeviceJSON {
        try Self.validateSection(name)
        let deadline = Date().addingTimeInterval(5)
        try await acquire(deadline: deadline)
        defer { release() }
        do { return try await readLocked(name: name, capability: capability, deadline: deadline) }
        catch { throw Self.safeError(error) }
    }

    func write(name: String, original: DeviceJSON, updated: DeviceJSON) async throws -> DVRIPWriteResult {
        try Self.validateSection(name)
        // Capability/status blocks are never a generic configuration write target.
        guard !["SystemFunction", "EncodeCapability", "SystemInfo"].contains(name) else { throw DVRIPError.invalidSection }
        let edits = try updated.edits(from: original)
        let deadline = Date().addingTimeInterval(5)
        try await acquire(deadline: deadline)
        defer { release() }
        let fresh = try await readLocked(name: name, capability: false, deadline: deadline)
        let patched = try fresh.applying(edits: edits)
        guard !edits.isEmpty else { return DVRIPWriteResult(value: fresh, requiresRestart: false) }
        try Task.checkCancellation()
        let reply: [String: DeviceJSON]
        do { reply = try await exchange(message: 1040, body: ["Name": .string(name), name: patched], deadline: deadline) }
        catch { throw DVRIPError.writeUncertain }
        try checkReturn(reply)
        let requiresRestart = reply["Ret"] == .number(150)
        let readback: DeviceJSON
        do { readback = try await readLocked(name: name, capability: false, deadline: deadline) }
        catch { throw DVRIPError.writeUncertain }
        let verified = edits.allSatisfy { (try? readback.value(at: $0.path)) == $0.updated }
        guard verified || requiresRestart else { throw DVRIPError.verification }
        return DVRIPWriteResult(value: readback, requiresRestart: requiresRestart, verified: verified)
    }

    /// Called only by an explicit maintenance action. Acknowledgement is not proof
    /// that reboot completed. Keep TCP open: some firmware cancels reboot on close.
    func reboot() async throws {
        let deadline = Date().addingTimeInterval(5)
        try await acquire(deadline: deadline)
        defer { release() }
        let reply: [String: DeviceJSON]
        do { reply = try await exchange(message: 1450, body: ["Name": .string("OPMachine"), "OPMachine": .object(["Action": .string("Reboot")])], deadline: deadline) }
        catch { throw DVRIPError.writeUncertain }
        try checkReturn(reply)
        keepAlive?.cancel(); keepAlive = nil
        // Retain the socket while the device restarts, but do not permit more
        // commands on the old session. Reconnect must be an explicit later action.
        generation &+= 1
        session = 0
        framer = DVRIPFramer()
    }

    private func readLocked(name: String, capability: Bool, deadline: Date) async throws -> DeviceJSON {
        let message: UInt16 = capability ? 1360 : (name == "SystemInfo" ? 1020 : 1042)
        let reply = try await exchange(message: message, body: ["Name": .string(name)], deadline: deadline)
        try checkReturn(reply)
        guard let value = reply[name] else { throw DVRIPError.unsupported }
        return value
    }

    private func exchange(message: UInt16, body: [String: DeviceJSON], deadline: Date, login: Bool = false) async throws -> [String: DeviceJSON] {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw DVRIPError.timeout }
        guard let transport, login || session != 0 else { throw DVRIPError.disconnected }
        let current = generation
        var body = body
        if !login { body["SessionID"] = .string(String(format: "0x%08x", session)) }
        let payload = try JSONEncoder().encode(DeviceJSON.object(body)) + Data([10, 0])
        let sentSequence = sequence
        sequence &+= 1
        let sentSession = session
        do {
            try await transport.send(try DVRIPFrame(session: sentSession, sequence: sentSequence, message: message, payload: payload).encoded(), deadline: deadline)
            try checkSessionGeneration(current)
            while true {
                try Task.checkCancellation()
                guard deadline.timeIntervalSinceNow > 0 else { throw DVRIPError.timeout }
                if let frame = try framer.next() {
                    guard frame.message == message + 1, frame.sequence == sentSequence,
                          login || frame.session == sentSession else { throw DVRIPError.malformed }
                    var json = frame.payload
                    while json.last == 0 || json.last == 10 || json.last == 13 { json.removeLast() }
                    guard case .object(let reply) = try DeviceJSON.decode(json) else { throw DVRIPError.malformed }
                    if let token = reply["SessionID"] {
                        guard case .string(let text) = token, Self.sessionNumber(text) == frame.session else { throw DVRIPError.malformed }
                    }
                    if login { session = frame.session }
                    return reply
                }
                let data = try await transport.receive(deadline: deadline)
                try checkSessionGeneration(current)
                guard !data.isEmpty else { throw DVRIPError.disconnected }
                try framer.append(data)
            }
        } catch {
            // Correlation cannot be trusted after timeout, cancellation or partial IO.
            // Discard the stream; future calls require an explicit new authentication.
            if generation == current { await closeSession() }
            throw Self.safeError(error)
        }
    }

    private func checkReturn(_ reply: [String: DeviceJSON]) throws {
        guard case .number(let value)? = reply["Ret"] else { throw DVRIPError.malformed }
        switch value {
        case 100, 150: return
        case 104, 105, 106, 202, 203, 204, 205, 206, 207: throw DVRIPError.authentication
        case 103, 107, 213: throw DVRIPError.forbidden
        case 102, 210, 211, 502, 605, 607: throw DVRIPError.unsupported
        case 108: throw DVRIPError.timeout
        default: throw DVRIPError.rejected
        }
    }

    private func sendKeepAlive(generation expected: UInt64) async {
        guard generation == expected, session != 0 else { return }
        let deadline = Date().addingTimeInterval(5)
        do {
            try await acquire(deadline: deadline)
            defer { release() }
            guard generation == expected, session != 0 else { return }
            let reply = try await exchange(message: 1006, body: ["Name": .string("KeepAlive")], deadline: deadline)
            try checkReturn(reply)
        } catch {
            if generation == expected { await closeSession() }
        }
    }

    private func acquire(deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw DVRIPError.timeout }
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    await self?.cancelWaiter(id, error: .timeout)
                }
                if Task.isCancelled { cancelWaiter(id, error: .disconnected) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, error: .disconnected) }
        }
        if Task.isCancelled { release(); throw DVRIPError.disconnected }
    }
    private func cancelWaiter(_ id: UUID, error: DVRIPError) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume() }
    }
    private func closeSession() async {
        generation &+= 1
        keepAlive?.cancel(); keepAlive = nil
        session = 0; sequence = 0; framer = DVRIPFramer()
        let channel = transport; transport = nil
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: DVRIPError.disconnected) }
        await channel?.close()
    }
    private func checkSessionGeneration(_ expected: UInt64) throws {
        guard generation == expected else { throw DVRIPError.disconnected }
    }
    private static func sessionNumber(_ token: String) -> UInt32? {
        UInt32(token.hasPrefix("0x") || token.hasPrefix("0X") ? String(token.dropFirst(2)) : token, radix: 16)
    }
    private static func safeError(_ error: any Error) -> DVRIPError {
        if let safe = error as? DVRIPError { return safe }
        if error is CancellationError { return .disconnected }
        return .malformed
    }
    private static func validateSection(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")
        let lowered = name.lowercased()
        let forbidden = ["cloud", "account", "password", "passwd", "user", "group", "platform", "p2p", "nat", "upgrade", "reboot", "reset", "restore", "default", "factory", "format", "delete", "remove", "keepalive", "authority", "alarmset", "alarmInfo"]
        guard !name.isEmpty, name.utf8.count <= 128, name.unicodeScalars.allSatisfy(allowed.contains),
              !lowered.hasPrefix("op"), !forbidden.contains(where: { lowered.contains($0.lowercased()) }) else { throw DVRIPError.invalidSection }
    }
}
