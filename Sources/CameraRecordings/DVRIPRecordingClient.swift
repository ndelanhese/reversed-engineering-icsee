import Foundation
import Darwin

/// Read-only history commands and file downloads own their authentication and
/// sockets. Settings and live-view sessions are never borrowed or interrupted.
actor DVRIPRecordingClient {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let factory: (@Sendable () -> any DVRIPTransport)?
    private var control: RecordingProtocolSession?
    private var keepAlive: Task<Void, Never>?
    private var active: (id: UUID, media: RecordingProtocolSession, recording: CameraRecording, cancelled: Bool)?
    private var downloadWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var generation: UInt64 = 0
    private var connecting = false
    private var disconnectDepth = 0
    static let maximumDownloadBytes: UInt64 = 8 * 1024 * 1024 * 1024

    init(host: String, port: Int = 34567, username: String, password: String,
         transportFactory: (@Sendable () -> any DVRIPTransport)? = nil) {
        self.host = host; self.port = port; self.username = username; self.password = password; factory = transportFactory
    }
    func connect() async throws {
        guard disconnectDepth == 0 else { throw RecordingError.busy }
        let expected = generation
        if let control, await control.isAuthenticated {
            guard expected == generation, disconnectDepth == 0 else { throw RecordingError.busy }
            return
        }
        guard expected == generation, disconnectDepth == 0 else { throw RecordingError.busy }
        guard !connecting else { throw RecordingError.busy }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.first?.isLetter == true || host.first?.isNumber == true,
              host.unicodeScalars.allSatisfy(allowed.contains), (1...65535).contains(port), !username.isEmpty else { throw DVRIPError.invalidEndpoint }
        connecting = true
        defer { connecting = false }
        keepAlive?.cancel()
        let session = makeSession()
        control = session
        do {
            let interval = try await session.login(username: username, password: password)
            guard expected == generation else { throw CancellationError() }
            keepAlive = Task { [weak self, session] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                        guard let self, await self.isCurrent(session, generation: expected) else { return }
                        let reply = try await session.exchange(1006, body: ["Name": .string("KeepAlive")])
                        try RecordingWire.checkReturn(reply)
                    } catch { return }
                }
            }
        } catch {
            await session.close()
            if expected == generation { control = nil }
            throw error
        }
    }
    func disconnect() async {
        disconnectDepth += 1
        defer { disconnectDepth -= 1 }
        generation &+= 1
        keepAlive?.cancel(); keepAlive = nil
        await cancelDownload()
        let session = control; control = nil
        await session?.close()
    }
    /// Closes media promptly and awaits the matching best-effort stop. The task
    /// that owns the file removes its incomplete output before returning.
    func cancelDownload() async {
        guard let download = active else { return }
        active?.cancelled = true
        await download.media.close()
        await withCheckedContinuation { continuation in
            if active?.id == download.id { downloadWaiters.append((download.id, continuation)) }
            else { continuation.resume() }
        }
    }
    func cameraTime() async throws -> CameraRecordingTime {
        let reply = try await request(1452, name: "OPTimeQuery")
        guard case .string(let wire)? = reply["OPTimeQuery"], let time = CameraRecordingTime(wire: wire) else { throw RecordingError.invalidTime }
        return time
    }
    func calendar(year: Int, month: Int) async throws -> RecordingCalendar {
        guard let first = CameraRecordingTime(wire: String(format: "%04d-%02d-01 00:00:00", year, month)),
              let days = CameraRecordingTime.calendar.range(of: .day, in: .month, for: first.date) else { throw RecordingError.invalidSelection }
        let reply = try await request(1446, name: "OPSCalendar", value: .object([
            "Year": .number(Decimal(year)), "Month": .number(Decimal(month)), "Event": .string("*"), "FileType": .string("h264"), "Rev": .string("")]))
        guard case .object(let value)? = reply["OPSCalendar"], let raw = value["Mask"] else { throw DVRIPError.unsupported }
        let mask = try RecordingWire.unsigned(raw)
        guard mask <= UInt32.max else { throw DVRIPError.malformed }
        return RecordingCalendar(year: year, month: month, days: Set(days.filter { mask & (UInt64(1) << ($0 - 1)) != 0 }))
    }
    func storage() async throws -> RecordingStorage {
        let reply = try await request(1020, name: "StorageInfo")
        guard case .array(let disks)? = reply["StorageInfo"] else { throw DVRIPError.unsupported }
        var statuses: [Int] = [], total: UInt64 = 0, free: UInt64 = 0
        var hasTotal = false, hasFree = false, partitions = 0
        var allTotals = true, allFree = true
        for disk in disks {
            guard case .object(let diskFields) = disk else { throw DVRIPError.malformed }
            guard let rawPartitions = diskFields["Partition"] else { continue }
            guard case .array(let values) = rawPartitions else { throw DVRIPError.malformed }
            for partition in values {
                guard case .object(let fields) = partition else { throw DVRIPError.malformed }
                partitions += 1
                if let status = fields["Status"] {
                    let value = try RecordingWire.unsigned(status)
                    guard value <= Int.max else { throw DVRIPError.malformed }
                    statuses.append(Int(value))
                }
                for (key, isTotal) in [("TotalSpace", true), ("RemainSpace", false)] {
                    guard let raw = fields[key] else {
                        if isTotal { allTotals = false } else { allFree = false }
                        continue
                    }
                    let mib = try RecordingWire.unsigned(raw)
                    let (bytes, overflow) = mib.multipliedReportingOverflow(by: 1024 * 1024)
                    guard !overflow else { throw DVRIPError.malformed }
                    let (sum, sumOverflow) = (isTotal ? total : free).addingReportingOverflow(bytes)
                    guard !sumOverflow else { throw DVRIPError.malformed }
                    if isTotal { total = sum; hasTotal = true } else { free = sum; hasFree = true }
                }
            }
        }
        // Empty query results alone cannot establish that SD hardware is absent.
        let presence: RecordingStorage.Presence = partitions == 0 ? .unknown :
            (!statuses.isEmpty && statuses.count == partitions && statuses.allSatisfy { $0 == 7 } ? .absent : .present)
        return RecordingStorage(presence: presence, disks: disks, statuses: statuses,
                                totalBytes: hasTotal && allTotals ? total : nil, freeBytes: hasFree && allFree ? free : nil)
    }
    func recordings(day: CameraRecordingTime, channel: Int = 0, substream: Bool = false) async throws -> RecordingListing {
        guard (0...255).contains(channel), let end = day.dayStart.adding(seconds: 86_399) else { throw RecordingError.invalidSelection }
        // Completeness covers this bounded query: a file beginning more than
        // 24 hours before the day cannot be discovered without a wider search.
        let start = day.dayStart.adding(seconds: -86_400) ?? day.dayStart
        var cursor = start
        var records: [String: CameraRecording] = [:]
        var complete = false
        var warnings: [String] = []
        let deadline = Date().addingTimeInterval(45)
        for _ in 0..<128 {
            try Task.checkCancellation()
            let session = try requireControl()
            let reply = try await session.exchange(1440, body: ["Name": .string("OPFileQuery"), "OPFileQuery": .object([
                "BeginTime": .string(cursor.wire), "EndTime": .string(end.wire), "Channel": .number(Decimal(channel)),
                "DriverTypeMask": .string("0x0000FFFF"), "Event": .string("*"), "StreamType": .string(substream ? "0x00000001" : "0x00000000"), "Type": .string("h264")])], deadline: deadline)
            let status = try RecordingWire.returnCode(reply)
            if [109, 119].contains(status) { complete = true; break }
            try RecordingWire.checkReturn(reply, search: true)
            guard case .array(let items)? = reply["OPFileQuery"], items.count <= 8192 else { throw DVRIPError.malformed }
            let page = try items.map { try RecordingWire.recording($0, channel: channel, substream: substream) }
            for item in page where item.begin <= end && item.end >= day.dayStart { records[item.id] = item }
            guard records.count <= 8192 else { throw DVRIPError.responseTooLarge }
            if page.isEmpty || status == 110 || (page.count < 64 && status != 111) { complete = true; break }
            guard let next = page.map(\.begin).max(), next >= cursor, next <= end else { throw DVRIPError.malformed }
            if next == cursor {
                warnings.append(String(localized: "The camera returned a full page at one timestamp. More recordings may exist at that time.")); break
            }
            cursor = next // Inclusive: adding a second would silently skip siblings.
        }
        if !complete && warnings.isEmpty { warnings.append(String(localized: "The history query reached its safety limit. Some recordings may be missing.")) }
        return RecordingListing(records: records.values.sorted { $0.begin == $1.begin ? $0.id < $1.id : $0.begin < $1.begin }, complete: complete, warnings: warnings)
    }
    func download(recording: CameraRecording, to url: URL,
                  progress: @escaping @Sendable (RecordingDownloadProgress) -> Void = { _ in }) async throws {
        try RecordingWire.validate(recording)
        guard active == nil, disconnectDepth == 0 else { throw RecordingError.busy }
        let session = try requireControl()
        guard url.isFileURL else { throw RecordingError.invalidSelection }
        let expected = generation
        let media = makeSession(), id = UUID()
        // Reserve synchronously. Reading the control token is an actor hop and
        // must never leave another caller free to admit a second download.
        active = (id, media, recording, false)
        var handle: FileHandle?
        var created = false
        do {
            let token = try await session.sessionID
            try checkDownload(id, generation: expected)
            try await withTaskCancellationHandler {
                try checkDownload(id, generation: expected)
                try await media.connect(sessionID: token)
                try checkDownload(id, generation: expected)
                // Some devices withhold Claim ACK until control Start. Send
                // Claim, start control, then correlate ACK while buffering
                // media that arrives before that acknowledgement.
                try await media.beginClaim(body: playback(recording, action: "Claim"))
                try checkDownload(id, generation: expected)
                let start = try await session.exchange(1420, body: playback(recording, action: "DownloadStart"))
                try checkDownload(id, generation: expected)
                try RecordingWire.checkReturn(start)
                let claim = try await media.finishClaim()
                try checkDownload(id, generation: expected)
                do {
                    try RecordingWire.checkReturn(claim)
                } catch DVRIPError.unsupported {
                    // Documented compatibility dialect only after explicit rejection
                    // of the shared-session claim, before any media was consumed.
                    guard !(await media.hasBufferedBytes) else { throw DVRIPError.malformed }
                    try checkDownload(id, generation: expected)
                    await stop(recording, media: media, control: session)
                    try checkDownload(id, generation: expected)
                    let closedGeneration = await media.closeForCompatibility()
                    try checkDownload(id, generation: expected)
                    try await media.loginOnFreshTransport(makeTransport(), afterClosing: closedGeneration, username: username, password: password)
                    try checkDownload(id, generation: expected)
                    let claim = try await media.exchange(1424, body: playback(recording, action: "Claim"))
                    try checkDownload(id, generation: expected)
                    try RecordingWire.checkReturn(claim)
                    let start = try await media.exchange(1420, body: playback(recording, action: "DownloadStart"))
                    try checkDownload(id, generation: expected)
                    try RecordingWire.checkReturn(start)
                    try await writeMedia(media, recording: recording, url: url, handle: &handle, created: &created, progress: progress)
                    return
                }
                try checkDownload(id, generation: expected)
                try await writeMedia(media, recording: recording, url: url, handle: &handle, created: &created, progress: progress)
            } onCancel: { Task { await media.close() } }
            try Task.checkCancellation()
            guard active?.id == id, active?.cancelled == false else { throw CancellationError() }
            try handle?.synchronize(); try handle?.close(); handle = nil
            await stop(recording, media: media, control: session)
            await media.close()
            try Task.checkCancellation()
            guard active?.id == id, active?.cancelled == false else { throw CancellationError() }
            finishDownload(id)
        } catch {
            try? handle?.close()
            if created { try? FileManager.default.removeItem(at: url) }
            await stop(recording, media: media, control: session)
            await media.close()
            let cancelled = active?.id == id && active?.cancelled == true
            finishDownload(id)
            if Task.isCancelled || cancelled { throw CancellationError() }
            throw error
        }
    }
    private func checkDownload(_ id: UUID, generation expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == generation, disconnectDepth == 0, active?.id == id, active?.cancelled == false else { throw CancellationError() }
    }
    private func finishDownload(_ id: UUID) {
        if active?.id == id { active = nil }
        let completed = downloadWaiters.filter { $0.0 == id }
        downloadWaiters.removeAll { $0.0 == id }
        for (_, continuation) in completed { continuation.resume() }
    }
    private func writeMedia(_ media: RecordingProtocolSession, recording: CameraRecording, url: URL,
                            handle: inout FileHandle?, created: inout Bool,
                            progress: @Sendable (RecordingDownloadProgress) -> Void) async throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw RecordingError.fileIO }
        created = true
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var bytes: UInt64 = 0
        let deadline = Date().addingTimeInterval(30 * 60)
        while true {
            try Task.checkCancellation()
            let frame: RecordingPacket
            do { frame = try await media.nextMedia(deadline: min(deadline, Date().addingTimeInterval(15))) }
            catch DVRIPError.disconnected { throw RecordingError.incompleteTransfer }
            if frame.message == 1423 { break }
            guard frame.message == 1426 else { throw DVRIPError.malformed }
            let (count, overflow) = bytes.addingReportingOverflow(UInt64(frame.payload.count))
            guard !overflow, count <= Self.maximumDownloadBytes else { throw RecordingError.byteLimit }
            do { try handle?.write(contentsOf: frame.payload) } catch { throw RecordingError.fileIO }
            bytes = count
            progress(RecordingDownloadProgress(receivedBytes: bytes, estimatedBytes: recording.estimatedBytes))
            if frame.payload.isEmpty || frame.end != 0 { break }
        }
        guard bytes > 0 else { throw RecordingError.incompleteTransfer }
    }
    private func stop(_ recording: CameraRecording, media: RecordingProtocolSession, control: RecordingProtocolSession) async {
        let body = playback(recording, action: "DownloadStop")
        // A fresh unstructured task deliberately does not inherit cancellation.
        await Task {
            _ = try? await control.exchange(1420, body: body, deadline: Date().addingTimeInterval(2))
            if await media.isCompatibilitySession {
                _ = try? await media.exchange(1420, body: body, deadline: Date().addingTimeInterval(2))
            }
        }.value
    }
    private func playback(_ recording: CameraRecording, action: String) -> [String: DeviceJSON] {
        ["Name": .string("OPPlayBack"), "OPPlayBack": .object([
            "Action": .string(action), "StartTime": .string(recording.begin.wire), "EndTime": .string(recording.end.wire),
            "Parameter": .object(["PlayMode": .string("ByName"), "FileName": .string(recording.fileName),
                                  "StreamType": .number(recording.substream ? 1 : 0), "Value": .number(0), "TransMode": .string("TCP")])])]
    }
    private func request(_ message: UInt16, name: String, value: DeviceJSON? = nil) async throws -> [String: DeviceJSON] {
        var body: [String: DeviceJSON] = ["Name": .string(name)]
        body[name] = value
        let session = try requireControl()
        let reply = try await session.exchange(message, body: body)
        try RecordingWire.checkReturn(reply)
        return reply
    }
    private func requireControl() throws -> RecordingProtocolSession {
        guard let control else { throw DVRIPError.disconnected }; return control
    }
    private func makeTransport() -> any DVRIPTransport { factory?() ?? DVRIPTCPTransport(host: host, port: UInt16(port)) }
    private func makeSession() -> RecordingProtocolSession { RecordingProtocolSession(transport: makeTransport()) }
    private func isCurrent(_ session: RecordingProtocolSession, generation expected: UInt64) -> Bool { generation == expected && control === session }
}

