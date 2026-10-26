import Foundation

enum RecordingMediaError: Error, Equatable, LocalizedError {
    case invalidHeader, frameTooLarge, truncated, invalidClock, invalidFrameRate
    case configurationChanged, backwardClock, unsupportedVideo, reorderedVideo, invalidNAL
    case missingParameters, noVideo, outputExists, writerFailed, timedOut, busy, recordingTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidHeader, .truncated, .invalidNAL: "The recording contains malformed or incomplete media. The original file is still available."
        case .frameTooLarge: "A recording frame exceeds the supported size limit."
        case .invalidClock, .backwardClock: "The recording has invalid or backward camera timestamps."
        case .invalidFrameRate: "The recording does not declare a valid frame rate."
        case .configurationChanged: "The recording changes video or audio configuration. Export the original file instead."
        case .unsupportedVideo: "This recording's video codec is not supported for native playback."
        case .reorderedVideo: "This recording requires frame reordering, but camera media does not provide decode timestamps."
        case .missingParameters: "The recording has no complete video decoder configuration."
        case .noVideo: "The recording contains no decodable video."
        case .outputExists: "The movie destination already exists."
        case .writerFailed: "The system could not create a playable movie. The original file is still available."
        case .timedOut: "Movie conversion exceeded its processing deadline."
        case .busy: "A recording conversion is already running."
        case .recordingTooLarge: "The recording exceeds the supported conversion size or duration. Export the original file instead."
        }
    }
}

enum RecordingMediaKind: UInt8, Sendable { case key = 0xFC, delta = 0xFD, picture = 0xFE, audio = 0xFA, info = 0xF9 }

struct RecordingMediaFrame: Sendable, Equatable {
    let kind: RecordingMediaKind
    let codec: UInt8
    let fps: Int
    let width: Int
    let height: Int
    /// Camera-local components represented in a fixed UTC calendar, never an actual UTC claim.
    let cameraTime: Date?
    let sampleRate: Int
    let payload: Data
}

/// Strict file parser: corruption is reported, never hidden by scanning for another start code.
struct RecordingMediaParser {
    private var buffer = Data()
    private var configuration: (codec: UInt8, fps: Int, width: Int, height: Int)?
    private let maximumFrameBytes: Int
    init(maximumFrameBytes: Int = 16 * 1024 * 1024) { self.maximumFrameBytes = max(1, maximumFrameBytes) }

    mutating func append(_ data: Data) throws -> [RecordingMediaFrame] {
        var frames: [RecordingMediaFrame] = []
        var offset = 0
        while offset < data.count {
            let count = min(64 * 1024, data.count - offset)
            buffer.append(data[data.startIndex + offset..<data.startIndex + offset + count])
            offset += count
            while let frame = try next() { frames.append(frame) }
            guard buffer.count <= maximumFrameBytes + 16 else { throw RecordingMediaError.frameTooLarge }
        }
        return frames
    }

    func finish() throws { if !buffer.isEmpty { throw RecordingMediaError.truncated } }

    private mutating func next() throws -> RecordingMediaFrame? {
        guard buffer.count >= 4 else { return nil }
        // Rebase after consuming data: Data slices need not begin at index zero.
        let b = [UInt8](buffer.prefix(16))
        guard b[0] == 0, b[1] == 0, b[2] == 1, let kind = RecordingMediaKind(rawValue: b[3]) else { throw RecordingMediaError.invalidHeader }
        let headerSize = (kind == .key || kind == .picture) ? 16 : 8
        guard b.count >= headerSize else { return nil }
        let length: Int
        if headerSize == 16 { length = Int(Self.uint32(b, 12)) }
        else if kind == .delta { length = Int(Self.uint32(b, 4)) }
        else { length = Int(b[6]) | Int(b[7]) << 8 }
        guard length <= maximumFrameBytes else { throw RecordingMediaError.frameTooLarge }
        guard length > 0 else { throw RecordingMediaError.invalidHeader }
        guard buffer.count >= headerSize + length else { return nil }
        let payload = Data(buffer.dropFirst(headerSize).prefix(length))
        buffer = Data(buffer.dropFirst(headerSize + length))
        var codec: UInt8 = 0, fps = 0, width = 0, height = 0, sampleRate = 0
        var time: Date?
        if headerSize == 16 {
            codec = b[4] & 15
            fps = Int(b[5] & 31)
            guard fps > 0 && fps <= 30 else { throw RecordingMediaError.invalidFrameRate }
            width = (Int((b[4] >> 4) & 3) << 8 | Int(b[6])) * 8
            height = (Int((b[4] >> 6) & 3) << 8 | Int(b[7])) * 8
            guard width > 0 && height > 0 else { throw RecordingMediaError.invalidHeader }
            time = try Self.cameraDate(Self.uint32(b, 8))
            if kind == .key {
                if let c = configuration, c.codec != codec || c.fps != fps || c.width != width || c.height != height { throw RecordingMediaError.configurationChanged }
                configuration = (codec, fps, width, height)
            }
        } else if kind == .delta, let c = configuration {
            codec = c.codec; fps = c.fps; width = c.width; height = c.height
        } else if kind == .audio {
            codec = b[4] & 15
            sampleRate = b[5] == 2 ? 8000 : 0
        }
        return RecordingMediaFrame(kind: kind, codec: codec, fps: fps, width: width, height: height, cameraTime: time, sampleRate: sampleRate, payload: payload)
    }

