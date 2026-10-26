import Foundation
import CryptoKit

public func sofiaPassword(_ password: String) -> String {
    let digest = Array(Insecure.MD5.hash(data: Data(password.utf8)))
    let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    let bytes = stride(from: 0, to: digest.count, by: 2).map {
        alphabet[(Int(digest[$0]) + Int(digest[$0 + 1])) % alphabet.count]
    }
    return String(decoding: bytes, as: UTF8.self)
}

public func streamHasTimedOut(elapsed: Duration, sinceLastFrame: Duration?) -> Bool {
    if let sinceLastFrame { return sinceLastFrame > .seconds(12) }
    return elapsed > .seconds(20)
}

public struct CameraEndpoint: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var channel: Int
    public var substream: Bool

    public init(host: String, port: Int = 554, channel: Int = 1, substream: Bool = false) {
        self.host = host
        self.port = port
        self.channel = channel
        self.substream = substream
    }

    public func playlist(username: String, password: String, useSofiaQuery: Bool = false) throws -> Data {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.first?.isLetter == true || host.first?.isNumber == true,
              host.unicodeScalars.allSatisfy(hostCharacters.contains),
              (1...65535).contains(port), (1...64).contains(channel), !username.isEmpty else {
            throw CameraError.invalidEndpoint
        }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let user = username.addingPercentEncoding(withAllowedCharacters: unreserved),
              let secret = password.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw CameraError.invalidEndpoint
        }
        let address = host.contains(":") ? "[\(host)]" : host
        let vendorAuth = useSofiaQuery ? "&password=\(sofiaPassword(password))" : ""
        let uri = "rtsp://\(user):\(secret)@\(address):\(port)/user=\(user)\(vendorAuth)&channel=\(channel)&stream=\(substream ? 1 : 0).sdp?real_stream"
        return Data("""
        ffconcat version 1.0
        file '\(uri)'
        option rtsp_transport tcp
        option timeout 8000000
        option probesize 1000000
        option analyzeduration 1000000

        """.utf8)
    }
}

public enum DecoderFailure: Sendable {
    case authentication, forbidden, unreachable, streamNotFound, videoMissing, hardwareUnavailable
    public var message: String {
        switch self {
        case .authentication: String(localized: "The camera rejected RTSP login (401). Check the device's local username and password.")
        case .forbidden: String(localized: "The camera blocked RTSP access (403). Check the device user's permissions.")
        case .unreachable: String(localized: "Could not reach the camera. Check its address, port and network connection.")
        case .streamNotFound: String(localized: "The camera could not find this stream (404). Check the channel and Substream setting.")
        case .videoMissing: String(localized: "This channel did not provide video. Check the camera settings.")
        case .hardwareUnavailable: String(localized: "Hardware video decoding is unavailable.")
        }
    }
}

public struct DecoderDiagnostics: Sendable {
    public private(set) var failure: DecoderFailure?
    private var tail = ""
    public init() {}
    public mutating func consume(_ data: Data) {
        let text = tail + String(decoding: data, as: UTF8.self).lowercased()
        // Keep only a bounded in-memory window; expose classifications, never raw URLs.
        tail = String(text.suffix(256))
        if text.contains("401 unauthorized") || text.contains("authorization failed") {
            failure = .authentication
        } else if failure == nil {
            if ["no device available for decoder", "device setup failed", "unrecognized hwaccel", "hardware accelerator failed to decode", "failed setup for format videotoolbox"].contains(where: text.contains) { failure = .hardwareUnavailable }
            else if text.contains("403 forbidden") { failure = .forbidden }
            else if text.contains("404 not found") { failure = .streamNotFound }
            else if ["connection refused", "connection timed out", "no route to host", "network is unreachable"].contains(where: text.contains) {
                failure = .unreachable
            } else if text.contains("matches no streams") || text.contains("does not contain any stream") {
                failure = .videoMissing
            }
        }
    }
}

public struct JPEGFramer: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        let start = Data([0xff, 0xd8])
        let end = Data([0xff, 0xd9])
        while let opening = buffer.range(of: start) {
            if opening.lowerBound > buffer.startIndex {
                buffer = Data(buffer[opening.lowerBound...])
            }
            guard let closing = buffer.range(of: end, in: buffer.index(buffer.startIndex, offsetBy: 2)..<buffer.endIndex) else { break }
            frames.append(Data(buffer[..<closing.upperBound]))
            buffer = Data(buffer[closing.upperBound...])
        }
        guard buffer.count <= 16 * 1024 * 1024 else { throw CameraError.frameTooLarge }
        if buffer.range(of: start) == nil, buffer.count > 1 {
            buffer = Data(buffer.suffix(1))
        }
        return frames
    }
}

public enum CameraError: LocalizedError {
    case invalidEndpoint
    case frameTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "Check the camera address, port, channel and username.")
        case .frameTooLarge: String(localized: "The video stream exceeded the frame size limit.")
        }
    }
}
