import AppKit
@preconcurrency import AVFoundation
import Observation

@MainActor @Observable
final class CameraRecordingsModel {
    private(set) var camera: Camera
    private(set) var connected = false
    private(set) var connecting = false
    private(set) var querying = false
    private(set) var downloading = false
    private(set) var converting = false
    private(set) var exporting = false
    private(set) var calendarDays: Set<Int>?
    private(set) var records: [CameraRecording] = []
    private(set) var storage: RecordingStorage?
    private(set) var cameraClock: CameraRecordingTime?
    private(set) var selectedDay: Date
    private(set) var selectedRecording: CameraRecording?
    private(set) var movie: MovieResult?
    private(set) var player: AVPlayer?
    private(set) var position: TimeInterval = 0
    private(set) var cameraPosition: Date?
    private(set) var receivedBytes: UInt64 = 0
    private(set) var rawAvailable = false
    var channel: Int
    var substream: Bool
    var playbackRate: Float = 1
    var intervalStart: TimeInterval = 0
    var intervalEnd: TimeInterval = 0
    var error: String?
    var notices: [String] {
        connectionNotices + queryNotices + mediaNotices + (exportNotice.map { [$0] } ?? []) +
            (calendarUnavailable ? [String(localized: "Monthly calendar unavailable. Select any day to search it directly.")] : [])
    }
    private var connectionNotices: [String] = []
    private var queryNotices: [String] = []
    private var mediaNotices: [String] = []
    private var exportNotice: String?
    private var calendarUnavailable = false
    static var clockCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    var month: Date { Self.clockCalendar.date(from: Self.clockCalendar.dateComponents([.year, .month], from: selectedDay))! }
    var transferActive: Bool { downloading || converting }
    var duration: TimeInterval { movie?.duration ?? 0 }
    var alignedExportRange: RecordingExportRange? {
        guard let movie else { return nil }
        return try? RecordingExportRange(start: intervalStart, end: intervalEnd, duration: movie.duration, keyframes: movie.keyframeTimes)
    }
    @ObservationIgnored private var backend: DVRIPRecordingClient?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var mediaCleanup: Task<Void, Never>?
    @ObservationIgnored private var cache: RecordingPrivateDirectory?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var exportSession: AVAssetExportSession?
    private var generation = UUID()
    private var queryID = UUID()
    private var playbackID = UUID()
    private var exportID = UUID()

