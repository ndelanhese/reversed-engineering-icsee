import AppKit
@preconcurrency import AVFoundation

@main enum CameraRecordingsTest {
    enum Failure: Error { case failed(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw Failure.failed("Timeout: " + message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() {
        if CommandLine.arguments.contains("--window") {
            _ = NSApplication.shared; NSApp.setActivationPolicy(.regular)
            Task { @MainActor in await execute(); NSApp.stop(nil); exit(0) }
            NSApp.run()
        } else { Task { @MainActor in await execute(); exit(0) }; RunLoop.main.run() }
    }
    @MainActor static func execute() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count >= 2, let port = Int(CommandLine.arguments[1]) else { throw Failure.failed("Synthetic peer port required") }
        let camera = Camera(name: "Synthetic recordings", host: "127.0.0.1", controlPort: port)
        let suite = "synthetic-recordings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([camera]), forKey: "cameras")
        let store = CameraStore(defaults: defaults), windows = CameraWindows()
        let live = store.session(camera); live.state = .live; live.frames = 7
        let useWindow = CommandLine.arguments.contains("--window")
        let cacheBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheBase, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: cacheBase) }
        let model: CameraRecordingsModel
        if useWindow {
            guard let opened = windows.openRecordings(camera: camera, store: store) else { throw Failure.failed("Window missing") }
            model = opened
            try check(windows.openRecordings(camera: camera, store: store) === model, "One model/window per camera")
        } else { model = CameraRecordingsModel(camera: camera, cacheBaseURL: cacheBase) }
        model.authenticate(Credentials(username: "fixture", password: UUID().uuidString))
        try await wait("recording discovery") { model.connected && !model.querying && model.records.count == 2 }
        try check(model.error == nil && model.calendarDays == [25], "Calendar/status query")
        try check(model.notices.contains { $0.contains("partial") }, "Partial listing disclosed")
        try check(model.cameraClock?.wire == "2026-10-25 00:01:03", "Camera clock preserved")
        let day = model.selectedDay
        if CommandLine.arguments.contains("--failure") {
            model.play(model.records[0])
            try await wait("invalid media cleanup") { !model.transferActive && model.error != nil }
            try check(model.movie == nil && !model.rawAvailable, "Failed playback never retains a cache entry")
            let failedCache = try FileManager.default.contentsOfDirectory(atPath: cacheBase.path)
            try check(failedCache.isEmpty, "Failed playback removes all temporary files")
            let saved = cacheBase.appendingPathComponent("explicit-original.xm")
            model.exportOriginal(to: saved)
            try await wait("explicit original redownload") { !model.exporting }
            try check(FileManager.default.fileExists(atPath: saved.path), "Explicit Save can download original after conversion failure")
            let exportedCache = try FileManager.default.contentsOfDirectory(atPath: cacheBase.path)
            try check(exportedCache == ["explicit-original.xm"], "Explicit export leaves only selected saved file")
            let cancelled = cacheBase.appendingPathComponent("cancelled-original.xm")
            model.exportOriginal(to: cancelled)
            model.disconnect(); await model.shutdown()
            try check(!FileManager.default.fileExists(atPath: cancelled.path), "Queued original export cannot start after disconnect")
            try check(FileManager.default.fileExists(atPath: saved.path), "Cleanup preserves explicit Save")
            try check(live.state == .live, "Failure/export cleanup preserves live session")
            print("PASS: failed playback deletes cache, explicit Save redownloads original, cancellation preserves saved files")
            return
        }
        model.selectCameraTime(day.addingTimeInterval(30))
        try check(model.error != nil && model.selectedRecording == nil, "Gap never silently selects footage")
        model.play(model.records[0], at: day.addingTimeInterval(1.5))
        try await wait("native movie") { model.movie != nil || (!model.transferActive && model.error != nil) }
        guard let movie = model.movie else { throw Failure.failed("Movie unavailable: " + (model.error ?? "unknown")) }
        try check(abs(movie.duration - 3) < 0.1 && model.rawAvailable && model.player != nil, "Download/native playback")
        let privateDirectory = movie.url.deletingLastPathComponent()
        let mediaNotices = Set(model.notices)
        try check(!mediaNotices.isEmpty, "Media timing/audio disclosure")
        model.setRate(2); model.jump(-15)
        try check(model.playbackRate == 2 && model.position == 0, "Seek/rate clamp")
        let exports = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exports) }
        model.intervalStart = 0.5; model.intervalEnd = 1.5
        let cut = exports.appendingPathComponent("interval.mov")
        model.exportMovie(to: cut, interval: true)
        try await wait("interval export") { !model.exporting }
        try check(FileManager.default.fileExists(atPath: cut.path), "Movie interval exported")
        try check(mediaNotices.isSubset(of: Set(model.notices)), "Export retains media timing/audio disclosure")
        let cutDuration = try await AVURLAsset(url: cut).load(.duration).seconds
        try check(abs(cutDuration - 2) < 0.15, "Keyframe aligned interval bounds")
        let raw = exports.appendingPathComponent("original.xm")
        model.exportOriginal(to: raw)
        try await wait("raw export") { !model.exporting }
        try check(FileManager.default.fileExists(atPath: raw.path), "Original export")
        let cancelled = exports.appendingPathComponent("cancelled.mov")
        model.exportMovie(to: cancelled, interval: true)
        model.disconnect()
        await model.shutdown()
        try check(!FileManager.default.fileExists(atPath: cancelled.path) && !model.exporting, "Queued export cannot restart after disconnect")
        model.authenticate(Credentials(username: "fixture", password: UUID().uuidString))
        try await wait("reauthenticated history") { model.connected && !model.querying && model.records.count == 2 }
        model.play(model.records[1])
        do { try await wait("slow download") { model.downloading && model.receivedBytes > 0 } }
        catch { throw Failure.failed("Slow download state: downloading=\(model.downloading), converting=\(model.converting), error=\(model.error ?? "none")") }
        model.loadDay(day.addingTimeInterval(86400))
        try await wait("day switch cancellation") { !model.querying && model.records.isEmpty && !model.transferActive }
        try check(!FileManager.default.fileExists(atPath: privateDirectory.path), "Old private cache removed")
        try check(!model.notices.contains { $0.contains("partial") }, "Old day query warning cleared")
        try check(live.state == .live && live.frames == 7, "Live session independent")
        var changed = camera; changed.channel = 2; changed.substream = true
        model.update(camera: changed)
        try check(!model.connected && model.channel == 1 && model.substream && model.player == nil, "Edited camera selection retires old work")
        if useWindow { windows.closeRecordings(camera.id); await windows.prepareForTermination() }
        else { await model.shutdown() }
        try check(live.state == .live, "Close does not stop live session")
        print("PASS: native recording calendar, gaps, download, playback, seek/rate, original/interval export, cancellation and independent live session")
    }
}
