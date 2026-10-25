import Foundation

@main enum DeviceSettingsEditorTest {
    static func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure.failed(label) }
    }
    enum Failure: Error { case failed(String) }

    static func main() throws {
        let english = Locale(identifier: "en_US")
        let portuguese = Locale(identifier: "pt_BR")
        try require(DeviceSettingsInput.decimal("12.5", locale: english) == Decimal(string: "12.5"), "Decimal input preserves fractional values")
        try require(DeviceSettingsInput.decimal("12,5", locale: portuguese) == Decimal(string: "12.5"), "Native decimal separator is accepted")
        try require(DeviceSettingsInput.decimal("-2.75e2", locale: english) == -275, "Signed exponent input is parsed completely")
        for input in ["", "-", "1.", "1x", "1 2", "1,000", "NaN", "inf", "1e9999", "1e-9999", "123456789012345678901234567890123456789"] {
            try require(DeviceSettingsInput.decimal(input, locale: english) == nil, "Malformed, partial or imprecise numbers stay out of the draft")
        }
        try require(DeviceSettingsInput.isSecret(path: "/Camera/AccessToken"), "Secret values are masked")
        try require(DeviceSettingsInput.isSecret(path: "/Camera/Password/0"), "Secret ancestry is masked")
        try require(!DeviceSettingsInput.isSecret(path: "/Camera/Sharpness"), "Ordinary settings remain readable")
        try require(DeviceSettingsInput.path(parent: "/a~1b", component: "x/y~z") == "/a~1b/x~1y~0z", "Distinct dictionary paths cannot collide")
        try require(DeviceSettingsInput.label("UnknownHTTPMode") == "Unknown HTTP Mode", "Unknown camel case labels remain readable")
        print("PASS: complete Decimal validation, locale separator, secret masking and unambiguous paths")
    }
}
