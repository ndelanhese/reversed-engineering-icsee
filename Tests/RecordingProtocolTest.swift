import Foundation
import Network

@main enum RecordingProtocolTest {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.failed(message) }
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--fallback-cancel-only") { try await fallbackCancellationTest(); return }
        try require(CameraRecordingTime(wire: "2024-02-29 23:59:59")?.adding(seconds: 1)?.wire == "2024-03-01 00:00:00", "Leap day arithmetic")
        for wire in ["2023-02-29 00:00:00", "2024-04-31 12:00:00", "2024-01-01 24:00:00", "2024-01-01 00:60:00", "2024-01-01 00:00:60", "0000-01-01 00:00:00", "2024-1-01 00:00:00", "2024-01-01 00:00:00Z"] {
            try require(CameraRecordingTime(wire: wire) == nil, "Malformed clock rejected")
        }
        try require(CameraRecordingTime(wire: "9999-12-31 23:59:59")?.adding(seconds: 1) == nil, "Clock overflow rejected")
        try require(CameraRecordingTime(date: Date(timeIntervalSince1970: .greatestFiniteMagnitude)) == nil, "Extreme finite Date rejected safely")
        try framingTests()
        try await queryTests()
        try await downloadTests()
        try await concurrentAdmissionTest()
        try await delayedClaimTest()
        try await unsupportedStartTest()
        try await fallbackCancellationTest()
        try await nativeDeadlineTest()
        print("PASS: recording wall clocks, calendar/storage, inclusive bounded history, independent authenticated download, EOS and abort cleanup")
    }
    static func framingTests() throws {
        var bytes = try DVRIPFrame(session: 12, sequence: 3, message: 1426, payload: Data([0, 4, 0])).encoded()
        bytes[1] = 1; bytes[12] = 7; bytes[13] = 1
        for split in 0...bytes.count {
            var parser = RecordingPacketFramer()
            try parser.append(Data(bytes.prefix(split)))
            let early = try parser.next()
            try parser.append(Data(bytes.dropFirst(split)))
            let result = try early ?? parser.next()
            try require(result?.payload == Data([0, 4, 0]) && result?.fragment == 7 && result?.end == 1, "Every TCP split retains media bytes and header flags")
        }
        var combined = RecordingPacketFramer(); try combined.append(bytes + bytes)
        try require(try combined.next()?.end == 1 && combined.next()?.end == 1, "Coalesced flags retained")
        var oversized = bytes; oversized.replaceSubrange(16..<20, with: [255, 255, 255, 255])
        do { var parser = RecordingPacketFramer(); try parser.append(oversized); _ = try parser.next(); throw Failure.failed("Oversized media packet accepted") }
        catch DVRIPError.responseTooLarge { }
        var truncated = RecordingPacketFramer(); try truncated.append(Data(bytes.dropLast()))
        try require(try truncated.next() == nil, "Truncated packet never published")
    }
    static func client(_ peers: RecordingPeers) -> DVRIPRecordingClient {
        DVRIPRecordingClient(host: "camera.invalid", username: "synthetic", password: UUID().uuidString, transportFactory: { peers.next() })
    }
    static func queryTests() async throws {
        let peer = RecordingPeer()
        let subject = client(RecordingPeers([peer]))
        try await subject.connect()
        try await subject.connect()
        let loginCount = await peer.logins
        try require(loginCount == 1, "Connect is idempotent while authenticated")
        async let timeRequest = subject.cameraTime()
        async let storageRequest = subject.storage()
        let (clock, storage) = try await (timeRequest, storageRequest)
        try require(clock.wire == "2024-02-29 12:30:45", "Camera clock preserved")
        let calendar = try await subject.calendar(year: 2024, month: 2)
        try require(calendar.days == [1, 29], "Calendar least-significant day bit and month limit")
        try require(storage.presence == .present && storage.totalBytes == 16 * 1024 * 1024 && storage.statuses == [5], "Storage units and status independent of health")
        let listing = try await subject.recordings(day: CameraRecordingTime(wire: "2024-03-01 12:00:00")!)
        try require(listing.complete && listing.records.count == 65, "Inclusive pagination deduplicates without skipping same-second items")
        try require(listing.records.first?.begin.wire == "2024-02-29 23:59:00", "Midnight overlap survives")
        let queries = await peer.queries
        try require(queries.first == "2024-02-29 00:00:00" && queries.count == 2, "Bounded preceding-day query and inclusive cursor")
        await subject.disconnect(); await subject.disconnect()
        for mode in [RecordingPeer.Mode.emptyStorage, .absentStorage, .partialStorage] {
            let subject = client(RecordingPeers([RecordingPeer(mode: mode)])); try await subject.connect()
            let storage = try await subject.storage()
            try require(storage.presence == (mode == .emptyStorage ? .unknown : mode == .absentStorage ? .absent : .present), "Unknown storage differs from reported missing disk")
            if mode == .partialStorage { try require(storage.totalBytes == nil && storage.freeBytes == nil, "Missing partition sizes do not become a misleading aggregate") }
            await subject.disconnect()
        }
        let stuckPeer = RecordingPeer(mode: .sameSecond)
        let stuck = client(RecordingPeers([stuckPeer])); try await stuck.connect()
        let partial = try await stuck.recordings(day: CameraRecordingTime(wire: "2024-03-01 00:00:00")!)
        try require(!partial.complete && !partial.warnings.isEmpty && partial.records.count == 64, "Full same-second page explicitly incomplete")
        await stuck.disconnect()
        for mode in [RecordingPeer.Mode.authentication, .wrongSequence, .overflow, .unsupportedCalendar] {
            let subject = client(RecordingPeers([RecordingPeer(mode: mode)]))
            do {
                try await subject.connect()
                if mode == .overflow { _ = try await subject.storage() }
                else if mode == .unsupportedCalendar { _ = try await subject.calendar(year: 2024, month: 2) }
                else { throw Failure.failed("Invalid login accepted") }
                throw Failure.failed("Malformed or unsupported response accepted")
            } catch is DVRIPError { }
            await subject.disconnect()
        }
    }
    static func downloadTests() async throws {
        let recording = CameraRecording(fileName: "/opaque/../recording.h264", begin: CameraRecordingTime(wire: "2024-03-01 00:00:00")!, end: CameraRecordingTime(wire: "2024-03-01 00:01:00")!, estimatedBytes: 1, channel: 0, substream: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [RecordingPeer.Mode.normal, .endFlag, .emptyEnd, .lostEnd, .mediaWrongSession, .stall, .compatibility] {
            let control = RecordingPeer()
            let media = RecordingPeer(mode: mode == .compatibility ? .claimUnsupported : mode, media: true)
            let fallback = RecordingPeer(mode: .compatibility, media: true)
            let peers = RecordingPeers(mode == .compatibility ? [control, media, fallback] : [control, media])
            let subject = client(peers); try await subject.connect()
            let url = directory.appendingPathComponent(UUID().uuidString)
            let download = Task { try await subject.download(recording: recording, to: url) }
            if mode == .stall { try await Task.sleep(for: .milliseconds(40)); download.cancel() }
            do {
                try await download.value
                try require([.normal, .endFlag, .emptyEnd, .compatibility].contains(mode), "Missing explicit EOS rejected")
                try require(try Data(contentsOf: url) == Data([0, 1, 2, 0, 3, 0]), "Binary NUL preserved; estimate does not end download")
                let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                try require(permissions?.intValue == 0o600, "Downloaded bytes private")
            } catch {
                if [.normal, .endFlag, .emptyEnd, .compatibility].contains(mode) { throw error }
                try require(!FileManager.default.fileExists(atPath: url.path), "Incomplete download removed")
            }
            let commands = await control.actions
            try require(commands.contains("DownloadStop"), "Best-effort stop after every download")
            let logins = await media.logins
            try require(logins == 0, "Claim socket shares authenticated control session")
            let clock = try await subject.cameraTime()
            try require(clock.year == 2024, "Control remains usable after transfer completion or cancellation")
            if mode == .compatibility {
                let logins = await fallback.logins
                try require(logins == 1, "Explicit unsupported claim permits one independently authenticated media dialect")
            }
            await subject.disconnect()
        }
        let control = RecordingPeer(), media = RecordingPeer(mode: .stall, media: true)
        let subject = client(RecordingPeers([control, media])); try await subject.connect()
        let output = directory.appendingPathComponent(UUID().uuidString)
        let transfer = Task { try await subject.download(recording: recording, to: output) }
        try await Task.sleep(for: .milliseconds(30))
        await subject.cancelDownload()
        do { try await transfer.value; throw Failure.failed("Explicit cancellation published a download") } catch is CancellationError { }
        try require(!FileManager.default.fileExists(atPath: output.path), "Explicit cancellation waits for private file cleanup")
        await subject.disconnect()
    }
    static func nativeDeadlineTest() async throws {
        let fixture = try RecordingSilentFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let subject = DVRIPRecordingClient(host: "127.0.0.1", port: Int(port), username: "synthetic", password: UUID().uuidString)
        let start = Date()
        do { try await subject.connect(); throw Failure.failed("Silent peer authenticated") }
        catch DVRIPError.timeout { }
        try require(Date().timeIntervalSince(start) < 6, "Native control deadline bounded")
        await subject.disconnect()
    }
    static func concurrentAdmissionTest() async throws {
        let control = RecordingPeer()
        let peers = RecordingPeers([control] + (0..<32).map { _ in RecordingPeer(mode: .stall, media: true) })
        let subject = client(peers); try await subject.connect()
        let recording = CameraRecording(fileName: "/opaque/race.h264", begin: CameraRecordingTime(wire: "2024-03-01 00:00:00")!, end: CameraRecordingTime(wire: "2024-03-01 00:01:00")!, estimatedBytes: nil, channel: 0, substream: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfers = (0..<32).map { _ in Task {
            do { try await subject.download(recording: recording, to: directory.appendingPathComponent(UUID().uuidString)); return false }
            catch RecordingError.busy { return true }
            catch { return false }
        } }
        try await Task.sleep(for: .milliseconds(50))
        for transfer in transfers { transfer.cancel() }
        var busy = 0
        for transfer in transfers { if await transfer.value { busy += 1 } }
        let transports = peers.createdCount
        await subject.disconnect()
        try require(transports == 2 && busy == 31, "Concurrent admission reserves one download before any actor suspension")
    }
    static func delayedClaimTest() async throws {
        let gate = RecordingHandshakeGate()
        let control = RecordingPeer(gate: gate)
        let media = RecordingPeer(mode: .delayedClaim, media: true, gate: gate)
        let subject = client(RecordingPeers([control, media])); try await subject.connect()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent(UUID().uuidString)
        let recording = CameraRecording(fileName: "/opaque/delayed.h264", begin: CameraRecordingTime(wire: "2024-03-01 00:00:00")!, end: CameraRecordingTime(wire: "2024-03-01 00:01:00")!, estimatedBytes: nil, channel: 0, substream: false)
        try await subject.download(recording: recording, to: output)
        try require(try Data(contentsOf: output) == Data([0, 1, 2, 0, 3, 0]), "Start precedes delayed Claim acknowledgement and early media is retained")
        await subject.disconnect()
    }
    static func unsupportedStartTest() async throws {
        let control = RecordingPeer(mode: .startUnsupported)
        let media = RecordingPeer(media: true)
        let compatibility = RecordingPeer(mode: .compatibility, media: true)
        let subject = client(RecordingPeers([control, media, compatibility])); try await subject.connect()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = CameraRecording(fileName: "/opaque/start-rejected.h264", begin: CameraRecordingTime(wire: "2024-03-01 00:00:00")!, end: CameraRecordingTime(wire: "2024-03-01 00:01:00")!, estimatedBytes: nil, channel: 0, substream: false)
        let output = directory.appendingPathComponent(UUID().uuidString)
        var rejected = false
        do { try await subject.download(recording: recording, to: output) }
        catch DVRIPError.unsupported { rejected = true }
        let logins = await compatibility.logins
        await subject.disconnect()
        try require(rejected && logins == 0 && !FileManager.default.fileExists(atPath: output.path), "Unsupported Start cannot authorize a compatibility login")
    }
    static func fallbackCancellationTest() async throws {
        let gate = RecordingHandshakeGate(holdStop: true)
        let control = RecordingPeer(gate: gate)
        let media = RecordingPeer(mode: .claimUnsupported, media: true)
        let compatibility = RecordingPeer(mode: .compatibility, media: true)
        let subject = client(RecordingPeers([control, media, compatibility])); try await subject.connect()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = CameraRecording(fileName: "/opaque/cancel-fallback.h264", begin: CameraRecordingTime(wire: "2024-03-01 00:00:00")!, end: CameraRecordingTime(wire: "2024-03-01 00:01:00")!, estimatedBytes: nil, channel: 0, substream: false)
        let output = directory.appendingPathComponent(UUID().uuidString)
        let transfer = Task { try await subject.download(recording: recording, to: output) }
        for _ in 0..<200 {
            if await gate.stopEntered { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let entered = await gate.stopEntered
        guard entered else { transfer.cancel(); await gate.releaseStop(); throw Failure.failed("Fallback Stop gate was not reached") }
        let cancellation = Task { await subject.cancelDownload() }
        for _ in 0..<200 {
            if await media.closed { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let closed = await media.closed
        await gate.releaseStop()
        await cancellation.value
        var cancelled = false
        do { try await transfer.value } catch is CancellationError { cancelled = true }
        let logins = await compatibility.logins
        await subject.disconnect()
        try require(closed && cancelled && logins == 0 && !FileManager.default.fileExists(atPath: output.path), "Cancellation during fallback Stop cannot reopen or authenticate media")
    }
}

// A deterministic transport peer exercises production framing and command decoding.
// It contains synthetic opaque identifiers only and never opens a camera socket.
final class RecordingPeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [any DVRIPTransport]
    private var count = 0
    init(_ peers: [any DVRIPTransport]) { self.peers = peers }
    var createdCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> any DVRIPTransport { lock.lock(); defer { lock.unlock() }; count += 1; return peers.removeFirst() }
}
actor RecordingHandshakeGate {
    var started = false
    var stopEntered = false
    private var holdStop: Bool
    private var stopContinuation: CheckedContinuation<Void, Never>?
    init(holdStop: Bool = false) { self.holdStop = holdStop }
    func start() { started = true }
    func stop() async {
        if !holdStop { return }
        stopEntered = true
        await withCheckedContinuation { stopContinuation = $0 }
    }
    func releaseStop() { holdStop = false; stopContinuation?.resume(); stopContinuation = nil }
}
actor RecordingPeer: DVRIPTransport {
    enum Mode: Sendable { case normal, sameSecond, authentication, wrongSequence, overflow, unsupportedCalendar, endFlag, emptyEnd, lostEnd, mediaWrongSession, stall, compatibility, claimUnsupported, emptyStorage, absentStorage, partialStorage, delayedClaim, startUnsupported }
    let mode: Mode
    let media: Bool
    let gate: RecordingHandshakeGate?
    var bytes = Data()
    var queries: [String] = []
    var actions: [String] = []
    var logins = 0
    var closed = false
    init(mode: Mode = .normal, media: Bool = false, gate: RecordingHandshakeGate? = nil) { self.mode = mode; self.media = media; self.gate = gate }
    func connect(deadline: Date) async throws { closed = false }
    func close() async { closed = true }
    func send(_ data: Data, deadline: Date) async throws {
        var parser = DVRIPFramer(); try parser.append(data)
        guard let request = try parser.next(), case .object(let object) = try DeviceJSON.decode(Data(request.payload.dropLast(2))) else { throw DVRIPError.malformed }
        var reply: [String: DeviceJSON] = ["Ret": .number(100), "SessionID": .string("0x0000000c")]
        switch request.message {
        case 1000:
            logins += 1; reply["AliveInterval"] = .number(3600)
            if mode == .authentication { reply["Ret"] = .number(106) }
        case 1452: reply["OPTimeQuery"] = .string("2024-02-29 12:30:45")
        case 1446:
            reply["OPSCalendar"] = .object(["Mask": .string("0x90000001")])
            if mode == .unsupportedCalendar { reply["Ret"] = .number(605) }
        case 1020:
            reply["StorageInfo"] = .array(mode == .emptyStorage ? [] : [.object(["Partition": .array([.object(["TotalSpace": .string(mode == .overflow ? "0xffffffffffffffff" : "0x10"), "RemainSpace": .number(0), "Status": .number(mode == .absentStorage ? 7 : 5)])])])])
            if mode == .partialStorage { reply["StorageInfo"] = .array([.object(["Partition": .array([.object(["TotalSpace": .number(16), "RemainSpace": .number(0)]), .object(["Status": .number(0)])])])]) }
        case 1440:
            guard case .object(let query)? = object["OPFileQuery"], case .string(let begin)? = query["BeginTime"] else { throw DVRIPError.malformed }
            queries.append(begin)
            let indices = mode == .sameSecond || queries.count == 1 ? Array(0..<64) : [63, 64]
            reply["OPFileQuery"] = .array(indices.map { index in
                let start = mode == .sameSecond ? "2024-03-01 00:00:00" : (index == 0 ? "2024-02-29 23:59:00" : String(format: "2024-03-01 00:%02d:%02d", index / 60, index % 60))
                return .object(["FileName": .string("/opaque/\(index).h264"), "BeginTime": .string(start), "EndTime": .string("2024-03-01 01:00:00"), "FileLength": .string("0x2")])
            })
        case 1424, 1420:
            guard case .object(let playback)? = object["OPPlayBack"], case .string(let action)? = playback["Action"] else { throw DVRIPError.malformed }
            actions.append(action)
            if action == "DownloadStart" { await gate?.start() }
            if action == "DownloadStop" { await gate?.stop() }
            if action == "DownloadStart" && mode == .startUnsupported { reply["Ret"] = .number(605) }
            if request.message == 1424 && mode == .claimUnsupported { reply["Ret"] = .number(605) }
        case 1006: break
        default: throw DVRIPError.malformed
        }
        let frame = DVRIPFrame(session: 12, sequence: request.sequence + (mode == .wrongSequence ? 1 : 0), message: request.message + 1, payload: try JSONEncoder().encode(DeviceJSON.object(reply)))
        if mode == .delayedClaim && request.message == 1424 {
            bytes.append(try DVRIPFrame(session: 12, sequence: 0, message: 1426, payload: Data([0, 1, 2, 0, 3, 0])).encoded())
            bytes.append(try frame.encoded())
            bytes.append(try DVRIPFrame(session: 12, sequence: 1, message: 1423, payload: Data()).encoded())
            return
        }
        bytes.append(try frame.encoded())
        if media && ((request.message == 1424 && mode != .compatibility) || (request.message == 1420 && mode == .compatibility && actions.last == "DownloadStart")) {
            if mode == .stall || mode == .claimUnsupported { return }
            var payload = try DVRIPFrame(session: mode == .mediaWrongSession ? 13 : 12, sequence: 0, message: 1426, payload: Data([0, 1, 2, 0, 3, 0])).encoded()
            if mode == .endFlag { payload[13] = 1 }
            bytes.append(payload)
            if mode == .normal || mode == .compatibility { bytes.append(try DVRIPFrame(session: 12, sequence: 1, message: 1423, payload: Data()).encoded()) }
            if mode == .emptyEnd { bytes.append(try DVRIPFrame(session: 12, sequence: 1, message: 1426, payload: Data()).encoded()) }
        }
    }
    func receive(deadline: Date) async throws -> Data {
        if mode == .delayedClaim, let gate, !(await gate.started) { throw DVRIPError.timeout }
        if mode == .stall && bytes.isEmpty { while !closed { try await Task.sleep(for: .milliseconds(5)) }; throw DVRIPError.disconnected }
        guard !bytes.isEmpty && !closed else { throw DVRIPError.disconnected }
        let part = Data(bytes.prefix(17)); bytes.removeFirst(part.count); return part
    }
}

final class RecordingSilentFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Recording.synthetic.loopback")
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
                    queue.asyncAfter(deadline: .now() + 6) { connection.cancel() }
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