private enum RecordingWire {
    static func unsigned(_ value: DeviceJSON) throws -> UInt64 {
        let text: String
        switch value {
        case .string(let string): text = string
        case .number(let decimal): text = NSDecimalNumber(decimal: decimal).stringValue
        default: throw DVRIPError.malformed
        }
        let hex = text.hasPrefix("0x") || text.hasPrefix("0X")
        let digits = hex ? String(text.dropFirst(2)) : text
        guard !digits.isEmpty, digits.utf8.allSatisfy({ hex ? (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) : (48...57).contains($0) }),
              let result = UInt64(digits, radix: hex ? 16 : 10) else { throw DVRIPError.malformed }
        return result
    }
    static func returnCode(_ reply: [String: DeviceJSON]) throws -> UInt64 {
        guard let raw = reply["Ret"] else { throw DVRIPError.malformed }; return try unsigned(raw)
    }
    static func checkReturn(_ reply: [String: DeviceJSON], search: Bool = false) throws {
        switch try returnCode(reply) {
        case 100: return
        case 109, 110, 111, 119:
            guard search else { throw DVRIPError.rejected }; return
        case 104, 105, 106, 202, 203, 204, 205, 206, 207: throw DVRIPError.authentication
        case 103, 107, 213: throw DVRIPError.forbidden
        case 102, 210, 211, 502, 605, 607: throw DVRIPError.unsupported
        case 108: throw DVRIPError.timeout
        default: throw DVRIPError.rejected
        }
    }
    static func validate(_ recording: CameraRecording) throws {
        guard !recording.fileName.isEmpty, recording.fileName.utf8.count <= 4096,
              !recording.fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              recording.begin <= recording.end, (0...255).contains(recording.channel) else { throw RecordingError.invalidSelection }
    }
    static func recording(_ json: DeviceJSON, channel: Int, substream: Bool) throws -> CameraRecording {
        guard case .object(let fields) = json, case .string(let name)? = fields["FileName"],
              case .string(let beginWire)? = fields["BeginTime"], case .string(let endWire)? = fields["EndTime"],
              let begin = CameraRecordingTime(wire: beginWire), let end = CameraRecordingTime(wire: endWire) else { throw DVRIPError.malformed }
        var bytes: UInt64?
        if let length = fields["FileLength"] {
            let (value, overflow) = try unsigned(length).multipliedReportingOverflow(by: 1024)
            guard !overflow else { throw DVRIPError.malformed }; bytes = value
        }
        let actualChannel = try fields["Channel"].map { raw -> Int in
            let value = try unsigned(raw); guard value <= 255 else { throw DVRIPError.malformed }; return Int(value)
        } ?? channel
        let actualStream = try fields["StreamType"].map { raw -> Bool in
            let value = try unsigned(raw); guard value <= 1 else { throw DVRIPError.malformed }; return value == 1
        } ?? substream
        let recording = CameraRecording(fileName: name, begin: begin, end: end, estimatedBytes: bytes, channel: actualChannel, substream: actualStream)
        try validate(recording)
        return recording
    }
}

