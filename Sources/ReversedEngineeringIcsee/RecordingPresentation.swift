import Foundation

enum RecordingPresentationError: Error, LocalizedError {
    case invalidRange, insufficientSpace, exportFailed
    var errorDescription: String? {
        switch self {
        case .invalidRange: String(localized: "Select a valid interval within the recording.")
        case .insufficientSpace: String(localized: "Not enough free disk space to prepare this recording.")
        case .exportFailed: String(localized: "The recording could not be exported. The original download was kept.")
        }
    }
}

struct RecordingExportRange: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    init(start: TimeInterval, end: TimeInterval, duration: TimeInterval, keyframes: [TimeInterval]) throws {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0,
              start >= 0, end <= duration, start < end else { throw RecordingPresentationError.invalidRange }
        let boundaries = Set(keyframes.filter { $0.isFinite && $0 >= 0 && $0 < duration } + [0, duration]).sorted()
        self.start = boundaries.last(where: { $0 <= start }) ?? 0
        self.end = boundaries.first(where: { $0 >= end }) ?? duration
    }
}

/// One recording owns one private directory; camera filenames never become local paths.
struct RecordingPrivateDirectory: Sendable {
    let url: URL
    var rawURL: URL { url.appendingPathComponent("original.xm") }
    var movieURL: URL { url.appendingPathComponent("recording.mov") }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("icsee-recording-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func checkSpace(estimatedBytes: UInt64?) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let estimate = min(estimatedBytes ?? 128 * 1024 * 1024, 2 * 1024 * 1024 * 1024)
        guard free > estimate * 2 + 64 * 1024 * 1024 else { throw RecordingPresentationError.insufficientSpace }
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

func recordingDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}
