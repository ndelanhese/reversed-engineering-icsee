import SwiftUI

// Disambiguate the property wrapper from the newer State macro in the SDK.
private typealias SettingsEditorState<Value> = SwiftUI.State<Value>

/// Edits existing scalar leaves only; applying a draft remains the caller's responsibility.
struct DeviceSettingsEditor: View {
    @Binding var value: DeviceJSON
    @Binding var invalidPaths: Set<String>
    var readOnly = false

    var body: some View {
        DeviceSettingsNode(value: $value, invalidPaths: $invalidPaths,
            title: String(localized: "Settings"), path: "", depth: 0, readOnly: readOnly)
            .controlSize(.small)
    }
}

private struct DeviceSettingsNode: View {
    @Binding var value: DeviceJSON
    @Binding var invalidPaths: Set<String>
    let title: String
    let path: String
    let depth: Int
    let readOnly: Bool
    @SettingsEditorState private var visibleCount = 64
    @SettingsEditorState private var expanded: Bool?

    private var expansion: Binding<Bool> {
        Binding(get: { expanded ?? (depth == 0) }, set: { expanded = $0 })
    }

    var body: some View {
        switch value {
        case .object(let object):
            if depth >= 16 {
                limitRow
            } else {
                DisclosureGroup(isExpanded: expansion) {
                    if object.isEmpty { Text("No fields").foregroundStyle(.secondary) }
                    ForEach(Array(object.keys.sorted().prefix(visibleCount)), id: \.self) { key in
                        child(objectBinding(key), title: DeviceSettingsInput.label(key), component: key)
                    }
                    showMore(total: object.count)
                } label: { Text(verbatim: title) }
            }
        case .array(let array):
            if depth >= 16 {
                limitRow
            } else {
                DisclosureGroup(isExpanded: expansion) {
                    if array.isEmpty { Text("No items").foregroundStyle(.secondary) }
                    ForEach(0..<min(array.count, visibleCount), id: \.self) { index in
                        child(arrayBinding(index), title: String(localized: "Item \(index + 1)"), component: String(index))
                    }
                    showMore(total: array.count)
                } label: { Text(verbatim: title) }
            }
        case .bool:
            Toggle(isOn: Binding(get: {
                if case .bool(let flag) = value { return flag }
                return false
            }, set: { if !readOnly { value = .bool($0) } })) { Text(verbatim: title) }
                .disabled(readOnly)
        case .string, .number:
            DeviceSettingsScalar(value: $value, invalidPaths: $invalidPaths,
                title: title, path: path, readOnly: readOnly)
        case .null:
            LabeledContent { Text("No value").foregroundStyle(.secondary) } label: { Text(verbatim: title) }
        }
    }

    private var limitRow: some View {
        LabeledContent { Text("Nesting limit reached").foregroundStyle(.secondary) } label: { Text(verbatim: title) }
    }

    // A single erasure breaks the recursive SwiftUI view type; depth bounds construction.
    private func child(_ binding: Binding<DeviceJSON>, title: String, component: String) -> AnyView {
        AnyView(DeviceSettingsNode(value: binding, invalidPaths: $invalidPaths, title: title,
            path: DeviceSettingsInput.path(parent: path, component: component), depth: depth + 1, readOnly: readOnly))
    }

    @ViewBuilder private func showMore(total: Int) -> some View {
        if visibleCount < total {
            Button("Show more") { visibleCount = min(total, visibleCount + 64) }
        }
    }

    private func objectBinding(_ key: String) -> Binding<DeviceJSON> {
        Binding(get: {
            guard case .object(let object) = value else { return .null }
            return object[key] ?? .null
        }, set: { replacement in
            guard !readOnly, case .object(var object) = value, let old = object[key],
                  (try? replacement.edits(from: old)) != nil else { return }
            object[key] = replacement
            value = .object(object)
        })
    }

    private func arrayBinding(_ index: Int) -> Binding<DeviceJSON> {
        Binding(get: {
            guard case .array(let array) = value, array.indices.contains(index) else { return .null }
            return array[index]
        }, set: { replacement in
            guard !readOnly, case .array(var array) = value, array.indices.contains(index),
                  (try? replacement.edits(from: array[index])) != nil else { return }
            array[index] = replacement
            value = .array(array)
        })
    }
}

private struct DeviceSettingsScalar: View {
    @Binding var value: DeviceJSON
    @Binding var invalidPaths: Set<String>
    let title: String
    let path: String
    let readOnly: Bool
    @SettingsEditorState private var draft: String?
    @Environment(\.locale) private var locale

    private var text: Binding<String> {
        Binding(get: { draft ?? currentText }, set: { input in
            guard !readOnly else { return }
            draft = input
            switch value {
            case .string:
                value = .string(input)
                invalidPaths.remove(path)
            case .number:
                if let number = DeviceSettingsInput.decimal(input, locale: locale) {
                    value = .number(number)
                    invalidPaths.remove(path)
                } else {
                    invalidPaths.insert(path)
                }
            default: break
            }
        })
    }

    private var currentText: String {
        switch value {
        case .string(let string): string
        case .number(let number): NSDecimalNumber(decimal: number).stringValue
        default: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if DeviceSettingsInput.isSecret(path: path) {
                SecureField(text: text) { Text(verbatim: title) }
            } else {
                TextField(text: text) { Text(verbatim: title) }
            }
            if invalidPaths.contains(path) {
                Text("Enter a valid number.").font(.caption).foregroundStyle(.red)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(readOnly)
    }
}

enum DeviceSettingsInput {
    static func decimal(_ input: String, locale: Locale) -> Decimal? {
        let separator = locale.decimalSeparator ?? "."
        let normalized = separator == "." ? input : input.replacingOccurrences(of: separator, with: ".")
        guard normalized.count <= 256,
              normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        // Decimal can silently round oversized mantissas. Reject them before parsing.
        let mantissa = normalized.split(whereSeparator: { $0 == "e" || $0 == "E" })[0]
        let significant = mantissa.filter(\.isNumber).drop(while: { $0 == "0" })
        guard significant.count <= 38,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    static func path(parent: String, component: String) -> String {
        parent + "/" + component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    static func isSecret(path: String) -> Bool {
        let normalized = path.lowercased().filter(\.isLetter)
        return ["password", "passwd", "passphrase", "secret", "token", "credential", "privatekey", "accesskey", "pwd"]
            .contains(where: normalized.contains)
    }

    static func label(_ key: String) -> String {
        switch key.lowercased() {
        case "enable", "enabled": return String(localized: "Enabled")
        case "name": return String(localized: "Name")
        case "brightness": return String(localized: "Brightness")
        case "contrast": return String(localized: "Contrast")
        case "saturation": return String(localized: "Saturation")
        case "sharpness": return String(localized: "Sharpness")
        case "hue": return String(localized: "Hue")
        case "exposure": return String(localized: "Exposure")
        case "gain": return String(localized: "Gain")
        case "volume": return String(localized: "Volume")
        case "mirror": return String(localized: "Mirror")
        case "flip": return String(localized: "Flip")
        case "mode": return String(localized: "Mode")
        case "quality": return String(localized: "Quality")
        case "resolution": return String(localized: "Resolution")
        case "framerate": return String(localized: "Frame rate")
        case "bitrate": return String(localized: "Bit rate")
        default:
            return key.replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
        }
    }
}
