import AppKit
import Foundation
import Observation

@MainActor @Observable
final class CameraSession {
    enum State: Equatable {
        case stopped, connecting, live, failed(String)
        var label: String {
            switch self {
            case .stopped: String(localized: "Disconnected")
            case .connecting: String(localized: "Connecting…")
            case .live: String(localized: "Live")
            case .failed: String(localized: "Connection failed")
            }
        }
    }
    var state = State.stopped
    var image: NSImage?
    var frames = 0
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var diagnosticReader: Task<DecoderFailure?, Never>?
    private var deadline: Task<Void, Never>?
    private var lastFrameAt: ContinuousClock.Instant?
    private var generation = UUID()

    func start(camera: Camera, credentials: Credentials) {
        start(camera: camera, credentials: credentials, useSofiaQuery: false)
    }

    private func start(camera: Camera, credentials: Credentials, useSofiaQuery: Bool) {
        stop()
        do {
            let playlist = try camera.endpoint.playlist(username: credentials.username, password: credentials.password, useSofiaQuery: useSofiaQuery)
            let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path
            guard let executable = ([bundled].compactMap { $0 } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                state = .failed(String(localized: "FFmpeg was not found on this Mac."))
                return
            }
            let child = Process()
            let input = Pipe(), output = Pipe(), errors = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                "-protocol_whitelist", "file,pipe,fd,rtp,rtsp,tcp,udp,crypto,http,https,tls",
                "-f", "concat", "-safe", "0", "-i", "pipe:0", "-map", "0:v:0", "-an",
                "-vf", "scale=1280:-2", "-fpsmax", "15", "-q:v", "5", "-c:v", "mjpeg", "-f", "image2pipe", "pipe:1"]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = errors
            try child.run()
            process = child
            state = .connecting
            let token = generation
            try input.fileHandleForWriting.write(contentsOf: playlist)
            try input.fileHandleForWriting.close()
            let errorHandle = errors.fileHandleForReading
            let diagnostics = Task.detached(priority: .utility) {
                var result = DecoderDiagnostics()
                while let chunk = try? errorHandle.read(upToCount: 4096), !chunk.isEmpty {
                    result.consume(chunk)
                }
                try? errorHandle.close()
                return result.failure
            }
            diagnosticReader = diagnostics
            let handle = output.fileHandleForReading
            reader = Task.detached(priority: .userInitiated) { [weak self] in
                var parser = JPEGFramer()
                do {
                    while !Task.isCancelled, let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                        for frame in try parser.append(chunk) {
                            await self?.receive(frame, token: token)
                        }
                    }
                    await self?.ended(token: token, failure: diagnostics.value, camera: camera,
                                      credentials: credentials, canRetryCompatibility: !useSofiaQuery)
                } catch {
                    await self?.ended(token: token, failure: diagnostics.value, camera: camera,
                                      credentials: credentials, canRetryCompatibility: !useSofiaQuery)
                }
                try? handle.close()
            }
            deadline = Task { [weak self] in
                let started = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    let now = ContinuousClock.now
                    if streamHasTimedOut(elapsed: started.duration(to: now),
                                         sinceLastFrame: self.lastFrameAt.map { $0.duration(to: now) }) {
                        self.stop()
                        self.state = .failed(String(localized: "The camera stopped sending video. Check the network and credentials, then reconnect."))
                        return
                    }
                }
            }
        } catch {
            stop()
            state = .failed(error.localizedDescription)
        }
    }

    private func receive(_ data: Data, token: UUID) {
        guard generation == token, let next = NSImage(data: data) else { return }
        image = next
        frames += 1
        state = .live
        lastFrameAt = .now
    }
    private func ended(token: UUID, failure: DecoderFailure?, camera: Camera,
                       credentials: Credentials, canRetryCompatibility: Bool) {
        guard generation == token else { return }
        if failure == .authentication, frames == 0, canRetryCompatibility {
            start(camera: camera, credentials: credentials, useSofiaQuery: true)
            return
        }
        stop()
        state = .failed(failure?.message ?? String(localized: "The camera ended the stream. Reconnect or select Substream in camera settings."))
    }
    func stop() {
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        reader?.cancel()
        reader = nil
        diagnosticReader?.cancel()
        diagnosticReader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        image = nil
        frames = 0
        lastFrameAt = nil
        state = .stopped
    }
}
