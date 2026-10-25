import Foundation

/// JSON values retain decimal precision and unknown configuration fields.
enum DeviceJSON: Codable, Equatable, Sendable {
    case object([String: DeviceJSON]), array([DeviceJSON]), string(String), number(Decimal), bool(Bool), null

    /// Reject out-of-range numeric literals rather than silently rounding unknown fields.
    static func decode(_ data: Data) throws -> DeviceJSON {
        guard data.count <= 2 * 1024 * 1024 else { throw DVRIPError.responseTooLarge }
        let bytes = Array(data)
        var index = 0
        var quoted = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                index += 1
            } else if byte == 34 {
                quoted = true; index += 1
            } else if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count, ![UInt8(9), 10, 13, 32, 44, 93, 125, 58].contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.utf8.count <= 512,
                      let decimal = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN,
                      let source = normalizedNumber(token),
                      source == normalizedNumber(NSDecimalNumber(decimal: decimal).stringValue) else { throw DVRIPError.malformed }
            } else { index += 1 }
        }
        do { return try JSONDecoder().decode(DeviceJSON.self, from: data) }
        catch { throw DVRIPError.malformed }
    }

    private static func normalizedNumber(_ token: String) -> String? {
        let parts = token.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let exponent: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (-1000...1000).contains(parsed) else { return nil }
            exponent = parsed
        } else { exponent = 0 }
        var mantissa = String(parts[0])
        let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        var digits = decimal.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var power = exponent - (decimal.count == 2 ? decimal[1].count : 0)
        while digits.first == "0" { digits.removeFirst() }
        guard !digits.isEmpty else { return "0" }
        while digits.last == "0" { digits.removeLast(); power += 1 }
        return (negative ? "-" : "") + digits + "e" + String(power)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: DeviceJSON].self) { self = .object(value) }
        else { self = .array(try container.decode([DeviceJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value):
            guard !value.isNaN else { throw DVRIPError.invalidEdit }
            try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func prettyPrinted() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func value(at path: [DeviceJSONPathComponent]) throws -> DeviceJSON {
        guard path.count <= 128 else { throw DVRIPError.invalidEdit }
        var result = self
        for component in path {
            switch (result, component) {
            case (.object(let object), .key(let key)):
                guard let child = object[key] else { throw DVRIPError.invalidEdit }; result = child
            case (.array(let array), .index(let index)):
                guard array.indices.contains(index) else { throw DVRIPError.invalidEdit }; result = array[index]
            default: throw DVRIPError.invalidEdit
            }
        }
        return result
    }

    /// Replacement cannot add fields, remove array positions or change a JSON type.
    func replacing(at path: [DeviceJSONPathComponent], with replacement: DeviceJSON) throws -> DeviceJSON {
        guard path.count <= 128 else { throw DVRIPError.invalidEdit }
        guard let first = path.first else {
            _ = try replacement.edits(from: self)
            return replacement
        }
        let remainder = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var object), .key(let key)):
            guard let child = object[key] else { throw DVRIPError.invalidEdit }
            object[key] = try child.replacing(at: remainder, with: replacement)
            return .object(object)
        case (.array(var array), .index(let index)):
            guard array.indices.contains(index) else { throw DVRIPError.invalidEdit }
            array[index] = try array[index].replacing(at: remainder, with: replacement)
            return .array(array)
        default: throw DVRIPError.invalidEdit
        }
    }

    func edits(from original: DeviceJSON) throws -> [DeviceJSONEdit] {
        var result: [DeviceJSONEdit] = []
        try collectEdits(from: original, path: [], result: &result)
        return result
    }

    private func collectEdits(from original: DeviceJSON, path: [DeviceJSONPathComponent], result: inout [DeviceJSONEdit]) throws {
        guard path.count <= 128 else { throw DVRIPError.invalidEdit }
        switch (original, self) {
        case (.object(let old), .object(let new)):
            guard old.keys == new.keys else { throw DVRIPError.invalidEdit }
            for key in old.keys.sorted() {
                guard let before = old[key], let after = new[key] else { throw DVRIPError.invalidEdit }
                try after.collectEdits(from: before, path: path + [.key(key)], result: &result)
            }
        case (.array(let old), .array(let new)):
            guard old.count == new.count else { throw DVRIPError.invalidEdit }
            for index in old.indices { try new[index].collectEdits(from: old[index], path: path + [.index(index)], result: &result) }
        case (.string, .string), (.number, .number), (.bool, .bool), (.null, .null):
            if original != self { result.append(DeviceJSONEdit(path: path, original: original, updated: self)) }
        default: throw DVRIPError.invalidEdit
        }
    }

    /// Apply only edited leaves to a freshly read value, rejecting overlapping changes.
    func applying(edits: [DeviceJSONEdit]) throws -> DeviceJSON {
        var result = self
        for edit in edits {
            guard let fresh = try? result.value(at: edit.path), fresh == edit.original else { throw DVRIPError.conflict }
            result = try result.replacing(at: edit.path, with: edit.updated)
        }
        return result
    }
}

enum DeviceJSONPathComponent: Hashable, Sendable { case key(String), index(Int) }
struct DeviceJSONEdit: Equatable, Sendable {
    let path: [DeviceJSONPathComponent]
    let original: DeviceJSON
    let updated: DeviceJSON
}

struct DVRIPWriteResult: Sendable {
    let value: DeviceJSON
    let requiresRestart: Bool
    let verified: Bool
    init(value: DeviceJSON, requiresRestart: Bool, verified: Bool = true) {
        self.value = value; self.requiresRestart = requiresRestart; self.verified = verified
    }
}

enum DVRIPError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint, invalidSection, disconnected, authentication, forbidden, unsupported, timeout
    case malformed, unsupportedFragment, responseTooLarge, rejected, invalidEdit, conflict, verification, writeUncertain
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "Check the camera control address, port and username.")
        case .invalidSection: String(localized: "This section is not available through generic local settings.")
        case .disconnected: String(localized: "The camera control connection is closed. Authenticate again.")
        case .authentication: String(localized: "The camera rejected the control credentials.")
        case .forbidden: String(localized: "This camera account cannot perform this control action.")
        case .unsupported: String(localized: "This setting is not supported by this camera.")
        case .timeout: String(localized: "The camera control request timed out.")
        case .malformed: String(localized: "The camera returned an invalid control response.")
        case .unsupportedFragment: String(localized: "The camera uses an unsupported fragmented control response.")
        case .responseTooLarge: String(localized: "The camera control response exceeded the size limit.")
        case .rejected: String(localized: "The camera rejected this setting.")
        case .invalidEdit: String(localized: "Keep the existing fields, array positions and value types.")
        case .conflict: String(localized: "This value changed on the camera. Refresh before applying your edit.")
        case .verification: String(localized: "The camera did not return the requested value. Refresh to inspect its current setting.")
        case .writeUncertain: String(localized: "The setting may have changed, but the camera did not confirm it. Reconnect and refresh before applying again.")
        }
    }
}
