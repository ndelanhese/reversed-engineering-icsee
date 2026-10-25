import Foundation
import Network

@main enum DVRIPControlTest {
    static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw TestFailure.failed(label) }
    }
    enum TestFailure: Error { case failed(String) }
    static func rejects(_ error: DVRIPError, _ operation: () throws -> Void) throws {
        do { try operation(); throw TestFailure.failed("Expected rejection") }
        catch let actual as DVRIPError { try require(actual == error, "Correct rejection") }
    }
    static func main() async throws {
        let original = try JSONDecoder().decode(DeviceJSON.self, from: Data(#"{"Brightness":42,"Unknown":{"Enabled":true},"Channels":[1,2],"Precise":12345678901234567890.12345,"Null":null}"#.utf8))
        try rejects(.malformed) { _ = try DeviceJSON.decode(Data("12345678901234567890123456789012345678901234567890".utf8)) }
        try require(try DeviceJSON.decode(Data("1.2300e2".utf8)) == .number(123), "Exact exponent numbers accepted")
        try require(try DeviceJSON.decode(Data(#"{"text":"12345678901234567890123456789012345678901234567890"}"#.utf8)) == .object(["text": .string("12345678901234567890123456789012345678901234567890")]), "Numeric strings remain strings")
        let encoded = try JSONEncoder().encode(original)
        let roundtrip = try JSONDecoder().decode(DeviceJSON.self, from: encoded)
        try require(roundtrip == original, "Numbers and booleans roundtrip without Double conversion")
        let updated = try original.replacing(at: [.key("Brightness")], with: .number(43))
        let edits = try updated.edits(from: original)
        let concurrent = try original.replacing(at: [.key("Unknown"), .key("Enabled")], with: .bool(false))
        let patched = try concurrent.applying(edits: edits)
        try require(try patched.value(at: [.key("Unknown"), .key("Enabled")]) == .bool(false), "Unrelated concurrent edit survives")
        try require(try patched.value(at: [.key("Brightness")]) == .number(43), "Edited leaf applied")
        let conflicted = try original.replacing(at: [.key("Brightness")], with: .number(44))
        try rejects(.conflict) { _ = try conflicted.applying(edits: edits) }
        try rejects(.invalidEdit) { _ = try DeviceJSON.object([:]).edits(from: original) }
        try rejects(.invalidEdit) { _ = try original.replacing(at: [.key("Brightness")], with: .string("43")) }
        try rejects(.invalidEdit) { _ = try original.replacing(at: [.key("Channels"), .index(3)], with: .number(3)) }
        let frame = DVRIPFrame(session: 12, sequence: 9, message: 1043, payload: Data("{}\n\0".utf8))
        let bytes = try frame.encoded()
        for split in 0...bytes.count {
            var parser = DVRIPFramer()
            try parser.append(Data(bytes.prefix(split)))
            let early = try parser.next()
            try parser.append(Data(bytes.dropFirst(split)))
            let result = try early ?? parser.next()
            try require(result == frame, "Frame survives every TCP split")
        }
        var coalesced = DVRIPFramer()
        try coalesced.append(bytes + bytes)
        try require(try coalesced.next() == frame, "First coalesced frame")
        try require(try coalesced.next() == frame, "Second coalesced frame")
        var fragment = bytes; fragment[12] = 1
        try rejects(.unsupportedFragment) { var parser = DVRIPFramer(); try parser.append(fragment); _ = try parser.next() }
        var oversized = bytes; oversized.replaceSubrange(16..<20, with: [1,0,32,0])
        try rejects(.responseTooLarge) { var parser = DVRIPFramer(); try parser.append(oversized); _ = try parser.next() }
        var malformed = bytes; malformed[0] = 0
        try rejects(.malformed) { var parser = DVRIPFramer(); try parser.append(malformed); _ = try parser.next() }
        try await clientTests(original: original, updated: updated, concurrent: concurrent)
        try await nativeTransportTests()
        print("PASS: DVRIP framing, JSON leaf conflicts, serialized protocol, auth, deadlines, no write replay and verified restart result")
    }

    static func clientTests(original: DeviceJSON, updated: DeviceJSON, concurrent: DeviceJSON) async throws {
        let transport = ScriptedDVRIPTransport(value: original)
        // Generated for this isolated fake peer; no reusable device credential exists.
        let client = DVRIPClient(host: "camera.invalid", port: 34567, username: "synthetic", password: UUID().uuidString, transport: transport)
        try await client.connect()
        async let first = client.read(name: "Camera.Param")
        async let second = client.read(name: "Camera.Param")
        _ = try await (first, second)
        _ = try await client.read(name: "SystemInfo")
        _ = try await client.read(name: "SystemFunction", capability: true)
        await transport.setValue(concurrent)
        let result = try await client.write(name: "Camera.Param", original: original, updated: updated)
        try require(result.requiresRestart, "Ret150 surfaced without reboot")
        try require(try result.value.value(at: [.key("Unknown"), .key("Enabled")]) == .bool(false), "Write preserves concurrent unrelated value")
        let stats = await transport.statistics()
        try require(stats.maximumInFlight == 1 && stats.writes == 1, "Requests serialize across actor suspension and one write")
        let editedConcurrent = try original.replacing(at: [.key("Brightness")], with: .number(99))
        await transport.setValue(editedConcurrent)
        do { _ = try await client.write(name: "Camera.Param", original: original, updated: updated); throw TestFailure.failed("Conflicting write accepted") }
        catch let error as DVRIPError { try require(error == .conflict, "Fresh leaf conflict rejects write") }
        let afterConflict = await transport.statistics()
        try require(afterConflict.writes == 1, "Conflict sends no additional set")
        await client.disconnect()
        for name in ["OPMachine", "OPPTZControl", "Users", "ModifyPassword", "NetWork.Cloud", "KeepAlive", "anything/unsafe"] {
            do { _ = try await client.read(name: name); throw TestFailure.failed("Unsafe section accepted") }
            catch let error as DVRIPError { try require(error == .invalidSection, "Operations rejected locally") }
        }
        let auth = ScriptedDVRIPTransport(value: original, loginReturn: 106)
        do { try await DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: auth).connect(); throw TestFailure.failed("Auth accepted") }
        catch let error as DVRIPError { try require(error == .authentication, "Auth rejection distinguished") }
        let mismatch = ScriptedDVRIPTransport(value: original, wrongSequence: true)
        do { try await DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: mismatch).connect(); throw TestFailure.failed("Sequence mismatch accepted") }
        catch let error as DVRIPError { try require(error == .malformed, "Sequence validated") }
        let lost = ScriptedDVRIPTransport(value: original, loseWriteReply: true)
        let uncertain = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: lost)
        try await uncertain.connect()
        do { _ = try await uncertain.write(name: "Camera.Param", original: original, updated: updated); throw TestFailure.failed("Lost acknowledgement accepted") }
        catch let error as DVRIPError { try require(error == .writeUncertain, "Lost write ack reports uncertainty") }
        let lostStats = await lost.statistics()
        try require(lostStats.writes == 1, "Write never replayed")
        let pendingTransport = ScriptedDVRIPTransport(value: original, ignoreWrite: true)
        let pendingClient = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: pendingTransport)
        try await pendingClient.connect()
        let pending = try await pendingClient.write(name: "Camera.Param", original: original, updated: updated)
        try require(pending.requiresRestart && !pending.verified && pending.value == original, "Ret150 preserves current readback while marking pending effect")
        try await pendingClient.reboot()
        let pendingStats = await pendingTransport.statistics()
        try require(pendingStats.reboots == 1, "Reboot requires separate explicit call")
        let wrongReadback = ScriptedDVRIPTransport(value: original, ignoreWrite: true, writeReturn: 100)
        let unverified = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: wrongReadback)
        try await unverified.connect()
        do { _ = try await unverified.write(name: "Camera.Param", original: original, updated: updated); throw TestFailure.failed("Wrong readback accepted") }
        catch let error as DVRIPError { try require(error == .verification, "Readback mismatch rejected") }
        await unverified.disconnect()
        for (options, expected) in [(Fault.wrongSession, DVRIPError.malformed), (.eof, .disconnected), (.unsupported, .unsupported), (.forbidden, .forbidden), (.malformedJSON, .malformed)] {
            let faulty = ScriptedDVRIPTransport(value: original, fault: options)
            let subject = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: faulty)
            try await subject.connect()
            do { _ = try await subject.read(name: "Camera.Param"); throw TestFailure.failed("Invalid response accepted") }
            catch let error as DVRIPError { try require(error == expected, "Protocol failure classified") }
            await subject.disconnect()
        }
        let concurrentTransport = ScriptedDVRIPTransport(value: original)
        let concurrentClient = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: concurrentTransport)
        try await concurrentClient.connect()
        let active = Task { try await concurrentClient.read(name: "Camera.Param") }
        try await Task.sleep(for: .milliseconds(10))
        let cancelled = Task { try await concurrentClient.read(name: "Camera.Param") }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        _ = try await active.value
        var cancellationRejected = false
        do { _ = try await cancelled.value } catch { cancellationRejected = true }
        try require(cancellationRejected, "Cancelled queued request does not run")
        _ = try await concurrentClient.read(name: "Camera.Param")
        await concurrentClient.disconnect()
        let deniedTransport = ScriptedDVRIPTransport(value: original, writeReturn: 107)
        let deniedClient = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: deniedTransport)
        try await deniedClient.connect()
        do { _ = try await deniedClient.write(name: "Camera.Param", original: original, updated: updated); throw TestFailure.failed("Unauthorized write accepted") }
        catch let error as DVRIPError { try require(error == .forbidden, "Unauthorized set remains explicit") }
        let deniedValue = try await deniedClient.read(name: "Camera.Param")
        try require(deniedValue == original, "Rejected write does not overwrite local value")
        await deniedClient.disconnect()
        let aliveTransport = ScriptedDVRIPTransport(value: original, aliveInterval: 1)
        let aliveClient = DVRIPClient(host: "camera.invalid", username: "x", password: UUID().uuidString, transport: aliveTransport)
        try await aliveClient.connect()
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await aliveClient.read(name: "Camera.Param")
        let aliveStats = await aliveTransport.statistics()
        try require(aliveStats.keepAlives > 0 && aliveStats.maximumInFlight == 1, "Keepalive shares request queue")
        await aliveClient.disconnect()
    }

    static func nativeTransportTests() async throws {
        let fixture = try SilentLocalDVRIPFixture()
        let port = try await fixture.start()
        let client = DVRIPClient(host: "127.0.0.1", port: Int(port), username: "synthetic", password: UUID().uuidString)
        let started = Date()
        do { try await client.connect(); throw TestFailure.failed("Silent server accepted") }
        catch let error as DVRIPError { try require(error == .timeout, "Native TCP login deadline") }
        try require(Date().timeIntervalSince(started) < 4, "Native operation deadline is bounded")
        await client.disconnect(); fixture.stop()
    }
}

