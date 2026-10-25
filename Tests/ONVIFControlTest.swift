import Foundation
import CryptoKit

private func response(_ action: String, _ body: String = "", service: String = "ptz") -> String {
    let namespaces = ["device": "http://www.onvif.org/ver10/device/wsdl", "media": "http://www.onvif.org/ver10/media/wsdl", "ptz": "http://www.onvif.org/ver20/ptz/wsdl", "imaging": "http://www.onvif.org/ver20/imaging/wsdl"]
    return "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body><x:\(action)Response xmlns:x=\"\(namespaces[service]!)\">\(body)</x:\(action)Response></s:Body></s:Envelope>"
}
private struct Reply: Sendable {
    let body: String
    var status = 200
    var headers: [String: String] = [:]
    var delay: Int = 0
}
private actor ONVIFMock {
    var requests: [URLRequest] = []
    var replies: [Reply]
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> ONVIFHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw ONVIFError.transport }
        let reply = replies.removeFirst()
        if reply.delay > 0 { try await Task.sleep(for: .milliseconds(reply.delay)) }
        return ONVIFHTTPResponse(status: reply.status, headers: reply.headers, body: Data(reply.body.utf8))
    }
    func bodies() -> [String] { requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
    func allRequests() -> [URLRequest] { requests }
}

private actor ONVIFWatchdogMock {
    var stopCount = 0
    func send(_ request: URLRequest) -> ONVIFHTTPResponse {
        let action = request.value(forHTTPHeaderField: "SOAPAction") ?? ""
        let xml: String
        if action.contains("GotoPreset") { xml = response("GotoPreset") }
        else if action.contains("Stop") { stopCount += 1; xml = response("Stop") }
        else { xml = response("GetStatus", "<PTZStatus><MoveStatus><PanTilt>MOVING</PanTilt></MoveStatus></PTZStatus>") }
        return ONVIFHTTPResponse(status: 200, headers: [:], body: Data(xml.utf8))
    }
}