    init(camera: Camera) {
        self.camera = camera; channel = max(0, camera.channel - 1); substream = camera.substream
        let local = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        selectedDay = Self.clockCalendar.date(from: local)!
    }
    func authenticate(_ credentials: Credentials) {
        disconnect()
        let client = DVRIPRecordingClient(host: camera.host, port: camera.controlPort,
                                          username: credentials.username, password: credentials.password)
        backend = client; connecting = true; error = nil
        connectionNotices = []; queryNotices = []; mediaNotices = []; exportNotice = nil; calendarUnavailable = false
        let stamp = generation, gate = cleanupTask
        queryTask = Task { [weak self] in
            await gate?.value
            do {
                try Task.checkCancellation()
                try await client.connect()
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                do {
                    let clock = try await client.cameraTime()
                    guard self.generation == stamp, !Task.isCancelled else { return }
                    self.cameraClock = clock; self.selectedDay = clock.dayStart.date
                } catch {
                    try Task.checkCancellation()
                    self.connectionNotices.append(String(localized: "Camera clock unavailable. Select the date using camera time."))
                }
                do {
                    let storage = try await client.storage()
                    guard self.generation == stamp, !Task.isCancelled else { return }
                    self.storage = storage
                }
                catch {
                    try Task.checkCancellation()
                    self.connectionNotices.append(String(localized: "Storage status unavailable. You can still search recordings."))
                }
                guard self.generation == stamp, !Task.isCancelled else { return }
                self.connected = true; self.connecting = false
                self.loadDay(self.selectedDay, refreshCalendar: true)
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.connecting = false; self.error = NSLocalizedString(error.localizedDescription, comment: "")
            }
        }
    }
    func loadDay(_ date: Date, refreshCalendar: Bool = false) {
        guard connected, !exporting, let client = backend, let day = CameraRecordingTime(date: Self.clockCalendar.startOfDay(for: date)) else { return }
        let changedMonth = Self.clockCalendar.dateComponents([.year, .month], from: selectedDay) != Self.clockCalendar.dateComponents([.year, .month], from: day.date)
        selectedDay = day.date; records = []; error = nil; queryNotices = []; exportNotice = nil
        if changedMonth || refreshCalendar { calendarDays = nil; calendarUnavailable = false }
        queryTask?.cancel(); let ticket = UUID(); queryID = ticket; querying = true
        retirePlayback()
        let gate = mediaCleanup, stamp = generation, channel = channel, substream = substream
        queryTask = Task { [weak self] in
            await gate?.value
            do {
                try Task.checkCancellation()
                try await client.connect()
                if changedMonth || refreshCalendar {
                    do {
                        let calendar = try await client.calendar(year: day.year, month: day.month)
                        guard let self, self.generation == stamp, self.queryID == ticket, !Task.isCancelled else { return }
                        self.calendarDays = calendar.days
                        self.calendarUnavailable = false
                    } catch {
                        try Task.checkCancellation()
                        guard let self, self.generation == stamp, self.queryID == ticket else { return }
                        self.calendarUnavailable = true
                    }
                }
                let listing = try await client.recordings(day: day, channel: channel, substream: substream)
                guard let self, self.generation == stamp, self.queryID == ticket, !Task.isCancelled else { return }
                self.records = listing.records; self.querying = false
                self.queryNotices = listing.warnings
                if !listing.complete { self.queryNotices.append(String(localized: "The camera returned a partial recording list. Some recordings may be missing.")) }
            } catch {
                guard let self, self.generation == stamp, self.queryID == ticket, !Task.isCancelled else { return }
                self.querying = false; self.error = NSLocalizedString(error.localizedDescription, comment: "")
            }
        }
    }
    func changeMonth(_ delta: Int) {
        guard let date = Self.clockCalendar.date(byAdding: .month, value: delta, to: month) else { return }
        loadDay(date, refreshCalendar: true)
    }
    func selectCameraTime(_ date: Date) {
        if let movie, let offset = movie.movieTime(for: date) { seek(offset); return }
        guard let recording = records.first(where: { $0.begin.date <= date && date < $0.end.date }) else {
            error = String(localized: "No recording covers this time. Select a recorded interval on the timeline."); return
        }
        if selectedRecording?.id == recording.id, movie != nil {
            error = String(localized: "The requested time falls in a gap in the downloaded recording.")
        } else { play(recording, at: date) }
    }
    func play(_ recording: CameraRecording, at date: Date? = nil) {
        guard connected, !exporting, let client = backend else { return }
        retirePlayback()
        let gate = mediaCleanup, ticket = UUID(), stamp = generation
        playbackID = ticket; selectedRecording = recording; downloading = true; receivedBytes = 0; error = nil
        playbackTask = Task { [weak self] in
            await gate?.value
            var directory: RecordingPrivateDirectory?
            do {
                try Task.checkCancellation()
                let prepared = try RecordingPrivateDirectory(); directory = prepared
                try prepared.checkSpace(estimatedBytes: recording.estimatedBytes)
                guard let self, self.generation == stamp, self.playbackID == ticket else { prepared.remove(); return }
                self.cache = prepared
                try await client.connect()
                try await client.download(recording: recording, to: prepared.rawURL) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == stamp, self.playbackID == ticket else { return }
                        self.receivedBytes = progress.receivedBytes
                    }
                }
                try Task.checkCancellation()
                guard self.generation == stamp, self.playbackID == ticket else { prepared.remove(); return }
                self.downloading = false; self.rawAvailable = true; self.converting = true
                let result = try await RecordingMovieWriter().convert(rawURL: prepared.rawURL, movieURL: prepared.movieURL)
                try Task.checkCancellation()
                guard self.generation == stamp, self.playbackID == ticket else { prepared.remove(); return }
                self.movie = result; self.converting = false; self.intervalStart = 0; self.intervalEnd = result.duration
                self.mediaNotices = result.notices.map { NSLocalizedString($0, comment: "") }
                let player = AVPlayer(url: result.url)
                self.player = player
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor in
                        guard let self, self.playbackID == ticket else { return }
                        self.position = time.seconds.isFinite ? max(0, time.seconds) : 0
                        self.cameraPosition = self.movie?.cameraTime(at: self.position)
                    }
                }
                if let date {
                    if let offset = result.movieTime(for: date) { self.seek(offset) }
                    else { self.error = String(localized: "The requested time falls in a gap in the downloaded recording.") }
                }
                player.playImmediately(atRate: self.playbackRate)
            } catch {
                guard let self, self.generation == stamp, self.playbackID == ticket, !Task.isCancelled else { directory?.remove(); return }
                self.downloading = false; self.converting = false; self.error = NSLocalizedString(error.localizedDescription, comment: "")
                // A complete raw download remains exportable when native conversion is unsupported.
                if !self.rawAvailable { directory?.remove(); self.cache = nil }
            }
        }
    }
    func cancelPlayback() { retirePlayback() }
    func seek(_ seconds: TimeInterval) {
        guard let movie, seconds.isFinite else { return }
        let target = min(max(0, seconds), movie.duration)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target; cameraPosition = movie.cameraTime(at: target)
    }
    func jump(_ delta: TimeInterval) { seek(position + delta) }
    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: playbackRate) }
    }
    func setRate(_ value: Float) {
        guard [Float(0.5), 1, 2, 4].contains(value) else { return }
        playbackRate = value
        if player?.rate ?? 0 > 0 { player?.playImmediately(atRate: value) }
    }
    func adjacent(_ direction: Int) {
        guard let id = selectedRecording?.id, let index = records.firstIndex(where: { $0.id == id }), records.indices.contains(index + direction) else { return }
        play(records[index + direction])
    }
    func exportOriginal(to destination: URL) {
        guard rawAvailable, !exporting, let source = cache?.rawURL else { return }
        exporting = true; error = nil
        let ticket = UUID(); exportID = ticket
        exportTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.exportID == ticket else { throw CancellationError() }
                try await Self.publishFile(source, to: destination)
                if self?.exportID == ticket { self?.exportNotice = String(localized: "Original camera file exported. This format may require a compatible player.") }
            } catch { if self?.exportID == ticket && !Task.isCancelled { self?.error = RecordingPresentationError.exportFailed.localizedDescription } }
            if self?.exportID == ticket { self?.exporting = false }
        }
    }
    func exportMovie(to destination: URL, interval: Bool) {
        guard !exporting, let movie, let range = interval ? alignedExportRange : try? RecordingExportRange(start: 0, end: movie.duration, duration: movie.duration, keyframes: movie.keyframeTimes) else { return }
        exporting = true; error = nil
        let ticket = UUID(); exportID = ticket
        exportTask = Task { [weak self] in
            let temporary = movie.url.deletingLastPathComponent().appendingPathComponent(".icsee-export-" + UUID().uuidString + ".mov")
            defer {
                try? FileManager.default.removeItem(at: temporary)
                if self?.exportID == ticket { self?.exportSession = nil; self?.exporting = false }
            }
            do {
                try Task.checkCancellation()
                guard self?.exportID == ticket else { throw CancellationError() }
                if !interval { try await Self.publishFile(movie.url, to: destination) }
                else {
                    guard let session = AVAssetExportSession(asset: AVURLAsset(url: movie.url), presetName: AVAssetExportPresetPassthrough) else { throw RecordingPresentationError.exportFailed }
                    guard self?.exportID == ticket else { throw CancellationError() }
                    self?.exportSession = session
                    session.outputURL = temporary; session.outputFileType = .mov
                    session.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), end: CMTime(seconds: range.end, preferredTimescale: 600))
                    await session.export()
                    try Task.checkCancellation()
                    guard session.status == .completed else { throw RecordingPresentationError.exportFailed }
                    try await Self.publishFile(temporary, to: destination)
                }
                if self?.exportID == ticket { self?.exportNotice = String(localized: "Recording exported.") }
            } catch { if self?.exportID == ticket && !Task.isCancelled { self?.error = RecordingPresentationError.exportFailed.localizedDescription } }
        }
    }
    nonisolated private static func publishFile(_ source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let copy = Task.detached(priority: .utility) {
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".icsee-copy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RecordingPresentationError.exportFailed }
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: staged)
            defer { try? input.close(); try? output.close() }
            while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
            else { try FileManager.default.moveItem(at: staged, to: destination) }
        }
        try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
    }
    private func retirePlayback() {
        playbackID = UUID(); playbackTask?.cancel()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player = nil; movie = nil; position = 0; cameraPosition = nil; rawAvailable = false
        downloading = false; converting = false; receivedBytes = 0; selectedRecording = nil
        mediaNotices = []; exportNotice = nil
        let oldTask = playbackTask, directory = cache, previous = mediaCleanup
        playbackTask = nil; cache = nil
        mediaCleanup = Task { await previous?.value; await oldTask?.value; directory?.remove() }
    }
    func disconnect() {
        generation = UUID(); queryID = UUID(); queryTask?.cancel()
        exportTask?.cancel(); exportSession?.cancelExport()
        exportID = UUID(); exporting = false; exportSession = nil
        retirePlayback()
        let client = backend, query = queryTask, media = mediaCleanup, export = exportTask, previous = cleanupTask
        backend = nil; queryTask = nil; exportTask = nil
        connected = false; connecting = false; querying = false; records = []; calendarDays = nil; storage = nil
        cleanupTask = Task {
            await previous?.value; await client?.disconnect(); await query?.value; await media?.value; await export?.value
        }
    }
    func shutdown() async { disconnect(); await cleanupTask?.value }
    func update(camera: Camera) {
        if self.camera.host != camera.host || self.camera.controlPort != camera.controlPort ||
            self.camera.channel != camera.channel || self.camera.substream != camera.substream {
            disconnect()
            channel = max(0, camera.channel - 1); substream = camera.substream
        }
        self.camera = camera
    }
}
