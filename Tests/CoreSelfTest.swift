import Foundation

@main
enum CoreSelfTest {
    static func main() throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        let endpoint = CameraEndpoint(host: "192.0.2.10")
        let text = String(decoding: try endpoint.playlist(username: "admin", password: "a'b@#\nfile /etc/passwd"), as: UTF8.self)
        check(text.contains("a%27b%40%23%0Afile%20%2Fetc%2Fpasswd"), "Credentials are URL encoded")
        check(text.components(separatedBy: "\nfile ").count == 2, "Exactly one playlist file")
        check(!text.contains("\nfile /etc/passwd"), "Credentials cannot inject a file directive")
        check(sofiaPassword("") == "tlJwpbo6", "Xiongmai empty-password protocol vector")
        check(sofiaPassword("password") == "mF95aD4o", "Xiongmai nonempty-password protocol vector")
        let compatible = String(decoding: try endpoint.playlist(username: "admin", password: "", useSofiaQuery: true), as: UTF8.self)
        check(compatible.contains("user=admin&password=tlJwpbo6&channel=1"), "Sofia credential reaches the vendor RTSP path")
        for host in ["", "192.0.2.1\nfile", "example.com/path", "a@b", "-option"] {
            do {
                _ = try CameraEndpoint(host: host).playlist(username: "a", password: "b")
                failures.append("Rejected invalid host: \(host.debugDescription)")
            } catch {}
        }
        do {
            _ = try CameraEndpoint(host: "camera.home", port: 0).playlist(username: "a", password: "b")
            failures.append("Rejected invalid port")
        } catch {}
        check(!streamHasTimedOut(elapsed: .seconds(19), sinceLastFrame: nil), "Allow initial connection time")
        check(streamHasTimedOut(elapsed: .seconds(21), sinceLastFrame: nil), "Connection cannot hang indefinitely")
        check(!streamHasTimedOut(elapsed: .seconds(600), sinceLastFrame: .seconds(1)), "A healthy long stream remains live")
        check(streamHasTimedOut(elapsed: .seconds(600), sinceLastFrame: .seconds(13)), "A frozen stream cannot remain live")
        var authentication = DecoderDiagnostics()
        authentication.consume(Data("[rtsp] DESCRIBE failed: 401 Unauth".utf8))
        authentication.consume(Data("orized\nImpossible to open rtsp://admin:fake%40secret@camera/\n".utf8))
        check(authentication.failure == .authentication, "Authentication errors survive chunk boundaries")
        check(!(authentication.failure?.message ?? "").contains("fake"), "Diagnostics never expose credential-bearing output")
        var missing = DecoderDiagnostics()
        missing.consume(Data("Server returned 404 Not Found".utf8))
        check(missing.failure == .streamNotFound, "Missing stream differs from wrong password")
        var unreachable = DecoderDiagnostics()
        unreachable.consume(Data("Connection to tcp://camera:554 failed: Connection refused".utf8))
        check(unreachable.failure == .unreachable, "Network failure differs from authentication")
        var parser = JPEGFramer()
        check(try parser.append(Data([0x00, 0xff])).isEmpty, "Wait for split JPEG start marker")
        check(try parser.append(Data([0xd8, 0x01, 0x02, 0xff])).isEmpty, "Wait for split JPEG end marker")
        let frames = try parser.append(Data([0xd9, 0xff, 0xd8, 0x03, 0xff, 0xd9]))
        check(frames == [Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9]), Data([0xff, 0xd8, 0x03, 0xff, 0xd9])], "Split and adjacent JPEG frames survive chunking")
        var unfinished = JPEGFramer()
        _ = try unfinished.append(Data([0xff, 0xd8]))
        do {
            _ = try unfinished.append(Data(repeating: 1, count: 16 * 1024 * 1024 + 1))
            failures.append("Unfinished JPEG has a memory limit")
        } catch {}
        if failures.isEmpty {
            print("PASS: credential escaping, endpoint validation, JPEG chunking, bounded buffering, stream liveness, safe diagnostics")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