@main enum ONVIFControlTest {
    static let profile = ONVIFProfile(token: "profile<&", name: "Synthetic", videoSourceToken: "source1", ptzConfigurationToken: "ptz1")
    static let options = "<PTZConfigurationOptions><Spaces><ContinuousPanTiltVelocitySpace><URI>urn:test:pan</URI><XRange><Min>-1</Min><Max>1</Max></XRange><YRange><Min>-1</Min><Max>1</Max></YRange></ContinuousPanTiltVelocitySpace></Spaces><PTZTimeout><Min>PT0.1S</Min><Max>PT5S</Max></PTZTimeout></PTZConfigurationOptions>"
    static let imageOptions = "<ImagingOptions><Brightness><Min>0</Min><Max>100</Max></Brightness><WhiteBalance><Mode>AUTO</Mode><Mode>MANUAL</Mode></WhiteBalance><IrCutFilterModes>ON</IrCutFilterModes><IrCutFilterModes>OFF</IrCutFilterModes></ImagingOptions>"
    static func image(_ brightness: Int, contrast: Int = 7) -> String {
        "<ImagingSettings xmlns=\"http://www.onvif.org/ver10/schema\"><Brightness>\(brightness)</Brightness><Contrast>\(contrast)</Contrast><WhiteBalance><Mode>AUTO</Mode><CrGain>12</CrGain></WhiteBalance><IrCutFilter>ON</IrCutFilter><Extension><v:Opaque xmlns:v=\"urn:synthetic:vendor\" v:flag=\"keep\">42</v:Opaque><Unqualified xmlns=\"\"><Leaf>preserved</Leaf></Unqualified></Extension></ImagingSettings>"
    }
    private static func client(_ mock: ONVIFMock, authenticated: Bool = false) -> ONVIFClient {
        ONVIFClient(host: "192.0.2.10", username: authenticated ? "synthetic-user" : nil, password: authenticated ? "synthetic-secret" : nil, transport: { try await mock.send($0) })
    }
    static func expect(_ expected: ONVIFError, _ operation: @Sendable () async throws -> Void) async throws {
        do { try await operation(); throw Failure.failed("Expected safe error") }
        catch let error as ONVIFError { guard error == expected else { throw Failure.failed("Unexpected safe error") } }
    }
    enum Failure: Error { case failed(String) }
    static func check(_ condition: Bool, _ label: String) throws { if !condition { throw Failure.failed(label) } }
    private static func waitForRequest(_ mock: ONVIFMock, count: Int) async throws {
        for _ in 0..<100 {
            if await mock.allRequests().count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.failed("Synthetic request did not start")
    }

    static func main() async throws {
        if let mode = CommandLine.arguments.dropFirst().first, mode.hasPrefix("--review-") {
            switch mode {
            case "--review-batch-imaging": try await batchImaging()
            case "--review-namespace": try await imagingPreservation()
            case "--review-path": try await digestRegression(algorithm: "SHA-256", qop: true)
            case "--review-md5-sess": try await digestRegression(algorithm: "MD5-SESS", qop: false)
            case "--review-sha256-sess": try await digestRegression(algorithm: "SHA-256-SESS", qop: false)
            default: throw Failure.failed("Unknown review regression")
            }
            print("PASS: \(mode)")
            return
        }
        if CommandLine.arguments.dropFirst().first == "--watchdog" {
            let mock = ONVIFWatchdogMock()
            let c = ONVIFClient(host: "192.0.2.10", transport: { await mock.send($0) })
            let start = ContinuousClock.now
            try await expect(.verificationFailed) { try await c.gotoPreset(profile: profile, token: "one") }
            let stops = await mock.stopCount
            let elapsed = start.duration(to: .now)
            print("Watchdog synthetic evidence: stops=\(stops), elapsed=\(elapsed)")
            try check(stops == 1 && elapsed < .seconds(17), "Preset watchdog bounded movement with Stop")
            print("PASS: preset 15-second watchdog sends Stop and reports failed verification")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native-redirect", let port = Int(CommandLine.arguments[2]) {
            let native = ONVIFClient(host: "127.0.0.1", port: port, username: "synthetic-user", password: "synthetic-secret")
            try await expect(.invalidResponse) { _ = try await native.presets(profile: profile) }
            print("PASS: native HTTP redirect refused")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native-http", let port = Int(CommandLine.arguments[2]) {
            let native = ONVIFClient(host: "127.0.0.1", port: port, username: "synthetic-user", password: "synthetic-secret")
            let device = try await native.discover()
            try check(device.profiles.count == 1, "Native HTTP Digest discovery")
            print("PASS: native HTTP transport with Digest")
            return
        }
        try await digestRegression(algorithm: "SHA-256", qop: true)
        try await digestRegression(algorithm: "MD5-SESS", qop: false)
        try await digestRegression(algorithm: "SHA-256-SESS", qop: false)
        try await discoveryAndSecurity()
        try await movementAndPresets()
        try await imagingPreservation()
        try await batchImaging()
        try await cancellations()
        print("PASS: ONVIF discovery, namespaces, authentication, safe faults/XML, bounded movement/Stop, presets, imaging preservation/conflicts/readback, cancellation")
    }
    static func digestRegression(algorithm: String, qop: Bool) async throws {
        let path = "/media%20service%2Fchannel"
        let services = "<Service><Namespace>http://www.onvif.org/ver10/media/wsdl</Namespace><XAddr>http://192.0.2.10:8899\(path)</XAddr></Service>"
        let challenge = "Digest realm=\"test\", nonce=\"nonce\", algorithm=\(algorithm)" + (qop ? ", qop=\"auth\"" : "")
        let mock = ONVIFMock([Reply(body: "", status: 401, headers: ["www-authenticate": challenge]), Reply(body: response("GetServices", services, service: "device")), Reply(body: response("GetProfiles", service: "media"))])
        _ = try await client(mock, authenticated: true).discover()
        let requests = await mock.allRequests()
        for (index, request) in requests.enumerated() where index > 0 {
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let regex = try NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)=(?:"([^"]*)"|([^,\s]+))"#)
            let source = header as NSString
            var fields: [String: String] = [:]
            for match in regex.matches(in: header, range: NSRange(location: 0, length: source.length)) {
                let capture = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
                fields[source.substring(with: match.range(at: 1))] = source.substring(with: capture)
            }
            if algorithm.hasSuffix("-SESS") {
                try check(!(fields["cnonce"] ?? "").isEmpty, "Session Digest sends cnonce without qop: \(algorithm)")
                try check(fields["qop"] == nil && fields["nc"] == nil, "No-qop session Digest omits qop and nc")
            }
            let uri = index == 1 ? "/onvif/device_service" : path
            try check(fields["uri"] == uri, "Digest uses the percent-encoded request-target")
            func hash(_ input: String) -> String {
                let data = Data(input.utf8)
                let bytes = algorithm.hasPrefix("SHA-256") ? Array(SHA256.hash(data: data)) : Array(Insecure.MD5.hash(data: data))
                return bytes.map { String(format: "%02x", $0) }.joined()
            }
            var ha1 = hash("synthetic-user:test:synthetic-secret")
            if algorithm.hasSuffix("-SESS") { ha1 = hash("\(ha1):nonce:\(fields["cnonce"] ?? "")") }
            let ha2 = hash("POST:\(uri)")
            let expected = qop ? hash("\(ha1):nonce:\(fields["nc"] ?? ""):\(fields["cnonce"] ?? ""):auth:\(ha2)") : hash("\(ha1):nonce:\(ha2)")
            try check(fields["response"] == expected, "Digest response hashes the encoded URI and advertised session nonce")
        }
    }
    static func discoveryAndSecurity() async throws {
        let services = "<Service><Namespace>http://www.onvif.org/ver10/media/wsdl</Namespace><XAddr>http://192.0.2.10:8899/media</XAddr></Service>"
        let profiles = "<Profiles token=\"main&amp;token\"><Name>Primary</Name><VideoSourceConfiguration><SourceToken>source1</SourceToken></VideoSourceConfiguration><PTZConfiguration token=\"ptz1\"/></Profiles><Profiles token=\"sub\"><Name>Sub</Name></Profiles>"
        let mock = ONVIFMock([Reply(body: response("GetServices", services, service: "device")), Reply(body: response("GetProfiles", profiles, service: "media"))])
        let c = client(mock)
        let device = try await c.discover()
        try check(device.profiles.count == 2 && device.profiles[0].token == "main&token" && device.profiles[1].videoSourceToken == nil, "Profile tokens and optional capabilities")
        try await expect(.unsupported) { _ = try await c.ptzOptions(profile: profile) }
        let evil = ONVIFMock([Reply(body: response("GetServices", services.replacingOccurrences(of: "192.0.2.10", with: "192.0.2.99"), service: "device"))])
        try await expect(.invalidResponse) { _ = try await client(evil).discover() }
        try check(await evil.allRequests().count == 1, "Foreign services never contacted")
        let challenge = Reply(body: "", status: 401, headers: ["www-authenticate": "Digest realm=\"test\", nonce=\"nonce\", qop=\"auth,auth-int\", algorithm=SHA-256"])
        let auth = ONVIFMock([challenge, Reply(body: response("GetServices", services, service: "device")), Reply(body: response("GetProfiles", profiles, service: "media"))])
        _ = try await client(auth, authenticated: true).discover()
        let requests = await auth.allRequests()
        try check(requests[1].value(forHTTPHeaderField: "Authorization")?.contains("qop=auth") == true, "Digest qop negotiation")
        let authenticatedBody = String(decoding: requests[1].httpBody!, as: UTF8.self)
        try check(authenticatedBody.contains("PasswordDigest") && !authenticatedBody.contains("synthetic-secret"), "WSSE digest has no plaintext password")
        let noReplay = ONVIFMock([challenge])
        try await expect(.unauthorized) { _ = try await client(noReplay, authenticated: true).savePreset(profile: profile, name: "Example") }
        try check(await noReplay.allRequests().count == 1, "Write authentication never replays")
        let fault = "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body><s:Fault><s:Code><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code><s:Reason>private fault content</s:Reason></s:Fault></s:Body></s:Envelope>"
        try await expect(.unauthorized) { _ = try await client(ONVIFMock([Reply(body: fault, status: 500)])).presets(profile: profile) }
        try check(!(ONVIFError.deviceFault.errorDescription ?? "").contains("private"), "Fault text stays private")
        for xml in ["<!DOCTYPE r [<!ENTITY x 'expanded'>]><r>&x;</r>", "<r>" + String(repeating: "<a>", count: 45) + String(repeating: "</a>", count: 45) + "</r>", String(repeating: "x", count: 2 * 1024 * 1024 + 1), "<r/>"] {
            try await expect(.invalidResponse) { _ = try await client(ONVIFMock([Reply(body: xml)])).presets(profile: profile) }
        }
        try await expect(.invalidResponse) { _ = try await client(ONVIFMock([Reply(body: "", status: 302, headers: ["Location": "http://192.0.2.99/"])]), authenticated: true).presets(profile: profile) }
    }
    static func movementAndPresets() async throws {
        let mock = ONVIFMock([Reply(body: response("GetConfigurationOptions", options)), Reply(body: response("ContinuousMove")), Reply(body: response("Stop"))])
        let c = client(mock)
        let capability = try await c.ptzOptions(profile: profile)
        try check(capability.zoomRange == nil && capability.panRange == -1...1, "Advertised axes only")
        try await expect(.invalidInput) { try await c.move(profile: profile, pan: 2, tilt: 0, zoom: 0, timeout: 1) }
        try await expect(.unsupported) { try await c.move(profile: profile, pan: 0, tilt: 0, zoom: 1, timeout: 1) }
        try await expect(.invalidInput) { try await c.move(profile: profile, pan: .nan, tilt: 0, zoom: 0, timeout: 1) }
        try await c.move(profile: profile, pan: 0.5, tilt: 0, zoom: 0, timeout: 20)
        try await c.stop(profile: profile)
        let bodies = await mock.bodies()
        try check(bodies.count == 3 && bodies[1].contains("PT1S") && bodies[1].contains("profile&lt;&amp;") && bodies[2].contains("Stop"), "Bounds, escaping, and Stop")
        let minimum = ONVIFMock([Reply(body: response("GetConfigurationOptions", options)), Reply(body: response("ContinuousMove"))])
        try await client(minimum).move(profile: profile, pan: 0.5, tilt: 0, zoom: 0, timeout: 0.001)
        try check(await minimum.bodies()[1].contains("PT0.1S"), "Advertised minimum timeout respected")
        let unsafe = ONVIFMock([Reply(body: response("GetConfigurationOptions", options.replacingOccurrences(of: "PT0.1S", with: "PT2S")))])
        try await expect(.unsupported) { try await client(unsafe).move(profile: profile, pan: 1, tilt: 0, zoom: 0, timeout: 0.2) }
        let empty = ONVIFMock([Reply(body: response("GetPresets"))])
        try check(try await client(empty).presets(profile: profile).isEmpty, "Empty presets are a successful empty list")
        let presets = ONVIFMock([Reply(body: response("GetPresets", "<Preset token=\"one\"><Name>Desk</Name></Preset>")), Reply(body: response("SetPreset", "<PresetToken>two</PresetToken>")), Reply(body: response("GotoPreset")), Reply(body: response("GetStatus", "<PTZStatus><MoveStatus><PanTilt>IDLE</PanTilt><Zoom>IDLE</Zoom></MoveStatus></PTZStatus>"))])
        let pc = client(presets)
        try check(try await pc.presets(profile: profile).first?.name == "Desk", "Preset parsing")
        try check(try await pc.savePreset(profile: profile, name: "New") == "two", "Save returns actual token")
        try await pc.gotoPreset(profile: profile, token: "one")
        try check(await presets.allRequests().count == 4, "Preset polls actual idle without replay")
    }
    static func imagingPreservation() async throws {
        let mock = ONVIFMock([Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50, contrast: 2), service: "imaging")), Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging")), Reply(body: response("SetImagingSettings", service: "imaging")), Reply(body: response("GetImagingSettings", image(60), service: "imaging"))])
        let c = client(mock)
        let fields = try await c.imaging(profile: profile)
        try check(fields.first { $0.path == "Brightness" }?.range == 0...100, "Actual numeric options")
        try check(fields.first { $0.path == "WhiteBalance.Mode" }?.choices == ["AUTO", "MANUAL"], "Actual enum options")
        try check(fields.first { $0.path == "WhiteBalance.CrGain" }?.isWritable == false, "Unadvertised fields remain readonly")
        try check(fields.first { $0.path == "IrCutFilter" }?.choices == ["ON", "OFF"], "Option plural aliases")
        try await c.setImaging(profile: profile, path: "Brightness", value: "60")
        let written = await mock.bodies()[4]
        try check(written.contains(">7</Contrast>") && written.contains("urn:synthetic:vendor") && written.contains("v:flag=\"keep\""), "Fresh unrelated fields and extension namespaces preserved")
        try check(written.contains("<Unqualified xmlns=\"\"") && written.contains("<Leaf xmlns=\"\""), "Namespace-reset extension survives an unrelated image edit")
        let conflict = ONVIFMock([Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging")), Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(51), service: "imaging"))])
        let cc = client(conflict)
        _ = try await cc.imaging(profile: profile)
        try await expect(.conflict) { try await cc.setImaging(profile: profile, path: "Brightness", value: "60") }
        try check(await conflict.allRequests().count == 4, "Conflicting leaf is never written")
        let invalid = ONVIFMock([Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging")), Reply(body: response("GetOptions", imageOptions, service: "imaging"))])
        let ic = client(invalid)
        _ = try await ic.imaging(profile: profile)
        try await expect(.invalidInput) { try await ic.setImaging(profile: profile, path: "Brightness", value: "101") }
        let mismatch = ONVIFMock([Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging")), Reply(body: response("GetOptions", imageOptions, service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging")), Reply(body: response("SetImagingSettings", service: "imaging")), Reply(body: response("GetImagingSettings", image(50), service: "imaging"))])
        let mc = client(mismatch)
        _ = try await mc.imaging(profile: profile)
        try await expect(.verificationFailed) { try await mc.setImaging(profile: profile, path: "Brightness", value: "60") }
    }
    static func batchImaging() async throws {
        let options = imageOptions.replacingOccurrences(of: "</ImagingOptions>", with: "<Contrast><Min>0</Min><Max>100</Max></Contrast></ImagingOptions>")
        let mock = ONVIFMock([
            Reply(body: response("GetOptions", options, service: "imaging")),
            Reply(body: response("GetImagingSettings", image(50, contrast: 2), service: "imaging")),
            Reply(body: response("GetOptions", options, service: "imaging")),
            Reply(body: response("GetImagingSettings", image(50, contrast: 3), service: "imaging")),
            Reply(body: response("SetImagingSettings", service: "imaging")),
            Reply(body: response("GetImagingSettings", image(60, contrast: 3), service: "imaging")),
            Reply(body: response("GetOptions", options, service: "imaging")),
            Reply(body: response("GetImagingSettings", image(60, contrast: 3), service: "imaging")),
            Reply(body: response("SetImagingSettings", service: "imaging")),
            Reply(body: response("GetImagingSettings", image(60, contrast: 4), service: "imaging"))
        ])
        let c = client(mock)
        _ = try await c.imaging(profile: profile)
        try await expect(.conflict) {
            try await c.setImaging(profile: profile, changes: ["Brightness": "60", "Contrast": "4"])
        }
        try check(await mock.allRequests().count == 4, "Every edited leaf conflicts before any batch write")
        for confirmedContrast in [4, 2] {
            let fresh = image(50, contrast: 2).replacingOccurrences(of: ">ON</IrCutFilter>", with: ">OFF</IrCutFilter>")
            let write = ONVIFMock([
                Reply(body: response("GetOptions", options, service: "imaging")),
                Reply(body: response("GetImagingSettings", image(50, contrast: 2), service: "imaging")),
                Reply(body: response("GetOptions", options, service: "imaging")),
                Reply(body: response("GetImagingSettings", fresh, service: "imaging")),
                Reply(body: response("SetImagingSettings", service: "imaging")),
                Reply(body: response("GetImagingSettings", image(60, contrast: confirmedContrast), service: "imaging"))
            ])
            let wc = client(write)
            _ = try await wc.imaging(profile: profile)
            if confirmedContrast == 4 {
                try await wc.setImaging(profile: profile, changes: ["Brightness": "60", "Contrast": "4"])
            } else {
                try await expect(.verificationFailed) { try await wc.setImaging(profile: profile, changes: ["Brightness": "60", "Contrast": "4"]) }
            }
            let bodies = await write.bodies()
            try check(bodies.count == 6 && bodies.filter { $0.contains("<timg:SetImagingSettings>") }.count == 1, "Batch performs exactly one settings write and readback")
            try check(bodies[4].contains(">60</Brightness>") && bodies[4].contains(">4</Contrast>") && bodies[4].contains(">OFF</IrCutFilter>") && bodies[4].contains("<Unqualified xmlns=\"\""), "Batch changes selected leaves and preserves fresh unrelated extensions")
        }
        let invalid = ONVIFMock([
            Reply(body: response("GetOptions", options, service: "imaging")),
            Reply(body: response("GetImagingSettings", image(50, contrast: 2), service: "imaging")),
            Reply(body: response("GetOptions", options, service: "imaging"))
        ])
        let ic = client(invalid)
        _ = try await ic.imaging(profile: profile)
        try await expect(.invalidInput) { try await ic.setImaging(profile: profile, changes: ["Brightness": "60", "Contrast": "101"]) }
        try check(await invalid.allRequests().count == 3, "All selected values validate before any batch write")
    }
    static func cancellations() async throws {
        let mock = ONVIFMock([Reply(body: response("GetConfigurationOptions", options)), Reply(body: response("ContinuousMove"), delay: 2000), Reply(body: response("Stop"))])
        let c = client(mock)
        let movement = Task { try await c.move(profile: profile, pan: 0.5, tilt: 0, zoom: 0, timeout: 0.2) }
        try await waitForRequest(mock, count: 2)
        try await c.stop(profile: profile)
        do { try await movement.value; throw Failure.failed("Stopped request succeeded") } catch is CancellationError { }
        try check(await mock.allRequests().count == 3, "In-flight movement cancelled then Stop, with no replay")
        let delayed = ONVIFMock([Reply(body: response("GetConfigurationOptions", options), delay: 100), Reply(body: response("Stop"))])
        let dc = client(delayed)
        let stale = Task { try await dc.move(profile: profile, pan: 0.5, tilt: 0, zoom: 0, timeout: 0.2) }
        try await waitForRequest(delayed, count: 1)
        try await dc.stop(profile: profile)
        do { try await stale.value; throw Failure.failed("Stale movement succeeded") } catch is CancellationError { }
        try check(await delayed.allRequests().count == 2, "Stop invalidates moves awaiting options")
        let preset = ONVIFMock([Reply(body: response("GotoPreset"), delay: 2000), Reply(body: response("Stop"))])
        let pc = client(preset)
        let presetCaller = Task { try await pc.gotoPreset(profile: profile, token: "one") }
        try await waitForRequest(preset, count: 1)
        presetCaller.cancel()
        do { try await presetCaller.value; throw Failure.failed("Cancelled preset succeeded") } catch is CancellationError { }
        try check(await preset.allRequests().count == 2, "Cancelled preset still transmits Stop")
        let cancelled = ONVIFMock([Reply(body: response("GetConfigurationOptions", options)), Reply(body: response("ContinuousMove"), delay: 2000), Reply(body: response("Stop"))])
        let ac = client(cancelled)
        let caller = Task { try await ac.move(profile: profile, pan: 0.5, tilt: 0, zoom: 0, timeout: 0.2) }
        try await waitForRequest(cancelled, count: 2)
        caller.cancel()
        do { try await caller.value; throw Failure.failed("Cancelled move succeeded") } catch is CancellationError { }
        try check(await cancelled.allRequests().count == 3, "Cancelled caller still transmits Stop")
    }
}
