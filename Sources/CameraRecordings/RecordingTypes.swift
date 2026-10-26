import Foundation

/// Camera-local Gregorian components. `date` is a synthetic UTC coordinate for
/// arithmetic and display with an explicitly UTC formatter, never an instant.
struct CameraRecordingTime: Hashable, Comparable, Sendable {
    let date: Date
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    init?(wire: String) {
        let bytes = Array(wire.utf8)
        guard bytes.count == 19, bytes[4] == 45, bytes[7] == 45, bytes[10] == 32, bytes[13] == 58, bytes[16] == 58 else { return nil }
        let fields = [(0, 4), (5, 2), (8, 2), (11, 2), (14, 2), (17, 2)]
        var values: [Int] = []
        for (start, length) in fields {
            let digits = bytes[start..<(start + length)]
            guard digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
            values.append(digits.reduce(0) { $0 * 10 + Int($1 - 48) })
        }
        guard (1...9999).contains(values[0]), (1...12).contains(values[1]), (1...31).contains(values[2]),
              (0...23).contains(values[3]), (0...59).contains(values[4]), (0...59).contains(values[5]) else { return nil }
        let components = DateComponents(year: values[0], month: values[1], day: values[2], hour: values[3], minute: values[4], second: values[5])
        guard let date = Self.calendar.date(from: components) else { return nil }
        let actual = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == values[0], actual.month == values[1], actual.day == values[2], actual.hour == values[3], actual.minute == values[4], actual.second == values[5] else { return nil }
        self.date = date
    }
    init?(date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        guard (1...9999).contains(Self.calendar.component(.year, from: whole)), Self.calendar.component(.era, from: whole) == 1 else { return nil }
        self.date = whole
    }
    var year: Int { Self.calendar.component(.year, from: date) }
    var month: Int { Self.calendar.component(.month, from: date) }
    var day: Int { Self.calendar.component(.day, from: date) }
    var hour: Int { Self.calendar.component(.hour, from: date) }
    var minute: Int { Self.calendar.component(.minute, from: date) }
    var second: Int { Self.calendar.component(.second, from: date) }
    var wire: String { String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second) }
    var dayStart: Self { Self(date: Self.calendar.startOfDay(for: date))! }
    func adding(seconds: Int) -> Self? { Self(date: date.addingTimeInterval(Double(seconds))) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }
}

struct CameraRecording: Identifiable, Hashable, Sendable {
    let fileName: String
    let begin: CameraRecordingTime
    let end: CameraRecordingTime
    let estimatedBytes: UInt64?
    let channel: Int
    let substream: Bool
    /// The camera name is an opaque protocol token; it is never a local path.
    var id: String { "\(fileName.utf8.count):\(fileName)\(begin.wire)\(end.wire):\(channel):\(substream)" }
}
struct RecordingCalendar: Sendable, Equatable { let year: Int; let month: Int; let days: Set<Int> }
struct RecordingListing: Sendable { let records: [CameraRecording]; let complete: Bool; let warnings: [String] }
struct RecordingStorage: Sendable {
    enum Presence: Sendable { case unknown, absent, present }
    let presence: Presence
    let disks: [DeviceJSON]
    let statuses: [Int]
    let totalBytes: UInt64?
    let freeBytes: UInt64?
}
struct RecordingDownloadProgress: Sendable { let receivedBytes: UInt64; let estimatedBytes: UInt64? }
enum RecordingError: Error, LocalizedError, Sendable {
    case invalidTime, invalidSelection, incompleteTransfer, byteLimit, fileIO, busy
    var errorDescription: String? {
        switch self {
        case .invalidTime: String(localized: "The camera returned an invalid recording time.")
        case .invalidSelection: String(localized: "Choose a valid recording, channel and stream.")
        case .incompleteTransfer: String(localized: "The camera closed the transfer before confirming the recording was complete.")
        case .byteLimit: String(localized: "This recording exceeds the download limit.")
        case .fileIO: String(localized: "The recording could not be saved in the private cache.")
        case .busy: String(localized: "Wait for the previous recording download to stop.")
        }
    }
}