/// This parser preserves header bytes 12/13. Their interpretation depends on the
/// packet kind; the strict settings framer deliberately continues to reject them.
struct RecordingPacket: Sendable {
    let session: UInt32; let sequence: UInt32; let message: UInt16
    let fragment: UInt8; let end: UInt8; let payload: Data
}
struct RecordingPacketFramer: Sendable {
    private var buffer = Data()
    var hasBufferedBytes: Bool { !buffer.isEmpty }
    mutating func append(_ data: Data) throws {
        guard data.count <= DVRIPFramer.maximumPayload + 20, buffer.count <= DVRIPFramer.maximumPayload + 65_556 - data.count else { throw DVRIPError.responseTooLarge }
        buffer.append(data)
    }
    mutating func next() throws -> RecordingPacket? {
        guard buffer.count >= 20 else { return nil }
        let bytes = Array(buffer.prefix(20))
        guard bytes[0] == 255, bytes[1] <= 1, bytes[2] == 0, bytes[3] == 0 else { throw DVRIPError.malformed }
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) } }
        let length = Int(u32(16))
        guard length <= DVRIPFramer.maximumPayload else { throw DVRIPError.responseTooLarge }
        guard buffer.count >= length + 20 else { return nil }
        let packet = RecordingPacket(session: u32(4), sequence: u32(8), message: UInt16(bytes[14]) | UInt16(bytes[15]) << 8,
                                     fragment: bytes[12], end: bytes[13], payload: Data(buffer.dropFirst(20).prefix(length)))
        buffer = Data(buffer.dropFirst(length + 20)); return packet
    }
}

