import AppKit
import Foundation
import Observation

enum CameraRenderProfile: Int, Comparable {
    case preview, grid, window
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var width: Int { switch self { case .preview: 480; case .grid: 800; case .window: 1280 } }
    var fps: Int { self == .window ? 15 : 5 }
}

@MainActor @Observable
final class CameraSession {
    enum State: Equatable {
        case stopped, suspended, connecting, live, failed(String)
        var label: String {
            switch self {
            case .stopped: String(localized: "Disconnected")
            case .suspended: String(localized: "Paused while hidden")
            case .connecting: String(localized: "Connecting…")
            case .live: String(localized: "Live")
            case .failed: String(localized: "Connection failed")
            }
        }
    }
    var state = State.stopped
    var image: NSImage?
    @ObservationIgnored var frames = 0
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var diagnosticReader: Task<DecoderFailure?, Never>?
    private var deadline: Task<Void, Never>?
    private var lastFrameAt: ContinuousClock.Instant?
    private var generation = UUID()
    @ObservationIgnored private var controlCredentials: Credentials?
    @ObservationIgnored private var viewers: [UUID: CameraRenderProfile] = [:]
    @ObservationIgnored private var request: (camera: Camera, credentials: Credentials, sofia: Bool, hardware: Bool)?
    @ObservationIgnored private var renderProfile: CameraRenderProfile?
    func credentialsForControls() -> Credentials? { controlCredentials }

    func start(camera: Camera, credentials: Credentials) {
        stop()
        request = (camera, credentials, false, true)
        controlCredentials = credentials
        reconcileViewers()
    }

    func updateViewer(_ id: UUID, profile: CameraRenderProfile?) {
        guard viewers[id] != profile else { return }
        viewers[id] = profile
        reconcileViewers()
    }

    private func reconcileViewers() {
        guard let request else { return }
        let wanted = viewers.values.max()
        guard wanted != renderProfile || (wanted == nil && state != .suspended) else { return }
        stopDecoder()
        guard let wanted else { state = .suspended; return }
        renderProfile = wanted
        launch(camera: request.camera, credentials: request.credentials, useSofiaQuery: request.sofia,
               hardware: request.hardware, profile: wanted)
    }

    private func launch(camera: Camera, credentials: Credentials, useSofiaQuery: Bool,
                        hardware: Bool, profile: CameraRenderProfile) {
        do {
            let playlist = try camera.endpoint.playlist(username: credentials.username, password: credentials.password, useSofiaQuery: useSofiaQuery)
            let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path
            guard let executable = ([bundled].compactMap { $0 } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                stop()
                state = .failed(String(localized: "FFmpeg was not found on this Mac."))
                return
            }
            let child = Process()
            let input = Pipe(), output = Pipe(), errors = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin",
                "-protocol_whitelist", "file,pipe,fd,rtp,rtsp,tcp,udp,crypto,http,https,tls",
                "-threads", "1"] + (hardware ? ["-hwaccel", "videotoolbox"] : []) + [
                "-f", "concat", "-safe", "0", "-i", "pipe:0", "-map", "0:v:0", "-an",
                "-filter_threads", "1", "-vf", (profile != .window ? "fps=\(profile.fps)," : "") + "scale=\(profile.width):-2",
                "-fpsmax", "\(profile.fps)",
                "-threads", "1", "-q:v", "5", "-c:v", "mjpeg", "-f", "image2pipe", "pipe:1"]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = errors
            try child.run()
            process = child
            controlCredentials = credentials
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
                } catch {}
                // Close stdout before waiting for stderr: a canceled reader can block FFmpeg's final JPEG flush.
                try? handle.close()
                await self?.ended(token: token, failure: diagnostics.value)
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
        if state != .live { state = .live }
        lastFrameAt = .now
    }
    private func ended(token: UUID, failure: DecoderFailure?) {
        guard generation == token else { return }
        if failure == .authentication, frames == 0, request?.sofia == false {
            request?.sofia = true
            stopDecoder()
            reconcileViewers()
            return
        }
        if failure == .hardwareUnavailable, frames == 0, request?.hardware == true {
            request?.hardware = false
            stopDecoder()
            reconcileViewers()
            return
        }
        stop()
        state = .failed(failure?.message ?? String(localized: "The camera ended the stream. Reconnect or select Substream in camera settings."))
    }
    func stop() {
        request = nil
        controlCredentials = nil
        stopDecoder()
        state = .stopped
    }
    private func stopDecoder() {
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
        renderProfile = nil
    }
}
