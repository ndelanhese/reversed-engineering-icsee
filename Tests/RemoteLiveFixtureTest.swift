import Foundation
import Darwin

@main struct RemoteLiveFixtureTest {
    static func main() throws {
        guard CommandLine.arguments.count == 7,
              let bootstrap = UInt16(CommandLine.arguments[2]), let lookup = UInt16(CommandLine.arguments[3]),
              let nat = UInt16(CommandLine.arguments[4]), let direct = UInt16(CommandLine.arguments[5]),
              let proxy = UInt16(CommandLine.arguments[6]) else { exit(2) }
        let mode = CommandLine.arguments[1]
        let configuration = try RemoteLiveConfiguration(serial: "1234567890abcdef", channel: 1, substream: true, username: "fixture", password: "fixture")
        let client = RemoteLiveClient(configuration: configuration, testRoute: { host, port in
            let selected: UInt16
            switch (host, port) {
            case ("secu100.net", 7999): selected = bootstrap
            case ("1.1.1.1", 8777): selected = lookup
            case ("1.1.1.1", 8765), ("2.2.2.2", 8765): selected = nat
            case ("3.3.3.3", 4000): selected = direct
            case ("8.8.8.8", 4001): selected = proxy
            default: return ("127.0.0.1", 1)
            }
            return ("127.0.0.1", selected)
        })
        var signalSource: DispatchSourceSignal?
        if ["cancel_start", "cancel_keepalive", "cancel_start_lost", "cancel_keepalive_lost"].contains(mode) {
            signal(SIGUSR1, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
            source.setEventHandler { @Sendable in client.cancel() }
            source.resume()
            signalSource = source
        }
        let cancellation = Task.detached {
            if mode == "cancel" {
                for _ in 0..<200 {
                    if client.stage == "greeting" { client.cancel(); return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                client.cancel()
            }
        }
        let started = Date()
        var frames = 0
        do {
            try client.run { _, _ in
                frames += 1
                if Date().timeIntervalSince(started) > 5 { client.cancel() }
            }
            preconditionFailure("client exited without cancellation")
        } catch is CancellationError {
            if mode != "cancel" && mode != "cancel_start" && mode != "cancel_start_lost" { precondition(frames > 0) }
        } catch RemoteProtocolError.invalidResponse where mode == "bad_session" {
        } catch RemoteProtocolError.authentication where mode == "bad_auth" {
        } catch {
            print("FAIL: remote fixture", mode, "stage", client.stage, "error", String(describing: error))
            exit(1)
        }
        cancellation.cancel()
        signalSource?.cancel()
        print("PASS: remote fixture \(mode)")
    }
}