/// One FIFO control exchange at a time, including keepalive. Media has its own
/// session object and receive loop, so it cannot consume a control reply.
private actor RecordingProtocolSession {
    private var transport: any DVRIPTransport
    private var session: UInt32 = 0
    private var sequence: UInt32 = 0
    private var framer = RecordingPacketFramer()
    private var busy = false
    private var closed = false
    private var closeGeneration: UInt64 = 0
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var pendingClaim: (sequence: UInt32, deadline: Date)?
    private var earlyMedia: [RecordingPacket] = []
    private var earlyMediaBytes = 0
    private(set) var isCompatibilitySession = false
    var isAuthenticated: Bool { session != 0 && !closed }
    var hasBufferedBytes: Bool { framer.hasBufferedBytes || !earlyMedia.isEmpty }
    var sessionID: UInt32 { get throws { guard isAuthenticated else { throw DVRIPError.disconnected }; return session } }
    init(transport: any DVRIPTransport) { self.transport = transport }
    func connect(sessionID: UInt32) async throws {
        let deadline = Date().addingTimeInterval(4)
        try await transport.connect(deadline: deadline)
        guard !closed else { throw DVRIPError.disconnected }; session = sessionID
    }
    @discardableResult func login(username: String, password: String) async throws -> Double {
        try await connect(sessionID: 0)
        let reply = try await exchange(1000, body: ["EncryptType": .string("MD5"), "LoginType": .string("DVRIP-Web"),
            "UserName": .string(username), "PassWord": .string(sofiaPassword(password))], login: true)
        try RecordingWire.checkReturn(reply)
        guard session != 0, case .string(let token)? = reply["SessionID"], try RecordingWire.unsigned(.string(token)) == session else { throw DVRIPError.malformed }
        let interval = try reply["AliveInterval"].map { try RecordingWire.unsigned($0) } ?? 20
        return min(3600, max(1, Double(interval) * 0.7))
    }
    func loginOnFreshTransport(_ newTransport: any DVRIPTransport, afterClosing expected: UInt64, username: String, password: String) async throws {
        try Task.checkCancellation()
        // A close arriving after compatibility preparation revokes this token;
        // explicit cancellation must never be undone by reopening the session.
        guard closed, closeGeneration == expected else { throw CancellationError() }
        transport = newTransport; session = 0; sequence = 0; closed = false; framer = RecordingPacketFramer()
        earlyMedia.removeAll(); earlyMediaBytes = 0; pendingClaim = nil
        isCompatibilitySession = true
        try await login(username: username, password: password)
    }
    func close() async {
        _ = await closeForCompatibility()
    }
    func closeForCompatibility() async -> UInt64 {
        closeGeneration &+= 1
        let current = closeGeneration
        closed = true; session = 0
        let pending = waiters; waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: DVRIPError.disconnected) }
        await transport.close()
        return current
    }
    func exchange(_ message: UInt16, body: [String: DeviceJSON], deadline: Date = Date().addingTimeInterval(5), login: Bool = false) async throws -> [String: DeviceJSON] {
        try await acquire(deadline: deadline)
        defer { release() }
        do {
            try Task.checkCancellation()
            guard !closed, login || session != 0 else { throw DVRIPError.disconnected }
            var body = body
            if !login { body["SessionID"] = .string(String(format: "0x%08x", session)) }
            let sentSequence = sequence; sequence &+= 1
            let payload = try JSONEncoder().encode(DeviceJSON.object(body)) + Data([10, 0])
            try await transport.send(try DVRIPFrame(session: session, sequence: sentSequence, message: message, payload: payload).encoded(), deadline: deadline)
            return try await receiveReply(message: message, sequence: sentSequence, deadline: deadline, login: login, allowMedia: isCompatibilitySession)
        } catch { await close(); throw error }
    }
    /// Holds the media session's exchange permit until finishClaim correlates
    /// the reply. The control socket can issue Start during this interval.
    func beginClaim(body: [String: DeviceJSON]) async throws {
        let deadline = Date().addingTimeInterval(5)
        try await acquire(deadline: deadline)
        do {
            try Task.checkCancellation()
            guard isAuthenticated else { throw DVRIPError.disconnected }
            var body = body
            body["SessionID"] = .string(String(format: "0x%08x", session))
            let sent = sequence; sequence &+= 1
            let payload = try JSONEncoder().encode(DeviceJSON.object(body)) + Data([10, 0])
            try await transport.send(try DVRIPFrame(session: session, sequence: sent, message: 1424, payload: payload).encoded(), deadline: deadline)
            pendingClaim = (sent, deadline)
        } catch { release(); await close(); throw error }
    }
    func finishClaim() async throws -> [String: DeviceJSON] {
        guard let claim = pendingClaim else { throw DVRIPError.malformed }
        pendingClaim = nil
        defer { release() }
        do { return try await receiveReply(message: 1424, sequence: claim.sequence, deadline: claim.deadline, allowMedia: true) }
        catch { await close(); throw error }
    }
    private func receiveReply(message: UInt16, sequence sent: UInt32, deadline: Date, login: Bool = false,
                              allowMedia: Bool) async throws -> [String: DeviceJSON] {
        while true {
            let packet = try await next(deadline: deadline)
            if allowMedia && (packet.message == 1426 || packet.message == 1423) {
                guard packet.session == session else { throw DVRIPError.malformed }
                guard earlyMediaBytes <= 8 * 1024 * 1024 - packet.payload.count, earlyMedia.count < 1024 else { throw DVRIPError.responseTooLarge }
                earlyMedia.append(packet); earlyMediaBytes += packet.payload.count
                continue
            }
            guard packet.message == message + 1, packet.sequence == sent, login || packet.session == session,
                  packet.fragment == 0, packet.end == 0 else { throw DVRIPError.malformed }
            var json = packet.payload
            while json.last == 0 || json.last == 10 || json.last == 13 { json.removeLast() }
            guard case .object(let reply) = try DeviceJSON.decode(json) else { throw DVRIPError.malformed }
            if let token = reply["SessionID"] { guard try RecordingWire.unsigned(token) == packet.session else { throw DVRIPError.malformed } }
            if login { session = packet.session }
            return reply
        }
    }
    func nextMedia(deadline: Date) async throws -> RecordingPacket {
        try Task.checkCancellation()
        guard !closed else { throw DVRIPError.disconnected }
        if !earlyMedia.isEmpty {
            let packet = earlyMedia.removeFirst(); earlyMediaBytes -= packet.payload.count
            return packet
        }
        let packet = try await next(deadline: deadline)
        guard packet.session == session, packet.message == 1426 || packet.message == 1423 else { throw DVRIPError.malformed }
        return packet
    }
    private func next(deadline: Date) async throws -> RecordingPacket {
        while true {
            try Task.checkCancellation()
            guard !closed else { throw DVRIPError.disconnected }
            guard deadline.timeIntervalSinceNow > 0 else { throw DVRIPError.timeout }
            if let packet = try framer.next() { return packet }
            let bytes = try await transport.receive(deadline: deadline)
            guard !closed, !bytes.isEmpty else { throw DVRIPError.disconnected }
            try framer.append(bytes)
        }
    }
    private func acquire(deadline: Date) async throws {
        try Task.checkCancellation()
        guard !closed else { throw DVRIPError.disconnected }
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    await self?.cancelWaiter(id, error: DVRIPError.timeout)
                }
            }
        } onCancel: { Task { await self.cancelWaiter(id, error: CancellationError()) } }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancelWaiter(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: error)
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().1.resume() }
    }
}
