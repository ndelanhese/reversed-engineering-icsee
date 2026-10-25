import Foundation

@main enum CameraControlFlowTest {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
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

    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count >= 3, let onvifPort = Int(CommandLine.arguments[1]),
              let controlPort = Int(CommandLine.arguments[2]), (1...65535).contains(onvifPort), (1...65535).contains(controlPort) else {
            throw Failure.failed("Usage: CameraControlFlowTest <synthetic ONVIF port> <synthetic DVRIP port> [--restart-disconnect]")
        }
        let camera = Camera(name: "Synthetic localhost controls", host: "127.0.0.1", onvifPort: onvifPort, controlPort: controlPort)
        let model = CameraControlModel(camera: camera)
        // The test never asks CredentialStore to load or save anything.
        model.authenticate(Credentials(username: "fixture", password: UUID().uuidString))
        try await wait("authenticated discovery and full availability scan") {
            model.deviceReady && !model.discovering && !model.loadingDetails && !model.profiles.isEmpty &&
                !model.checkingSettings && model.checkedSettings == DeviceSettingSection.all.count
        }
        try require(model.onvifError == nil && model.deviceError == nil, "Synthetic protocols failed")
        try require(model.availableSections == Set(["Camera.Param", "Record", "SystemFunction", "SystemInfo"]), "Unsupported sections leaked into available settings")
        try require(!model.sectionErrors.isEmpty, "Unsupported fixture sections were not classified")
        try require(model.profileToken == "synthetic-main" && model.ptzOptions?.maxTimeout == 1, "Profile/options did not come from advertised ONVIF capabilities")

        guard let section = DeviceSettingSection.all.first(where: { $0.name == "Camera.Param" }) else { throw Failure.failed("Camera.Param missing from registry") }
        model.loadSection(section)
        try await wait("load Camera.Param") { !model.busy && model.deviceOriginal != nil }
        let original = model.deviceOriginal!
        let path: [DeviceJSONPathComponent]
        if case .array = original { path = [.index(0), .key("Brightness")] }
        else { path = [.key("Brightness")] }
        let unknownPath = Array(path.dropLast()) + [.key("Unknown")]
        let unknown = try original.value(at: unknownPath)
        let value = Decimal(57)
        model.deviceDraft = try original.replacing(at: path, with: .number(value))
        try require(model.hasDeviceChanges, "Leaf edit was not tracked")
        model.applyDeviceSettings()
        try await wait("verified device write") { !model.busy }
        try require(model.deviceError == nil && !model.hasDeviceChanges, "Apply did not produce verified clean draft")
        try require(try model.deviceOriginal!.value(at: path) == .number(value), "Device readback lost edited value")
        try require(try model.deviceOriginal!.value(at: unknownPath) == unknown, "Apply overwrote unknown fields")
        let afterDevice = try await stats(onvifPort)
        try require(count(afterDevice, "DVRIP:1040:Camera.Param") == 1, "Device write was replayed or missing")

        guard let brightness = model.imaging.first(where: { $0.path == "Brightness" && $0.isWritable }) else { throw Failure.failed("No advertised imaging brightness") }
        model.imagingDraft[brightness.path] = "63"
        model.applyImaging()
        try await wait("verified imaging write") { !model.busy }
        try require(model.error == nil && !model.hasImageChanges && model.imagingDraft["Brightness"] == "63.0", "Image readback was not verified")
        let afterImage = try await stats(onvifPort)
        try require((afterImage["brightness"] as? Double) == 63 && (afterImage["imagingExtensionPreserved"] as? Bool) == true, "Imaging update lost brightness or extension")
        try require(count(afterImage, "ONVIF:SetImagingSettings") == 1, "Imaging write was replayed")

        let beforeMove = count(afterImage, "ONVIF:ContinuousMove")
        model.nudge(pan: 0.25, tilt: 0, zoom: 0)
        try await wait("bounded nudge and final Stop") { !model.moving }
        let afterMove = try await stats(onvifPort)
        try require(count(afterMove, "ONVIF:ContinuousMove") == beforeMove + 1 && count(afterMove, "ONVIF:Stop") >= 1, "Nudge did not send Move/Stop")
        model.nudge(pan: 0, tilt: 0.25, zoom: 0)
        try await Task.sleep(for: .milliseconds(75))
        model.disconnect()
        await model.shutdown()
        let afterDisconnect = try await stats(onvifPort)
        let motionOrder = (afterDisconnect["order"] as? [String] ?? []).filter { ["ONVIF:ContinuousMove", "ONVIF:Stop"].contains($0) }
        try require(motionOrder.last == "ONVIF:Stop", "Disconnect did not await a final Stop")
        try require(!model.credentialsProvided && !model.deviceReady && model.profiles.isEmpty && !model.moving, "Disconnect retained authenticated state")

        if CommandLine.arguments.contains("--restart-disconnect") {
            model.authenticate(Credentials(username: "fixture", password: UUID().uuidString))
            try await wait("reconnect") { model.deviceReady && !model.checkingSettings }
            model.restartCamera()
            try await wait("restarting") { model.restarting }
            try await Task.sleep(for: .milliseconds(150))
            model.disconnect()
            await model.shutdown()
            try require(!model.restarting, "Disconnect during reboot left restarting permanently true")
            let reboot = try await stats(onvifPort)
            let delays = reboot["rebootCloseDelays"] as? [Double] ?? []
            try require(delays.last.map { $0 >= 14.8 } == true, "Acknowledged reboot socket closed before 15 seconds")
        }
        print("PASS: synthetic localhost discovery, availability filtering, object/array leaf write/readback, unknown fields, imaging preservation, nudge and disconnect Stop")
    }
}
