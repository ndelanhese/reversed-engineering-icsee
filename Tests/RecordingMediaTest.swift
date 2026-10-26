import Foundation
import AVFoundation

@main enum RecordingMediaTest {
    enum Failure: Error { case failed(String) }
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !value() { throw Failure.failed(label) }
    }
    static func rejects(_ error: RecordingMediaError, _ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.failed("Expected \(error)") }
        catch let actual as RecordingMediaError { try check(actual == error, "Correct media failure: \(actual)") }
    }
    static func key(second: UInt32 = 0, fps: UInt8 = 10, codec: UInt8 = 2, payload: Data = Data([0,0,1,0x65,0xB8])) -> Data {
        let stamp: UInt32 = second | (25 << 17) | (10 << 22) | (26 << 26)
        return Data([0,0,1,0xFC,codec,fps,8,8]) + le(stamp) + le(UInt32(payload.count)) + payload
    }
    static func le(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func delta(_ payload: Data = Data([0,0,1,0x41,0xE0])) -> Data { Data([0,0,1,0xFD]) + le(UInt32(payload.count)) + payload }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-fixture" {
            try fixture(codec: 2, audio: 14).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let wire = key(fps: 0xEA) + delta() + Data([0,0,1,0xFA,14,2,2,0,0xD5,0x55]) + Data([0,0,1,0xF9,1,0,1,0,42])
        for split in 0...wire.count {
            var parser = RecordingMediaParser()
            let frames = try parser.append(Data(wire.prefix(split))) + parser.append(Data(wire.dropFirst(split)))
            try parser.finish()
            try check(frames.count == 4, "Every arbitrary split and coalescing")
            try check(frames[0].fps == 10 && frames[0].width == 64 && frames[1].codec == 2, "Declared FPS masks and inherited codec")
            try check(frames[2].sampleRate == 8000 && frames[2].codec == 14, "Audio metadata")
        }
        try rejects(.truncated) { var p = RecordingMediaParser(); _ = try p.append(Data(wire.dropLast())); try p.finish() }
        try rejects(.frameTooLarge) { var p = RecordingMediaParser(maximumFrameBytes: 32); _ = try p.append(Data([0,0,1,0xFD,255,255,255,255])) }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(Data([0,0,1,0xF8])) }
        try rejects(.invalidClock) { var p = RecordingMediaParser(); _ = try p.append(key(second: 63)) }
        try rejects(.invalidFrameRate) { var p = RecordingMediaParser(); _ = try p.append(key(fps: 0)) }
        try rejects(.configurationChanged) { var p = RecordingMediaParser(); _ = try p.append(key() + key(fps: 12)) }
        for cut in 1..<key().count { try rejects(.truncated) { var p = RecordingMediaParser(); _ = try p.append(Data(key().prefix(cut))); try p.finish() } }
        var bytewise = RecordingMediaParser()
        var bytewiseFrames: [RecordingMediaFrame] = []
        for byte in wire { bytewiseFrames += try bytewise.append(Data([byte])) }
        try bytewise.finish()
        try check(bytewiseFrames.count == 4, "One-byte chunk stream")
        let paddingLength = 1024 - wire.count % 1024
        let padded = wire + Data(repeating: 0xFF, count: paddingLength)
        for split in 0...padded.count {
            var p = RecordingMediaParser()
            let decoded = try p.append(Data(padded.prefix(split))) + p.append(Data(padded.dropFirst(split)))
            try p.finish()
            try check(decoded.count == 4, "Only aligned bounded FF EOF padding is accepted across every split")
        }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(wire + Data(repeating: 0xFF, count: 1024)); try p.finish() }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(wire + Data(repeating: 0xFF, count: 1)); try p.finish() }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(padded); _ = try p.append(key()); try p.finish() }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(Data(repeating: 0xFF, count: 1024)); try p.finish() }
        try rejects(.invalidHeader) { var p = RecordingMediaParser(); _ = try p.append(wire + Data([0xFF,0xFF,0,0xFF])); try p.finish() }
        var dimensions = key(); dimensions[4] |= 0x90
        try check(try RecordingMediaParser.frame(dimensions).width == 2112 && RecordingMediaParser.frame(dimensions).height == 4160, "Extended dimension bits")
        try check(G711.decode(0xD5, codec: 14) == 8 && G711.decode(0x55, codec: 14) == -8, "A-law silence vectors")
        try check(G711.decode(0xFF, codec: 10) == 0 && G711.decode(0x7F, codec: 10) == 0 && G711.decode(0, codec: 10) == -32124, "Mu-law known vectors")
        var parser = RecordingMediaParser()
        let frames = try parser.append(key() + delta() + key() + key(second: 3))
        var clock = RecordingMediaClock()
        let times = try frames.map { try clock.stamp($0) }
        try check(times == [0,0.1,0.2,3], "Quantized keys stay monotonic; real gap preserved")
        try check(clock.mappingSegments.count == 2, "Gap has separate mapping")
        try rejects(.backwardClock) { _ = try clock.stamp(try RecordingMediaParser.frame(key(second: 1))) }
        var nal = RecordingNALConfiguration()
        try rejects(.reorderedVideo) { _ = try nal.consume(Data([0,0,1,0x41,0xA0]), codec: 2) }
        let reordered = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/recording-reordered.h265")
        try rejects(.reorderedVideo) { var n = RecordingNALConfiguration(); _ = try n.consume(Data(contentsOf: reordered), codec: 3) }
        var configuration = RecordingNALConfiguration()
        var fixtureParser = RecordingMediaParser()
        let fixtureFrames = try fixtureParser.append(fixture(codec: 2, audio: 0))
        _ = try configuration.consume(fixtureFrames[0].payload, codec: 2)
        let parameter = try RecordingNALConfiguration.units(fixtureFrames[0].payload).first { $0[0] & 31 == 7 }!
        var changedParameter = parameter; changedParameter[changedParameter.count - 1] ^= 1
        try rejects(.configurationChanged) { _ = try configuration.consume(Data([0,0,0,1]) + changedParameter, codec: 2) }
        var declaredCadence = RecordingMediaClock()
        let differentFPS = try RecordingMediaParser.frame(key(fps: 7))
        _ = try declaredCadence.stamp(differentFPS)
        var sevenParser = RecordingMediaParser(); let sevenFrames = try sevenParser.append(key(fps: 7) + delta())
        try check(abs(try declaredCadence.stamp(sevenFrames[1]) - 1.0 / 7) < 0.000001, "No hardcoded frame rate")
        var roundedClock = RecordingMediaClock()
        var roundedParser = RecordingMediaParser()
        var roundedWire = Data()
        for index in 0..<3750 {
            let seconds = Int(Double(index) / 12.5)
            let packed = UInt32(seconds % 60) | UInt32(seconds / 60) << 6
            roundedWire += index % 36 == 0 ? key(second: packed, fps: 12) : delta()
        }
        let roundedFrames = try roundedParser.append(roundedWire)
        for frame in roundedFrames { _ = try roundedClock.stamp(frame) }
        let corrected = try roundedClock.correctedFrameDuration ?? { throw Failure.failed("Rounded camera FPS was not identified") }()
        try check(abs(1 / corrected - 12.5) < 0.01 && roundedClock.gapCount == 0, "Many coarse anchors recover rounded fractional cadence without inventing gaps")
        var calibrated = RecordingMediaClock(frameDuration: corrected)
        var previousTime = -1.0
        for frame in roundedFrames {
            let time = try calibrated.stamp(frame)
            try check(time > previousTime, "Calibrated native PTS remain strictly increasing")
            previousTime = time
        }
        let mapped = MovieResult(url: URL(fileURLWithPath: "/synthetic"), duration: calibrated.duration, cameraOrigin: calibrated.origin!, mappingSegments: calibrated.finalizedMappings, keyframeTimes: calibrated.keyframeTimes, audioStatus: .none, notices: [])
        try check(abs(calibrated.duration - 300) < 0.1, "Fractional cadence avoids multi-second drift")
        for (index, frame) in roundedFrames.enumerated() where frame.kind == .key {
            let time = Double(index) * corrected
            try check(abs((mapped.cameraTime(at: time) ?? .distantPast).timeIntervalSince(frame.cameraTime!)) < 0.001, "Affine camera mapping honors recorded coarse key anchors")
        }
        try rejects(.backwardClock) { _ = try calibrated.stamp(try RecordingMediaParser.frame(key(second: 1, fps: 12))) }
        try await nativeMovies()
        print("PASS: XM incremental framing, bounds, clock, quantization, configuration and G711 vectors")
    }

    static func nativeMovies() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("recording-media-test-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let writer = RecordingMovieWriter()
        for codec: UInt8 in [2,3] {
            for audio: UInt8 in [0,14,10,8] {
                let raw = directory.appendingPathComponent("\(codec)-\(audio).xm")
                let movie = directory.appendingPathComponent("\(codec)-\(audio).mov")
                let data = try fixture(codec: codec, audio: audio)
                try data.write(to: raw)
                let result = try await writer.convert(rawURL: raw, movieURL: movie)
                try check(abs(result.duration - 3) < 0.01, "Native movie retains declared cadence and duration")
                try check(result.keyframeTimes.count == 3 && zip(result.keyframeTimes, [0.0,1,2]).allSatisfy { abs($0 - $1) < 0.001 }, "Keyframe export anchors")
                try check(result.mappingSegments.count == 1 && result.cameraTime(at: 1.5) == result.cameraOrigin.addingTimeInterval(1.5), "Movie/camera mapping")
                try check(abs((result.movieTime(for: result.cameraOrigin.addingTimeInterval(2)) ?? -1) - 2) < 0.000001, "Camera-to-movie seek mapping")
                let expected: RecordingAudioStatus = audio == 0 ? .none : audio == 8 ? .unsupported : .inferredAlignment
                try check(result.audioStatus == expected, "Audio is native AAC or explicitly unsupported")
                try check(try Data(contentsOf: raw) == data, "Raw input retained")
                let asset = AVURLAsset(url: movie)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                try check(audioTracks.isEmpty == (expected != .inferredAlignment), "Audio status matches actual movie track")
                if expected == .inferredAlignment { try await decodeAudio(asset) }
                try await decode(asset)
                try await verifySync(asset)
                if audio == 0 { try await playerCanPlay(movie) }
                print("PASS: native codec \(codec), audio \(audio), 3s/30 decodable frames")
            }
        }
        let raw = directory.appendingPathComponent("cancel.xm")
        let movie = directory.appendingPathComponent("cancel.mov")
        try fixture(codec: 2, audio: 14).write(to: raw)
        let operation = Task { try await writer.convert(rawURL: raw, movieURL: movie) }
        operation.cancel()
        do { _ = try await operation.value; throw Failure.failed("Cancelled operation published movie") }
        catch is CancellationError {}
        try check(files.fileExists(atPath: raw.path) && !files.fileExists(atPath: movie.path), "Cancellation preserves raw and removes movie")
        try check(try files.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial") }, "Cancellation leaves no owned partial files")
        let sentinel = Data("owned-by-caller".utf8)
        try sentinel.write(to: movie)
        do { _ = try await writer.convert(rawURL: raw, movieURL: movie); throw Failure.failed("Overwrote existing output") }
        catch let error as RecordingMediaError { try check(error == .outputExists, "Existing target refused") }
        try check(try Data(contentsOf: movie) == sentinel, "Existing caller file preserved")
        let malformed = directory.appendingPathComponent("malformed.xm")
        try Data([0,0,1,0xFD,255,255,255,255]).write(to: malformed)
        do { _ = try await writer.convert(rawURL: malformed, movieURL: directory.appendingPathComponent("bad.mov")); throw Failure.failed("Malformed converted") }
        catch let error as RecordingMediaError { try check(error == .frameTooLarge, "Malformed media fails bounded") }
        try check(files.fileExists(atPath: malformed.path), "Failed conversion retains original")
        // A real clock gap is kept in the movie and excluded from seek mappings.
        var p = RecordingMediaParser()
        let originalFrames = try p.append(fixture(codec: 2, audio: 0))
        // A valid container/configuration does not prove the VCL payload decodes.
        for damagedRange in [0..<30, 20..<30] {
            var corrupt = Data()
            for (index, frame) in originalFrames.enumerated() {
                let payload = try RecordingNALConfiguration.units(frame.payload).reduce(into: Data()) { output, unit in
                    let type = unit[0] & 31
                    let damaged = damagedRange.contains(index) && (type == 1 || type == 5)
                    output += Data([0,0,0,1]) + (damaged ? Data(unit.prefix(2)) : unit)
                }
                corrupt += frame.kind == .key ? key(second: UInt32(index / 10), payload: payload) : delta(payload)
            }
            let corruptRaw = directory.appendingPathComponent("corrupt-\(damagedRange.lowerBound).xm")
            let corruptMovie = directory.appendingPathComponent("corrupt-\(damagedRange.lowerBound).mov")
            try corrupt.write(to: corruptRaw)
            do { _ = try await writer.convert(rawURL: corruptRaw, movieURL: corruptMovie); throw Failure.failed("Undecodable VCL with valid configuration was published") }
            catch let error as RecordingMediaError { try check(error == .invalidNAL, "Native decoder rejects corrupted video payloads") }
            try check(try Data(contentsOf: corruptRaw) == corrupt && !files.fileExists(atPath: corruptMovie.path), "Decoder rejection preserves original and never publishes movie")
            try check(try files.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial.mov") }, "Decoder rejection cleans owned partial")
        }
        var withGap = Data()
        for (index, frame) in originalFrames.enumerated() {
            withGap += frame.kind == .key ? key(second: UInt32(index / 10 + (index >= 10 ? 4 : 0)), payload: frame.payload) : delta(frame.payload)
        }
        let gapURL = directory.appendingPathComponent("gap.xm")
        try withGap.write(to: gapURL)
        let gap = try await writer.convert(rawURL: gapURL, movieURL: directory.appendingPathComponent("gap.mov"))
        try check(abs(gap.duration - 7) < 0.001 && gap.mappingSegments.count == 2, "Native movie preserves real four-second gap")
        try check(gap.cameraTime(at: 3) == nil && gap.movieTime(for: gap.cameraOrigin.addingTimeInterval(3)) == nil, "Gap cannot be reported as footage")
        let lateURL = directory.appendingPathComponent("late-start.xm")
        var lateStart = Data()
        for (index, frame) in originalFrames.dropFirst().enumerated() {
            lateStart += frame.kind == .key ? key(second: UInt32((index + 1) / 10), payload: frame.payload) : delta(frame.payload)
        }
        try lateStart.write(to: lateURL)
        let late = try await writer.convert(rawURL: lateURL, movieURL: directory.appendingPathComponent("late-start.mov"))
        try check(abs(late.duration - 2) < 0.001 && late.cameraOrigin == gap.cameraOrigin.addingTimeInterval(1), "Camera origin is first decodable frame, not file begin time")
        try check(late.movieTime(for: gap.cameraOrigin) == nil && late.notices.count > 1, "Discarded leading samples are disclosed and cannot be sought")
        // Cancel after the converter has created its own partial movie, not just
        // before entry; preserve a caller-owned neighbour throughout cleanup.
        let longRaw = directory.appendingPathComponent("long.xm")
        try fixture(codec: 2, audio: 14, repeats: 100).write(to: longRaw)
        let activeCancelURL = directory.appendingPathComponent("active-cancel.mov")
        let activeTask = Task { try await writer.convert(rawURL: longRaw, movieURL: activeCancelURL) }
        let deadline = Date().addingTimeInterval(10)
        var sawPartial = false
        while Date() < deadline {
            sawPartial = try files.contentsOfDirectory(atPath: directory.path).contains { $0.contains("partial.mov") }
            if sawPartial { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        activeTask.cancel()
        do { _ = try await activeTask.value; throw Failure.failed("Active cancellation published movie") }
        catch is CancellationError {}
        try check(sawPartial && !files.fileExists(atPath: activeCancelURL.path), "Active writer cancellation observed and removed partial")
        try check(try files.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.contains("partial.mov") }, "All owned partials removed")
        try check(try Data(contentsOf: movie) == sentinel && files.fileExists(atPath: longRaw.path), "Cancellation retains neighbours and original")
        var roundedNative = Data()
        for index in 0..<3000 {
            let frame = originalFrames[index % originalFrames.count]
            let seconds = Int(Double(index) / 12.5)
            let packed = UInt32(seconds % 60) | UInt32(seconds / 60) << 6
            roundedNative += frame.kind == .key ? key(second: packed, fps: 12, payload: frame.payload) : delta(frame.payload)
            roundedNative += Data([0,0,1,0xFA,14,2,128,2]) + Data(repeating: 0xD5, count: 640)
        }
        let roundedPadding = (1024 - roundedNative.count % 1024) % 1024
        roundedNative += Data(repeating: 0xFF, count: roundedPadding)
        let roundedRaw = directory.appendingPathComponent("rounded-fps.xm")
        try roundedNative.write(to: roundedRaw)
        let rounded = try await writer.convert(rawURL: roundedRaw, movieURL: directory.appendingPathComponent("rounded-fps.mov"))
        try check(abs(rounded.duration - 240) < 1 && rounded.audioStatus == .inferredAlignment, "Native rounded FPS video/audio stay near measured camera duration")
        try check(rounded.notices.contains { $0.contains("rounded frame rate") }, "Cadence correction and uncertainty are disclosed")
        try check(try Data(contentsOf: roundedRaw) == roundedNative, "Padding/cadence conversion leaves input unchanged")
    }

    static func fixture(codec: UInt8, audio: UInt8, repeats: Int = 1) throws -> Data {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/recording-synthetic.\(codec == 2 ? "h264" : "h265")")
        let units = try RecordingNALConfiguration.units(Data(contentsOf: source))
        var accessUnits: [[Data]] = []
        for unit in units {
            let type = codec == 2 ? unit[0] & 31 : unit[0] >> 1 & 63
            if type == (codec == 2 ? 9 : 35) { accessUnits.append([]) }
            guard !accessUnits.isEmpty else { throw Failure.failed("Fixture has AUD first") }
            accessUnits[accessUnits.count - 1].append(unit)
        }
        var result = Data()
        for index in 0..<(accessUnits.count * repeats) {
            let units = accessUnits[index % accessUnits.count]
            let payload = units.reduce(into: Data()) { $0 += Data([0,0,0,1]) + $1 }
            let sync = units.contains { codec == 2 ? $0[0] & 31 == 5 : (16...21).contains($0[0] >> 1 & 63) }
            let seconds = index / 10
            let packedClock = UInt32(seconds % 60) | UInt32(seconds / 60 % 60) << 6 | UInt32(seconds / 3600) << 12
            result += sync ? key(second: packedClock, codec: codec, payload: payload) : delta(payload)
            if audio != 0 {
                result += Data([0,0,1,0xFA,audio,2,32,3]) + Data(repeating: audio == 10 ? 0xFF : 0xD5, count: 800)
            }
        }
        return result
    }

    static func decodeAudio(_ asset: AVURLAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw Failure.failed("No audio track") }
        let formats = try await track.load(.formatDescriptions)
        try check(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC, "Movie audio is platform AAC")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        try check(reader.startReading(), "Native AAC decoder starts")
        var samples = 0
        while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
        try check(reader.status == .completed && samples > 20_000, "AAC track decodes supported audio")
    }

    static func verifySync(_ asset: AVURLAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output)
        try check(reader.startReading(), "Read compressed sample flags")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue } // Reader boundary markers carry no media.
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
            try check(notSync == (count % 10 != 0), "Native sync flags identify actual random-access samples")
            count += 1
        }
        try check(count == 30 && reader.status == .completed, "Compressed sync flags available for interval export")
    }

    static func decode(_ asset: AVURLAsset) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Failure.failed("No video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try check(reader.startReading(), "Native decoder starts")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try check(CMSampleBufferGetImageBuffer(sample) != nil, "Native decoded image")
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try check(abs(time - Double(count) / 10) < 0.001, "Native sample timestamps")
            count += 1
        }
        try check(reader.status == .completed && count == 30, "All native samples decode")
    }

    @MainActor static func playerCanPlay(_ url: URL) async throws {
        let player = AVPlayer(url: url)
        let deadline = Date().addingTimeInterval(10)
        while player.currentItem?.status == .unknown && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check(player.currentItem?.status == .readyToPlay, "AVPlayer native item becomes ready")
        await player.seek(to: CMTime(seconds: 1.4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try check(abs(player.currentTime().seconds - 1.4) < 0.01, "Native AVPlayer seeks inside recording")
        player.rate = 2
        try check(player.rate == 2, "Native playback rate")
        player.pause(); player.replaceCurrentItem(with: nil)
    }
}
