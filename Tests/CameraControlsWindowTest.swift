import AppKit
import Foundation

@main enum CameraControlsWindowTest {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
    @MainActor static func wait(_ message: String, seconds: Double = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw Failure.failed("Timed out: " + message) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    @MainActor static func stats(_ port: Int) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/__stats")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.failed("Fixture stats unavailable") }
        return value
    }
    static func count(_ stats: [String: Any], _ name: String) -> Int { (stats["counts"] as? [String: Int])?[name] ?? 0 }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count >= 3, let onvifPort = Int(CommandLine.arguments[1]),
              let controlPort = Int(CommandLine.arguments[2]), (1...65535).contains(onvifPort), (1...65535).contains(controlPort) else {
            throw Failure.failed("Usage: CameraControlsWindowTest <synthetic ONVIF port> <synthetic DVRIP port> [--snapshot path | --shutdown-move | --shutdown-preset | --restart]")
        }
        let suite = "synthetic-controls-window-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let camera = Camera(name: "Synthetic localhost camera", host: "127.0.0.1", onvifPort: onvifPort, controlPort: controlPort)
        defaults.set(try JSONEncoder().encode([camera]), forKey: "cameras")
        let store = CameraStore(defaults: defaults)
        let session = store.session(camera)
        session.state = .live
        session.image = NSImage(size: NSSize(width: 32, height: 32))
        let windows = CameraWindows()
        let lifecycle = CameraAppLifecycle()
        lifecycle.configure(store: store, windows: windows, openMain: {})
        NSApp.delegate = lifecycle
        defer { lifecycle.menuBar?.uninstall(); NSApp.delegate = nil }
        guard let model = windows.openControls(camera: camera, store: store) else { throw Failure.failed("Native controls model missing") }
        let identifier = NSUserInterfaceItemIdentifier("controls-\(camera.id)")
        guard let first = NSApp.windows.first(where: { $0.identifier == identifier }) else { throw Failure.failed("Native controls window missing") }
        try await wait("visible controls window") { first.isVisible }
        try require(first.styleMask.contains(.resizable) && first.frame.width >= 900, "Native controls window is not resizable or wide enough")
        let sameModel = windows.openControls(camera: camera, store: store)
        try require(sameModel === model && NSApp.windows.filter { $0.identifier == identifier && $0.isVisible }.count == 1, "Repeated Controls action did not reuse window and model")
        // Allow the actual view's onAppear discovery to finish before explicit synthetic authentication.
        try await wait("view discovery") { !model.discovering && !model.profiles.isEmpty && !model.loadingDetails }
        model.authenticate(Credentials(username: "fixture", password: UUID().uuidString))
        try await wait("view model authenticated") { model.deviceReady && !model.loadingDetails && !model.profiles.isEmpty && !model.checkingSettings }
        first.contentView?.layoutSubtreeIfNeeded()
        try require(model.ptzOptions != nil && model.imaging.contains { $0.path == "Brightness" }, "Native controls model did not render advertised fixture capabilities")
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            try await Task.sleep(for: .milliseconds(150))
            guard let view = first.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.failed("Native screenshot bitmap unavailable") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure.failed("Native screenshot encoding failed") }
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }

        let shutdownMove = CommandLine.arguments.contains("--shutdown-move")
        let shutdownPreset = CommandLine.arguments.contains("--shutdown-preset")
        let restart = CommandLine.arguments.contains("--restart")
        if shutdownMove || shutdownPreset || restart {
            let before = try await stats(onvifPort)
            let command: String
            if restart { command = "DVRIP:1450:OPMachine"; model.restartCamera() }
            else if shutdownPreset { command = "ONVIF:GotoPreset"; model.goToPreset("synthetic-preset") }
            else { command = "ONVIF:ContinuousMove"; model.nudge(pan: 0.25, tilt: 0, zoom: 0) }
            let deadline = Date().addingTimeInterval(5)
            while count(try await stats(onvifPort), command) <= count(before, command) {
                guard Date() < deadline else { throw Failure.failed("Pending operation never reached fixture") }
                try await Task.sleep(for: .milliseconds(20))
            }
            if restart { try await Task.sleep(for: .milliseconds(100)) }
            print("READY: real NSApplication termination with synthetic pending operation")
            fflush(stdout)
            // Enter through the AppKit run loop, as the real Quit menu does;
            // synchronous terminate() inside a MainActor Task holds the actor during its nested loop.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            // A terminateLater delegate must remain alive until it replies.
            try await Task.sleep(for: .seconds(22))
            throw Failure.failed("NSApplication termination never completed")
        }

        let beforeClose = try await stats(onvifPort)
        model.nudge(pan: 0.25, tilt: 0, zoom: 0)
        let deadline = Date().addingTimeInterval(5)
        while count(try await stats(onvifPort), "ONVIF:ContinuousMove") <= count(beforeClose, "ONVIF:ContinuousMove") {
            guard Date() < deadline else { throw Failure.failed("Close movement never reached fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        windows.closeControls(camera.id)
        await model.shutdown()
        let afterClose = try await stats(onvifPort)
        let movement = (afterClose["order"] as? [String] ?? []).filter { ["ONVIF:ContinuousMove", "ONVIF:Stop"].contains($0) }
        try require(movement.last == "ONVIF:Stop", "Closing controls did not complete final Stop")
        try require(!first.isVisible && session.state == .live && session.image != nil, "Closing controls changed shared video lifetime")
        let reopened = windows.openControls(camera: camera, store: store)
        try require(reopened !== model && NSApp.windows.contains { $0.identifier == identifier && $0 !== first && $0.isVisible }, "Closed controls did not reopen with a new model")
        windows.closeAll()
        await windows.prepareForTermination()
        try require(session.state == .live, "Window cleanup stopped shared video")
        print("PASS: native controls window, model reuse, discovery, synthetic authentication, close during Move final Stop, reopen and shared video lifetime")
    }
}
