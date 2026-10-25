import Foundation

struct ONVIFDevice: Sendable { let profiles: [ONVIFProfile] }
struct ONVIFProfile: Sendable, Identifiable, Equatable {
    let token: String
    let name: String
    let videoSourceToken: String?
    let ptzConfigurationToken: String?
    var id: String { token }
}
struct ONVIFPTZOptions: Sendable {
    let panRange: ClosedRange<Double>?
    let tiltRange: ClosedRange<Double>?
    let zoomRange: ClosedRange<Double>?
    let minTimeout: Double
    let maxTimeout: Double
}
struct ONVIFPreset: Sendable, Identifiable, Equatable {
    let token: String
    let name: String
    var id: String { token }
}
struct ONVIFImagingSetting: Sendable, Identifiable, Equatable {
    let path: String
    let value: String
    let range: ClosedRange<Double>?
    let choices: [String]
    let isWritable: Bool
    var id: String { path }
}
enum ONVIFError: Error, LocalizedError, Equatable {
    case invalidInput, unsupported, unauthorized, invalidResponse, deviceFault, transport, verificationFailed, conflict
    var errorDescription: String? {
        switch self {
        case .invalidInput: String(localized: "The camera control value is invalid.")
        case .unsupported: String(localized: "The camera does not advertise this control.")
        case .unauthorized: String(localized: "The camera rejected authentication or control permission.")
        case .invalidResponse: String(localized: "The camera returned an invalid control response.")
        case .deviceFault: String(localized: "The camera rejected this operation.")
        case .transport: String(localized: "The camera control connection failed.")
        case .verificationFailed: String(localized: "The camera did not confirm the requested value.")
        case .conflict: String(localized: "The camera value changed. Refresh before applying again.")
        }
    }
}
