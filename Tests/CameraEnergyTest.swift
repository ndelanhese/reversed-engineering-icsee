import AppKit
import Foundation

@main struct CameraEnergyTest {
    @MainActor static func main() throws {
        let session = CameraSession()
        defer { session.stop() }
        let camera = Camera(name: "Invisible synthetic camera", host: "127.0.0.1", port: 1)
        session.start(camera: camera, credentials: Credentials(username: "fixture", password: "fixture"))
        let ps = Process()
        let output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "ppid=,comm="]
        ps.standardOutput = output
        try ps.run()
        let children = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let hasDecoder = children.split(separator: "\n").contains { row in
            let parts = row.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == owner && parts[1].hasSuffix("/ffmpeg")
        }
        guard !hasDecoder else { print("FAIL: invisible camera spawned a decoder"); exit(1) }
        guard session.credentialsForControls()?.username == "fixture" else { print("FAIL: idle suspend forgot authenticated camera"); exit(1) }
        print("PASS: invisible camera uses no decoder and retains authentication in memory")
    }
}
