import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia

/// Owns only a randomly named partial movie. Input and caller-owned files are never removed.
actor RecordingMovieWriter {
    private var converting = false
    private var active: (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?, audioFormat: CMAudioFormatDescription?, videoFormat: CMVideoFormatDescription)?
    private let maximumInputBytes: UInt64
    init(maximumInputBytes: UInt64 = 2 * 1024 * 1024 * 1024) { self.maximumInputBytes = maximumInputBytes }

    func convert(rawURL: URL, movieURL: URL) async throws -> MovieResult {
        guard !converting else { throw RecordingMediaError.busy }
        converting = true
        defer { converting = false }
        try Task.checkCancellation()
        let files = FileManager.default
        guard !files.fileExists(atPath: movieURL.path) else { throw RecordingMediaError.outputExists }
        let partial = movieURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.mov")
        defer { try? files.removeItem(at: partial) }
        let deadline = Date().addingTimeInterval(30 * 60)
        var scan = RecordingMovieScan()
        try await frames(rawURL, deadline: deadline) { frame in try scan.consume(frame) }
        guard let format = scan.format, let origin = scan.clock.origin, scan.clock.duration > 0 else { throw RecordingMediaError.noVideo }
        let setup = try Self.startWriter(url: partial, format: format, audioRequested: scan.hasAudioAfterStart && !scan.unsupportedAudio)
        let (writer, video, audio, audioFormat) = setup
        active = (writer, video, audio, audioFormat, format)
        defer { active = nil }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let audioStatus: RecordingAudioStatus = audio != nil ? .inferredAlignment : scan.hasAudio ? .unsupported : .none
        if files.fileExists(atPath: partial.path) { try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path) }
        // Each input must make progress independently: AVAssetWriter can withhold
        // video readiness while its audio encoder needs more input (and vice versa).
        // Separate bounded file readers avoid an unbounded queue or interleave deadlock.
        async let videoWork: Void = writeVideo(rawURL, deadline: deadline)
        try await writeAudio(rawURL, deadline: deadline)
        try await videoWork
        // Keep the movie's bound at the last declared video frame; unmatched tail
        // audio is not evidence that a recording contains more video.
        writer.endSession(atSourceTime: Self.time(scan.clock.duration))
        writer.finishWriting {}
        let finishDeadline = min(deadline, Date().addingTimeInterval(30))
        while writer.status == .writing {
            try Task.checkCancellation()
            guard Date() < finishDeadline else { writer.cancelWriting(); throw RecordingMediaError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard writer.status == .completed else { throw RecordingMediaError.writerFailed }
        try Task.checkCancellation()
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        let asset = AVURLAsset(url: partial)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        guard playable, duration.isFinite, duration > 0, abs(duration - scan.clock.duration) < 0.05 else { throw RecordingMediaError.writerFailed }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if audioStatus == .inferredAlignment && tracks.isEmpty { throw RecordingMediaError.writerFailed }
        try await validateDecodedVideo(asset, expectedFrames: scan.videoSampleCount, deadline: deadline)
        try Task.checkCancellation()
        // FileManager move fails if a different task created the target during conversion.
        try files.moveItem(at: partial, to: movieURL)
        var notices = ["Video frame times are estimated from declared FPS and whole-second camera keyframe timestamps; original high-resolution PTS/DTS are unavailable."]
        if scan.clock.mappingSegments.count > 1 { notices.append("Camera timestamp gaps are preserved. Playback may hold the preceding image during a gap.") }
        if scan.skippedLeadingVideo { notices.append("Playback begins at the first independently decodable keyframe, which can be later than the recording's listed start time.") }
        if audioStatus == .inferredAlignment { notices.append("Audio is present as AAC. Its alignment is inferred from packet order and sample counts because XM audio has no absolute timestamps.") }
        if audioStatus == .unsupported { notices.append("Audio is unsupported or the platform audio encoder is unavailable. This movie contains video only; export the original file to retain its audio data.") }
        return MovieResult(url: movieURL, duration: duration, cameraOrigin: origin, mappingSegments: scan.clock.mappingSegments, keyframeTimes: scan.clock.keyframeTimes, audioStatus: audioStatus, notices: notices)
    }

    private func validateDecodedVideo(_ asset: AVURLAsset, expectedFrames: Int, deadline: Date) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw RecordingMediaError.invalidNAL }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingMediaError.invalidNAL }
        reader.add(output)
        guard reader.startReading() else { throw RecordingMediaError.invalidNAL }
        let cancellation = RecordingDecodeCancellation(reader: reader, deadline: deadline)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.setEventHandler { cancellation.checkDeadline() }
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.resume()
        defer { watchdog.cancel(); cancellation.close() }
        var count = 0
        var lastTime = -Double.infinity
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                guard Date() < deadline, !cancellation.timedOut else { throw RecordingMediaError.timedOut }
                let hadSample = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    if CMSampleBufferGetNumSamples(sample) == 0 { return true }
                    guard CMSampleBufferGetNumSamples(sample) == 1, CMSampleBufferGetImageBuffer(sample) != nil else { throw RecordingMediaError.invalidNAL }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard time.isFinite, time > lastTime, count < expectedFrames else { throw RecordingMediaError.invalidNAL }
                    lastTime = time
                    count += 1
                    return true
                }
                cancellation.madeProgress()
                if !hadSample { break }
                await Task.yield()
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        guard !cancellation.timedOut else { throw RecordingMediaError.timedOut }
        guard reader.status == .completed, count == expectedFrames else { throw RecordingMediaError.invalidNAL }
    }

    private static func startWriter(url: URL, format: CMVideoFormatDescription, audioRequested: Bool) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?, CMAudioFormatDescription?) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else { throw RecordingMediaError.unsupportedVideo }
        writer.add(video)
        var audio: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if audioRequested {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 12000]
            if writer.canApply(outputSettings: settings, forMediaType: .audio), let pcm = try? pcmFormat() {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: pcm)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) { writer.add(input); audio = input; audioFormat = pcm }
            }
        }
        guard writer.startWriting() else {
            // canApply only validates settings; some systems reject their encoder
            // when it is started. Retry this owned partial as explicit video only.
            if audio != nil {
                try? FileManager.default.removeItem(at: url)
                return try startWriter(url: url, format: format, audioRequested: false)
            }
            throw RecordingMediaError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)
        return (writer, video, audio, audioFormat)
    }

    private func writeVideo(_ rawURL: URL, deadline: Date) async throws {
        guard let active else { throw RecordingMediaError.writerFailed }
        var state = RecordingMovieScan()
        try await frames(rawURL, deadline: deadline) { frame in
            guard let sample = try state.consume(frame) else { return }
            let buffer = try Self.videoSample(sample.bytes, format: active.videoFormat, time: state.lastTime, duration: 1 / Double(frame.fps), sync: sample.sync)
            try await append(buffer, to: active.video, writer: active.writer, deadline: deadline)
        }
        active.video.markAsFinished()
    }

    private func writeAudio(_ rawURL: URL, deadline: Date) async throws {
        guard let active, let input = active.audio, let format = active.audioFormat else { return }
        var state = RecordingMovieScan()
        var nextTime: Double?
        var segmentCount = 0
        try await frames(rawURL, deadline: deadline) { frame in
            _ = try state.consume(frame)
            guard frame.kind == .audio, state.started else { return }
            // XM audio has no timestamps. Infer a first position from packet order,
            // then count PCM samples, starting another run across a camera gap.
            var time = nextTime ?? state.lastTime
            if state.clock.mappingSegments.count != segmentCount { time = max(time, state.lastTime) }
            segmentCount = state.clock.mappingSegments.count
            let buffer = try Self.audioSample(Self.decodeAudio(frame.payload, codec: frame.codec), format: format, time: time)
            try await append(buffer, to: input, writer: active.writer, deadline: deadline)
            nextTime = time + Double(frame.payload.count) / 8000
        }
        input.markAsFinished()
    }

    private func frames(_ url: URL, deadline: Date, consume: (RecordingMediaFrame) async throws -> Void) async throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var parser = RecordingMediaParser()
        var bytes: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RecordingMediaError.timedOut }
            guard let data = try file.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            bytes += UInt64(data.count)
            guard bytes <= maximumInputBytes else { throw RecordingMediaError.recordingTooLarge }
            for frame in try parser.append(data) { try await consume(frame) }
            await Task.yield()
        }
        try parser.finish()
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, writer: AVAssetWriter, deadline: Date) async throws {
        let waitDeadline = min(deadline, Date().addingTimeInterval(30))
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw RecordingMediaError.writerFailed }
            guard Date() < waitDeadline else { throw RecordingMediaError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        guard input.append(sample) else { throw RecordingMediaError.writerFailed }
    }
    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600_000) }
    private static func block(_ data: Data) throws -> CMBlockBuffer {
        var result: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &result) == noErr, let result else { throw RecordingMediaError.writerFailed }
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: result, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw RecordingMediaError.writerFailed }
        return result
    }
    private static func videoSample(_ bytes: Data, format: CMVideoFormatDescription, time: Double, duration: Double, sync: Bool) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: Self.time(duration), presentationTimeStamp: Self.time(time), decodeTimeStamp: .invalid)
        var size = bytes.count
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try block(bytes), formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result) == noErr, let result else { throw RecordingMediaError.writerFailed }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true), CFArrayGetCount(attachments) == 1 else { throw RecordingMediaError.writerFailed }
        // Use CoreFoundation mutation directly: bridging the array to Swift
        // dictionaries can create copies and silently mark every sample as sync.
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        let value = Unmanaged.passUnretained(sync ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
        CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), value)
        CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(), value)
        return result
    }
    private static func pcmFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var result: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &result) == noErr, let result else { throw RecordingMediaError.writerFailed }
        return result
    }
    private static func decodeAudio(_ data: Data, codec: UInt8) -> Data {
        var bytes = Data(capacity: data.count * 2)
        for code in data {
            let sample = UInt16(bitPattern: G711.decode(code, codec: codec))
            bytes.append(UInt8(truncatingIfNeeded: sample)); bytes.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return bytes
    }
    private static func audioSample(_ pcm: Data, format: CMAudioFormatDescription, time: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 8000), presentationTimeStamp: Self.time(time), decodeTimeStamp: .invalid)
        var sampleSize = 2
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try block(pcm), formatDescription: format, sampleCount: pcm.count / 2, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &result)
        guard status == noErr, let result else { throw RecordingMediaError.writerFailed }
        return result
    }
}

