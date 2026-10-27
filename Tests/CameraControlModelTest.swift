import Foundation

@main struct CameraControlModelTest {
    @MainActor static func main() throws {
        let id = UUID()
        let legacy = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Synthetic camera", "host": "127.0.0.1", "port": 554, "channel": 1, "substream": false])
        let camera = try JSONDecoder().decode(Camera.self, from: legacy)
        guard camera.id == id, camera.onvifPort == 8899, camera.controlPort == 34567, camera.onvifPath == "/onvif/device_service" else { print("FAIL: legacy profiles lost control defaults"); exit(1) }
        let discovery = CameraDiscoveryModel()
        guard !discovery.isScanning, !discovery.hasSearched, discovery.devices.isEmpty else { print("FAIL: discovery started in the background"); exit(1) }
        var selected = camera
        selected.apply(DiscoveredCamera(host: "192.168.4.8", onvifPort: 8080, onvifPath: "/custom/device", name: "Front Door"))
        let roundTrip = try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(selected))
        guard roundTrip == selected, selected.host == "192.168.4.8", selected.onvifPort == 8080,
              selected.onvifPath == "/custom/device", selected.name == camera.name, selected.port == 554, selected.controlPort == 34567 else {
            print("FAIL: discovered selection or persistence changed unrelated fields"); exit(1)
        }
        let model = CameraControlModel(camera: camera)
        guard !model.credentialsProvided, !model.deviceReady, model.profiles.isEmpty else { print("FAIL: controls started authenticated"); exit(1) }
        model.nudge(pan: 1, tilt: 0, zoom: 0)
        guard !model.moving, model.error != nil else { print("FAIL: movement accepted without discovered profile/credentials"); exit(1) }
        model.disconnect()
        guard !model.credentialsProvided, !model.deviceReady, model.profiles.isEmpty else { print("FAIL: disconnect retained authorization"); exit(1) }
        let sections = DeviceSettingSection.all
        guard !sections.isEmpty, Set(sections.map(\.id)).count == sections.count,
              !sections.contains(where: { $0.name.lowercased().hasPrefix("op") || $0.name.lowercased().contains("cloud") }) else { print("FAIL: invalid local settings catalog"); exit(1) }
        guard sections.contains(where: { $0.name == "Camera.Param" }), sections.contains(where: { $0.name == "Detect.MotionDetect" }), sections.contains(where: { $0.name == "Record" }) else { print("FAIL: expected settings missing"); exit(1) }
        print("PASS: legacy camera defaults, unauthenticated motion rejection, disconnect and local settings registry")
    }
}
