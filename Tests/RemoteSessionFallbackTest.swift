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
                return
            }
        }
        print("FAIL: remote silent decoder did not fall back")
        exit(1)
    }
}
