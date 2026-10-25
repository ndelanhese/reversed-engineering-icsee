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
    var endpoint: CameraEndpoint {
        CameraEndpoint(host: host, port: port, channel: channel, substream: substream)
    }
}

struct Credentials: Codable {
    var username: String
    var password: String
}

enum CredentialStore {
    private static let service = "local.CamMac.camera"
    static func load(_ id: UUID) -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Não foi possível salvar no Chaves do macOS (\(status))."])
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
        persist()
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
        persist()
    }
    func remove(_ camera: Camera) {
        sessions.removeValue(forKey: camera.id)?.stop()
        cameras.removeAll { $0.id == camera.id }
        CredentialStore.remove(camera.id)
        persist()
    }
    func stopAll() { sessions.values.forEach { $0.stop() } }
    private func persist() {
        if let data = try? JSONEncoder().encode(cameras) { defaults.set(data, forKey: "cameras") }
    }
}
