import AppKit
import Foundation
import Observation
import Security

struct Camera: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port = 554
    var channel = 1
    var substream = false
    var onvifPort = 8899
    var onvifPath = "/onvif/device_service"
    var controlPort = 34567
    var endpoint: CameraEndpoint {
        CameraEndpoint(host: host, port: port, channel: channel, substream: substream)
    }
}

extension Camera {
    enum CodingKeys: String, CodingKey { case id, name, host, port, channel, substream, onvifPort, onvifPath, controlPort }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 554
        channel = try values.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        substream = try values.decodeIfPresent(Bool.self, forKey: .substream) ?? false
        onvifPort = try values.decodeIfPresent(Int.self, forKey: .onvifPort) ?? 8899
        onvifPath = try values.decodeIfPresent(String.self, forKey: .onvifPath) ?? "/onvif/device_service"
        controlPort = try values.decodeIfPresent(Int.self, forKey: .controlPort) ?? 34567
    }
    mutating func apply(_ device: DiscoveredCamera) {
        host = device.host
        onvifPort = device.onvifPort
        onvifPath = device.onvifPath
    }
}

struct Credentials: Codable, Sendable {
    var username: String
    var password: String
}

enum CredentialStore {
    // Keep the legacy service name so renaming the app preserves saved credentials.
    private static let service = "local.CamMac.camera"
    static func load(_ id: UUID) throws -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try decode(status: status, data: result as? Data)
    }
    static func decode(status: OSStatus, data: Data?) throws -> Credentials? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Could not read macOS Keychain (\(Int(status))). Saved credentials were kept. The prompt asks for your Mac login password.")])
        }
        guard let data else { throw CocoaError(.coderReadCorrupt) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not save in macOS Keychain (\(Int(status))).")])
        }
    }
    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}

@MainActor @Observable
final class CameraStore {
    var cameras: [Camera]
    var sessions: [UUID: CameraSession] = [:]
    private(set) var menuBarCameraID: UUID?
    var menuBarCamera: Camera? { cameras.first { $0.id == menuBarCameraID } ?? cameras.first }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "cameras"),
           let saved = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = saved
        } else {
            cameras = []
        }
        for camera in cameras { sessions[camera.id] = CameraSession() }
        let savedPreview = defaults.string(forKey: "menuBarCameraID").flatMap(UUID.init(uuidString:))
        menuBarCameraID = cameras.contains { $0.id == savedPreview } ? savedPreview : cameras.first?.id
        persistMenuBarCamera()
        persist()
    }
    func selectMenuBarCamera(_ id: UUID) {
        guard cameras.contains(where: { $0.id == id }) else { return }
        menuBarCameraID = id
        persistMenuBarCamera()
    }
    private func persistMenuBarCamera() {
        if let menuBarCameraID { defaults.set(menuBarCameraID.uuidString, forKey: "menuBarCameraID") }
        else { defaults.removeObject(forKey: "menuBarCameraID") }
    }
    func session(_ camera: Camera) -> CameraSession { sessions[camera.id]! }
    func save(_ camera: Camera) {
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            if cameras[index].endpoint != camera.endpoint { sessions[camera.id]?.stop() }
            cameras[index] = camera
        } else {
            cameras.append(camera)
            sessions[camera.id] = CameraSession()
        }
        if menuBarCameraID == nil { selectMenuBarCamera(camera.id) }
        persist()
    }
    func remove(_ camera: Camera) {
        sessions.removeValue(forKey: camera.id)?.stop()
        cameras.removeAll { $0.id == camera.id }
        if menuBarCameraID == camera.id {
            menuBarCameraID = cameras.first?.id
            persistMenuBarCamera()
        }
        CredentialStore.remove(camera.id)
        persist()
    }
    func stopAll() { sessions.values.forEach { $0.stop() } }
    private func persist() {
        if let data = try? JSONEncoder().encode(cameras) { defaults.set(data, forKey: "cameras") }
    }
}