enum Fault: Sendable { case wrongSession, eof, unsupported, forbidden, malformedJSON }

actor ScriptedDVRIPTransport: DVRIPTransport {
    var value: DeviceJSON
    var response = Data()
    var writes = 0
    var inFlight = 0
    var maximumInFlight = 0
    var keepAlives = 0
    var reboots = 0
    let fault: Fault?
    let aliveInterval: Int
    let writeReturn: Int
    let loginReturn: Int
    let wrongSequence: Bool
    let loseWriteReply: Bool
    let ignoreWrite: Bool
    init(value: DeviceJSON, loginReturn: Int = 100, wrongSequence: Bool = false, loseWriteReply: Bool = false, ignoreWrite: Bool = false, fault: Fault? = nil, aliveInterval: Int = 3600, writeReturn: Int = 150) {
        self.value = value; self.loginReturn = loginReturn; self.wrongSequence = wrongSequence
        self.loseWriteReply = loseWriteReply; self.ignoreWrite = ignoreWrite
        self.fault = fault; self.aliveInterval = aliveInterval; self.writeReturn = writeReturn
    }
    func connect(deadline: Date) async throws {}
    func close() async { response = Data() }
    func setValue(_ value: DeviceJSON) { self.value = value }
    func statistics() -> (writes: Int, maximumInFlight: Int, keepAlives: Int, reboots: Int) { (writes, maximumInFlight, keepAlives, reboots) }
    func send(_ data: Data, deadline: Date) async throws {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        var parser = DVRIPFramer(); try parser.append(data)
        guard let request = try parser.next() else { throw DVRIPError.malformed }
        let object = try JSONDecoder().decode(DeviceJSON.self, from: Data(request.payload.dropLast(2)))
        var payload: [String: DeviceJSON] = ["Ret": .number(100), "SessionID": .string("0x0000000c")]
        if request.message == 1000 { payload["Ret"] = .number(Decimal(loginReturn)); payload["AliveInterval"] = .number(Decimal(aliveInterval)) }
        else {
            guard case .string(let name) = try object.value(at: [.key("Name")]) else { throw DVRIPError.malformed }
            if name == "SystemInfo" && request.message != 1020 { throw DVRIPError.malformed }
            if name == "SystemFunction" && request.message != 1360 { throw DVRIPError.malformed }
            if request.message == 1006 { keepAlives += 1 }
            if request.message == 1450 {
                guard name == "OPMachine", try object.value(at: [.key("OPMachine"), .key("Action")]) == .string("Reboot") else { throw DVRIPError.malformed }
                reboots += 1
            }
            if request.message == 1040 {
                writes += 1
                if !ignoreWrite && [100, 150].contains(writeReturn) { value = try object.value(at: [.key(name)]) }
                payload["Ret"] = .number(Decimal(writeReturn))
                if loseWriteReply { response = Data(); return }
            } else { payload[name] = value }
        }
        if request.message != 1000 {
            if fault == .eof { response = Data(); return }
            if fault == .unsupported { payload["Ret"] = .number(605) }
            if fault == .forbidden { payload["Ret"] = .number(107) }
        }
        let session: UInt32 = request.message != 1000 && fault == .wrongSession ? 13 : 12
        let data = request.message != 1000 && fault == .malformedJSON ? Data("not json".utf8) : try JSONEncoder().encode(DeviceJSON.object(payload))
        response = try DVRIPFrame(session: session, sequence: request.sequence + (wrongSequence ? 1 : 0), message: request.message + 1, payload: data + Data([10,0])).encoded()
    }
    func receive(deadline: Date) async throws -> Data {
        try await Task.sleep(for: .milliseconds(5))
        guard !response.isEmpty else { inFlight -= 1; throw DVRIPError.disconnected }
        let part = Data(response.prefix(7)); response.removeFirst(part.count)
        if response.isEmpty { inFlight -= 1 }
        return part
    }
}

// A loopback-only silent server exercises the real Network.framework deadline.
// Listener callbacks and connection lifetimes stay on one serial DispatchQueue.
final class SilentLocalDVRIPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DVRIP.synthetic.loopback")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
                }
            }
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, let port = listener.port { continuation.resume(returning: port.rawValue) }
                if case .failed = state { continuation.resume(throwing: DVRIPError.disconnected) }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
