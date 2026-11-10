import Foundation
import Darwin

enum RemoteDecoderError: Error { case failed }

protocol RemoteDecoding: Sendable {
    var hasStarted: Bool { get }
    func write(codec: UInt8, data: Data) throws
    func stop()
}

final class RemoteDecoder: RemoteDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let width: Int
    private let fps: Int
    private let hardware: Bool
    private let onFrame: @Sendable (Data) -> Void
    private var process: Process?
    var hasStarted: Bool { lock.withLock { process != nil } }
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var format: UInt8?
    private var stopped = false

    init(width: Int, fps: Int, hardware: Bool = true, onFrame: @escaping @Sendable (Data) -> Void) {
        self.width = width; self.fps = fps; self.hardware = hardware; self.onFrame = onFrame
    }
    func write(codec: UInt8, data: Data) throws {
        guard (codec == 2 || codec == 3), (1...4096).contains(width), (1...60).contains(fps) else { throw RemoteProtocolError.invalidIdentifier }
        let writer: FileHandle = try lock.withLock {
            guard !stopped else { throw CancellationError() }
            if let format, format != codec { throw RemoteProtocolError.invalidResponse }
            if process == nil {
            let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path
            guard let executable = ([bundled].compactMap { $0 } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw RemoteProtocolError.unavailable }
            let child = Process(), source = Pipe(), output = Pipe()
            guard fcntl(source.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw RemoteProtocolError.unavailable }
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1"] + (hardware ? ["-hwaccel", "videotoolbox"] : []) + ["-f", codec == 2 ? "h264" : "hevc", "-i", "pipe:0", "-an", "-filter_threads", "1", "-vf", "fps=\(fps),scale=\(width):-2", "-threads", "1", "-q:v", "5", "-c:v", "mjpeg", "-f", "image2pipe", "pipe:1"]
            child.standardInput = source; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            try child.run()
            process = child; input = source.fileHandleForWriting; format = codec
            let handle = output.fileHandleForReading, callback = onFrame
            reader = Task.detached(priority: .userInitiated) {
                var parser = JPEGFramer()
                while !Task.isCancelled, let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    guard let frames = try? parser.append(chunk) else { break }
                    for frame in frames { callback(frame) }
                }
                try? handle.close()
            }
            }
            guard let input else { throw RemoteProtocolError.unavailable }
            return input
        }
        do { try writer.write(contentsOf: data) }
        catch { throw RemoteDecoderError.failed }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let child = process, handle = input, task = reader
        process = nil; input = nil; reader = nil
        lock.unlock()
        task?.cancel()
        if let child, child.isRunning { child.terminate() }
        try? handle?.close()
    }
}