    static func frame(_ data: Data) throws -> RecordingMediaFrame {
        var parser = RecordingMediaParser()
        let frames = try parser.append(data)
        try parser.finish()
        guard frames.count == 1, let frame = frames.first else { throw RecordingMediaError.invalidHeader }
        return frame
    }

    private static func uint32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
    private static func cameraDate(_ packed: UInt32) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: 2000 + Int(packed >> 26), month: Int(packed >> 22 & 15), day: Int(packed >> 17 & 31), hour: Int(packed >> 12 & 31), minute: Int(packed >> 6 & 63), second: Int(packed & 63))
        guard let date = calendar.date(from: parts), calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date) == parts else { throw RecordingMediaError.invalidClock }
        return date
    }
}

struct RecordingTimeMapping: Sendable, Equatable {
    let movieOffset: TimeInterval
    let cameraStart: Date
    var duration: TimeInterval
}

enum RecordingAudioStatus: Sendable, Equatable {
    case none
    /// AAC is present; arrival order and sample counts infer its alignment to video.
    case inferredAlignment
    case unsupported
}

struct MovieResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let cameraOrigin: Date
    let mappingSegments: [RecordingTimeMapping]
    let keyframeTimes: [TimeInterval]
    let audioStatus: RecordingAudioStatus
    let notices: [String]

    func cameraTime(at movieTime: TimeInterval) -> Date? {
        guard movieTime.isFinite else { return nil }
        for segment in mappingSegments where movieTime >= segment.movieOffset && movieTime < segment.movieOffset + segment.duration {
            return segment.cameraStart.addingTimeInterval(movieTime - segment.movieOffset)
        }
        return nil
    }
    func movieTime(for cameraTime: Date) -> TimeInterval? {
        for segment in mappingSegments {
            let delta = cameraTime.timeIntervalSince(segment.cameraStart)
            if delta >= 0 && delta < segment.duration { return segment.movieOffset + delta }
        }
        return nil
    }
}

/// A whole-second stamp specifies [second, second+1). Keep the declared cadence
/// inside that interval; a later second creates an explicit gap, never a backwards PTS.
struct RecordingMediaClock {
    private(set) var origin: Date?
    private(set) var mappingSegments: [RecordingTimeMapping] = []
    private(set) var keyframeTimes: [TimeInterval] = []
    private(set) var duration: TimeInterval = 0
    private var lastKey: Date?
    private var nextTime: TimeInterval = 0
    private var sampleCount = 0
    mutating func stamp(_ frame: RecordingMediaFrame) throws -> TimeInterval {
        guard sampleCount < 2_000_000, keyframeTimes.count < 200_000, mappingSegments.count < 50_000 else { throw RecordingMediaError.recordingTooLarge }
        sampleCount += 1
        guard frame.kind == .key || frame.kind == .delta, frame.fps > 0 else { throw RecordingMediaError.invalidFrameRate }
        let period = 1 / Double(frame.fps)
        var time = nextTime
        if frame.kind == .key {
            guard let key = frame.cameraTime else { throw RecordingMediaError.invalidClock }
            if origin == nil { origin = key }
            if let lastKey, key < lastKey { throw RecordingMediaError.backwardClock }
            let target = key.timeIntervalSince(origin!)
            guard time < target + 1 - 0.000_001 else { throw RecordingMediaError.backwardClock }
            if mappingSegments.isEmpty || target > time + 0.000_001 {
                time = target
                mappingSegments.append(RecordingTimeMapping(movieOffset: time, cameraStart: key, duration: 0))
            }
            lastKey = key
            keyframeTimes.append(time)
        }
        guard !mappingSegments.isEmpty else { throw RecordingMediaError.missingParameters }
        let last = mappingSegments.count - 1
        mappingSegments[last].duration = time + period - mappingSegments[last].movieOffset
        nextTime = time + period
        duration = nextTime
        return time
    }
}

enum G711 {
    static func decode(_ code: UInt8, codec: UInt8) -> Int16 {
        if codec == 14 {
            let value = Int(code ^ 0x55)
            let exponent = (value >> 4) & 7
            var magnitude = (value & 15) << 4
            magnitude += exponent == 0 ? 8 : 264
            if exponent > 1 { magnitude <<= exponent - 1 }
            return Int16(value & 128 == 0 ? -magnitude : magnitude)
        }
        let value = Int(~code)
        let magnitude = (((value & 15) << 3) + 132) << ((value >> 4) & 7)
        return Int16(value & 128 == 0 ? magnitude - 132 : 132 - magnitude)
    }
}