/// A narrow cancellation bridge for AVAssetReader's synchronous decode call.
/// Only cancelReading crosses executors; native decoding and all other reader
/// operations remain on RecordingMovieWriter. The lock serializes cancellation,
/// progress and teardown so a late timer/cancellation cannot touch a closed reader.
private final class RecordingDecodeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private let deadline: Date
    private var lastProgress = Date()
    private var expired = false
    init(reader: AVAssetReader, deadline: Date) { self.reader = reader; self.deadline = deadline }
    var timedOut: Bool { lock.withLock { expired } }
    func madeProgress() { lock.withLock { lastProgress = Date() } }
    func cancel() { lock.withLock { reader?.cancelReading(); reader = nil } }
    func close() { lock.withLock { reader = nil } }
    func checkDeadline() {
        lock.withLock {
            guard let reader else { return }
            let now = Date()
            if now >= deadline || now.timeIntervalSince(lastProgress) >= 30 {
                expired = true
                reader.cancelReading()
                self.reader = nil
            }
        }
    }
}

private struct RecordingMovieScan {
    var configuration = RecordingNALConfiguration()
    var clock = RecordingMediaClock()
    var format: CMVideoFormatDescription?
    var started = false
    var skippedLeadingVideo = false
    var lastTime = 0.0
    var hasAudio = false
    var videoSampleCount = 0
    var hasAudioAfterStart = false
    var unsupportedAudio = false
    private var audioConfiguration: (UInt8, Int)?

