import Foundation

@main enum RecordingPresentationTest {
    static func main() throws {
        let range = try RecordingExportRange(start: 1.5, end: 4.2, duration: 8, keyframes: [0, 2, 4, 6])
        precondition(range.start == 0 && range.end == 6)
        let exact = try RecordingExportRange(start: 2, end: 4, duration: 8, keyframes: [0, 2, 4, 6])
        precondition(exact.start == 2 && exact.end == 4)
        let last = try RecordingExportRange(start: 6.1, end: 8, duration: 8, keyframes: [0, 2, 4, 6])
        precondition(last.start == 6 && last.end == 8)
        for pair in [(Double.nan, 2.0), (2, Double.infinity), (4, 2), (8, 8), (-1, 2)] {
            do {
                _ = try RecordingExportRange(start: pair.0, end: pair.1, duration: 8, keyframes: [0, 2])
                preconditionFailure("Invalid export range accepted")
            } catch RecordingPresentationError.invalidRange { }
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try RecordingPrivateDirectory(baseURL: base)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.url.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o700)
        precondition(directory.rawURL.deletingLastPathComponent() == directory.url)
        let sibling = directory.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data([1, 2]).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        directory.remove()
        precondition(!FileManager.default.fileExists(atPath: directory.url.path))
        precondition(FileManager.default.fileExists(atPath: sibling.path))
        let live = try RecordingPrivateDirectory(baseURL: base)
        let stale = base.appendingPathComponent("icsee-recording-2147483647-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        let linked = base.appendingPathComponent("icsee-recording-2147483647-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: live.url)
        RecordingPrivateDirectory.removeOrphans(baseURL: base)
        precondition(!FileManager.default.fileExists(atPath: stale.path))
        precondition(FileManager.default.fileExists(atPath: live.url.path))
        precondition((try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path)) != nil)
        print("PASS: keyframe export bounds, invalid ranges and isolated private cache permissions/cleanup")
    }
}
