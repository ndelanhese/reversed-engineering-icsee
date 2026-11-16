import AppKit
import Foundation

private final class FakeStream: RemoteStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    func run(onFrame: (UInt8, Data) throws -> Void) throws {
        while !lock.withLock({ stopped }) {
            try onFrame(3, Data([1]))
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CancellationError()
    }
}

private final class RejectMainStream: RemoteStreaming, @unchecked Sendable {
    func cancel() { }
    func run(onFrame: (UInt8, Data) throws -> Void) throws { throw RemoteProtocolError.streamUnavailable }
}

private final class FakeDecoder: RemoteDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let output: Data?
    private let callback: @Sendable (Data) -> Void
    init(output: Data?, callback: @escaping @Sendable (Data) -> Void) { self.output = output; self.callback = callback }
    var hasStarted: Bool { lock.withLock { started } }
    func write(codec: UInt8, data: Data) throws {
        let first = lock.withLock { let wasStarted = started; started = true; return !wasStarted }
        if first, let output { callback(output) }
    }
    func stop() { }
}

@main struct RemoteSessionFallbackTest {
    @MainActor static func main() async throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else { exit(2) }
        let session = CameraSession()
        var attempts: [Bool] = []
        session.remoteStartupTimeoutForTesting = .seconds(1)
        session.remoteClientFactoryForTesting = { _ in FakeStream() }
        session.remoteDecoderFactoryForTesting = { hardware, callback in
            attempts.append(hardware)
            return FakeDecoder(output: hardware ? nil : jpeg, callback: callback)
        }
        let camera = Camera(name: "Fixture", host: "", remoteEnabled: true, remoteSerial: "1234567890abcdef")
        session.updateViewer(UUID(), profile: .grid)
        session.start(camera: camera, credentials: Credentials(username: "fixture", password: "fixture"))
        defer { session.stop() }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if session.state == .live {
                guard attempts == [true, false], session.image != nil else { exit(1) }
                print("PASS: remote silent hardware decoder falls back once to software")
                break
            }
        }
        guard session.state == .live else { print("FAIL: remote silent decoder did not fall back"); exit(1) }
        session.stop()
        let alternate = CameraSession()
        var streams: [Bool] = []
        alternate.remoteClientFactoryForTesting = { configuration in
            streams.append(configuration.substream)
            return configuration.substream ? FakeStream() : RejectMainStream()
        }
        alternate.remoteDecoderFactoryForTesting = { _, callback in FakeDecoder(output: jpeg, callback: callback) }
        alternate.updateViewer(UUID(), profile: .grid)
        alternate.start(camera: camera, credentials: Credentials(username: "fixture", password: "fixture"))
        defer { alternate.stop() }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if alternate.state == .live { break }
        }
        guard alternate.state == .live, streams == [false, true] else { print("FAIL: remote stream fallback", streams); exit(1) }
        print("PASS: remote switches to substream when main is unavailable")
        let failedDecoder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\ncat >/dev/null\necho connection refused >&2\n".utf8).write(to: failedDecoder)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedDecoder.path)
        defer { try? FileManager.default.removeItem(at: failedDecoder) }
        let blocked = CameraSession()
        blocked.localNetworkForTesting = true
        blocked.localExecutableForTesting = failedDecoder.path
        blocked.remoteClientFactoryForTesting = { _ in FakeStream() }
        blocked.remoteDecoderFactoryForTesting = { _, callback in FakeDecoder(output: jpeg, callback: callback) }
        let localCamera = Camera(name: "Blocked local", host: "127.0.0.1", port: 1, remoteEnabled: true, remoteSerial: "1234567890abcdef")
        blocked.updateViewer(UUID(), profile: .grid)
        blocked.start(camera: localCamera, credentials: Credentials(username: "fixture", password: "fixture"))
        defer { blocked.stop() }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if blocked.state == .live || { if case .failed = blocked.state { return true }; return false }() { break }
        }
        guard blocked.state == .live, blocked.usingRemote else { print("FAIL: local connection failure did not fall back to remote"); exit(1) }
        print("PASS: unreachable local camera falls back to remote")
        let localOnly = CameraSession()
        localOnly.localNetworkForTesting = true
        localOnly.localExecutableForTesting = failedDecoder.path
        var unexpectedRemote = false
        localOnly.remoteClientFactoryForTesting = { _ in unexpectedRemote = true; return FakeStream() }
        var localOnlyCamera = localCamera
        localOnlyCamera.remoteEnabled = false
        localOnly.updateViewer(UUID(), profile: .grid)
        localOnly.start(camera: localOnlyCamera, credentials: Credentials(username: "fixture", password: "fixture"))
        defer { localOnly.stop() }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            if case .failed = localOnly.state { break }
        }
        guard case .failed = localOnly.state, !unexpectedRemote else { print("FAIL: local-only camera attempted remote"); exit(1) }
        print("PASS: local-only camera never falls back to remote")
    }
}