    @discardableResult mutating func consume(_ frame: RecordingMediaFrame) throws -> RecordingCompressedSample? {
        if frame.kind == .picture { throw RecordingMediaError.unsupportedVideo }
        if frame.kind == .audio {
            hasAudio = true
            hasAudioAfterStart = hasAudioAfterStart || started
            if ![10,14].contains(frame.codec) || frame.sampleRate != 8000 { unsupportedAudio = true }
            if let old = audioConfiguration, old.0 != frame.codec || old.1 != frame.sampleRate { unsupportedAudio = true }
            audioConfiguration = (frame.codec, frame.sampleRate)
            return nil
        }
        guard frame.kind == .key || frame.kind == .delta else { return nil }
        guard frame.codec == 2 || frame.codec == 3 else {
            if frame.kind == .delta && !started { skippedLeadingVideo = true; return nil }
            throw RecordingMediaError.unsupportedVideo
        }
        let sample = try configuration.consume(frame.payload, codec: frame.codec)
        if !started {
            guard frame.kind == .key, sample.sync, configuration.complete else { skippedLeadingVideo = true; return nil }
            format = try configuration.formatDescription()
            let dimensions = CMVideoFormatDescriptionGetDimensions(format!)
            guard dimensions.width == frame.width, dimensions.height == frame.height else { throw RecordingMediaError.configurationChanged }
            started = true
        }
        guard !sample.bytes.isEmpty else { throw RecordingMediaError.invalidNAL }
        if frame.kind == .key && !sample.sync { throw RecordingMediaError.invalidNAL }
        lastTime = try clock.stamp(frame)
        videoSampleCount += 1
        return sample
    }
}

struct RecordingCompressedSample { let bytes: Data; let sync: Bool }

/// Annex B access units become one length-prefixed CMSampleBuffer each. No decoder
/// timestamps are supplied by XM, so reject streams known to require reordering.
struct RecordingNALConfiguration {
    private var parameters: [UInt8: Data] = [:]
    private var codec: UInt8 = 0
    var complete: Bool { codec == 2 ? parameters[7] != nil && parameters[8] != nil : parameters[32] != nil && parameters[33] != nil && parameters[34] != nil }

    mutating func consume(_ payload: Data, codec: UInt8) throws -> RecordingCompressedSample {
        guard codec == 2 || codec == 3 else { throw RecordingMediaError.unsupportedVideo }
        if self.codec != 0 && self.codec != codec { throw RecordingMediaError.configurationChanged }
        self.codec = codec
        var bytes = Data(), sync = false, hasSlice = false
        for nal in try Self.units(payload) {
            guard let first = nal.first, first & 0x80 == 0 else { throw RecordingMediaError.invalidNAL }
            let type = codec == 2 ? first & 31 : (first >> 1) & 63
            if codec == 3 {
                guard nal.count >= 2, nal[1] & 7 != 0, ((first & 1) << 5 | nal[1] >> 3) == 0, type <= 40 else { throw RecordingMediaError.invalidNAL }
            } else {
                guard type > 0 && type <= 23 else { throw RecordingMediaError.invalidNAL }
                guard [1,5,6,7,8,9,10,11,12].contains(type) else { throw RecordingMediaError.unsupportedVideo }
            }
            let parameter = codec == 2 ? [7,8].contains(type) : [32,33,34].contains(type)
            if parameter {
                if let previous = parameters[type], previous != nal { throw RecordingMediaError.configurationChanged }
                if codec == 3 && type == 33 { try Self.rejectHEVCReordering(nal) }
                parameters[type] = nal
                continue
            }
            if codec == 2 && (type == 1 || type == 5) {
                var reader = RecordingBitReader(rbsp: nal.dropFirst())
                _ = try reader.ue()
                let sliceType = try reader.ue()
                guard sliceType <= 9 else { throw RecordingMediaError.invalidNAL }
                if sliceType % 5 == 1 { throw RecordingMediaError.reorderedVideo }
                hasSlice = true; sync = sync || type == 5
            } else if codec == 3 && type <= 31 {
                hasSlice = true; sync = sync || (16...21).contains(type)
            }
            let count = UInt32(nal.count)
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)])
            bytes.append(nal)
        }
        guard hasSlice else { return RecordingCompressedSample(bytes: Data(), sync: false) }
        return RecordingCompressedSample(bytes: bytes, sync: sync)
    }

    static func units(_ payload: Data) throws -> [Data] {
        let bytes = [UInt8](payload)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        guard let first = starts.first, bytes[..<first.0].allSatisfy({ $0 == 0 }) else { throw RecordingMediaError.invalidNAL }
        var units: [Data] = []
        for index in starts.indices {
            let start = starts[index].0 + starts[index].1
            var end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            while end > start && bytes[end - 1] == 0 { end -= 1 }
            guard end > start else { throw RecordingMediaError.invalidNAL }
            units.append(Data(bytes[start..<end]))
        }
        return units
    }

    func formatDescription() throws -> CMVideoFormatDescription {
        guard complete else { throw RecordingMediaError.missingParameters }
        let types: [UInt8] = codec == 2 ? [7,8] : [32,33,34]
        // Allocate short-lived copies for the CoreMedia C API; it copies parameter
        // sets into the returned format description before these pointers are freed.
        let buffers = types.map { [UInt8](parameters[$0]!) }
        let pointers = buffers.map { value -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: value.count)
            p.initialize(from: value, count: value.count)
            return p
        }
        defer { for (index, pointer) in pointers.enumerated() { pointer.deinitialize(count: buffers[index].count); pointer.deallocate() } }
        let readOnly = pointers.map { UnsafePointer($0) }
        let sizes = buffers.map(\.count)
        var description: CMVideoFormatDescription?
        let status = readOnly.withUnsafeBufferPointer { ptrs in sizes.withUnsafeBufferPointer { lengths in
            if codec == 2 { return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: lengths.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description) }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: lengths.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        } }
        guard status == noErr, let description else { throw RecordingMediaError.missingParameters }
        return description
    }

    private static func rejectHEVCReordering(_ nal: Data) throws {
        var bits = RecordingBitReader(rbsp: nal.dropFirst(2))
        _ = try bits.read(4)
        let layers = try bits.read(3)
        guard layers <= 6 else { throw RecordingMediaError.invalidNAL }
        _ = try bits.read(1)
        // profile_tier_level(1, max_sub_layers_minus1), including sublayer flags.
        try bits.skip(96)
        var profiles: [Bool] = [], levels: [Bool] = []
        for _ in 0..<layers { profiles.append(try bits.read(1) == 1); levels.append(try bits.read(1) == 1) }
        if layers > 0 { try bits.skip((8 - layers) * 2) }
        for index in 0..<layers { if profiles[index] { try bits.skip(88) }; if levels[index] { try bits.skip(8) } }
        _ = try bits.ue() // SPS id
        let chroma = try bits.ue()
        guard chroma <= 3 else { throw RecordingMediaError.invalidNAL }
        if chroma == 3 { _ = try bits.read(1) }
        _ = try bits.ue(); _ = try bits.ue() // dimensions
        if try bits.read(1) == 1 { for _ in 0..<4 { _ = try bits.ue() } }
        _ = try bits.ue(); _ = try bits.ue(); _ = try bits.ue() // bit depths and POC
        let all = try bits.read(1) == 1
        for _ in (all ? 0 : layers)...layers {
            _ = try bits.ue()
            guard try bits.ue() == 0 else { throw RecordingMediaError.reorderedVideo }
            _ = try bits.ue()
        }
    }
}

private struct RecordingBitReader {
    private let bytes: [UInt8]
    private var offset = 0
    init(rbsp: Data.SubSequence) {
        var result: [UInt8] = [], zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            result.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        bytes = result
    }
    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0 && count <= 31, offset + count <= bytes.count * 8 else { throw RecordingMediaError.invalidNAL }
        var value = 0
        for _ in 0..<count { value = value << 1 | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1); offset += 1 }
        return value
    }
    mutating func skip(_ count: Int) throws {
        guard count >= 0 && offset + count <= bytes.count * 8 else { throw RecordingMediaError.invalidNAL }
        offset += count
    }
    mutating func ue() throws -> Int {
        var zeros = 0
        while try read(1) == 0 { zeros += 1; guard zeros <= 30 else { throw RecordingMediaError.invalidNAL } }
        return (1 << zeros) - 1 + (try read(zeros))
    }
}
