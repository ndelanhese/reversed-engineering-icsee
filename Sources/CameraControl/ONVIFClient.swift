import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

struct ONVIFHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}
typealias ONVIFTransport = @Sendable (URLRequest) async throws -> ONVIFHTTPResponse

// Every redirect is refused; neither HTTP credentials nor WSSE can leave the configured origin.
private final class ONVIFSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.rejectProtectionSpace, nil)
    }
}

private enum ONVIFHTTP {
    static let limit = 2 * 1024 * 1024
    static func send(_ request: URLRequest) async throws -> ONVIFHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: ONVIFSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ONVIFError.invalidResponse }
        guard response.expectedContentLength <= limit else { throw ONVIFError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ONVIFError.invalidResponse }
            data.append(byte)
        }
        return ONVIFHTTPResponse(status: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [:]) { result, field in
                result[String(describing: field.key).lowercased()] = String(describing: field.value)
            }, body: data)
    }
}

struct ONVIFXMLNode: Sendable, Equatable {
    let name: String
    let namespace: String
    var attributes: [String: String]
    var children: [ONVIFXMLNode] = []
    var text = ""
    var local: String { name.split(separator: ":").last.map(String.init) ?? name }
    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func child(_ name: String) -> ONVIFXMLNode? { children.first { $0.local == name } }
    func descendants(_ name: String) -> [ONVIFXMLNode] {
        children.flatMap { ($0.local == name ? [$0] : []) + $0.descendants(name) }
    }
    func at(_ path: [String]) -> ONVIFXMLNode? {
        guard let first = path.first else { return self }
        return child(first)?.at(Array(path.dropFirst()))
    }
    mutating func replace(_ path: [String], with value: String) throws {
        guard let first = path.first else {
            guard children.isEmpty else { throw ONVIFError.invalidInput }
            text = value; return
        }
        let matches = children.indices.filter { children[$0].local == first }
        guard matches.count == 1, let index = matches.first else { throw ONVIFError.unsupported }
        try children[index].replace(Array(path.dropFirst()), with: value)
    }
    func serialized() -> String {
        let attrs = attributes.filter { !$0.key.hasPrefix("xmlns") }.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(onvifEscape($0.value))\"" }.joined()
        let xmlns = " xmlns=\"\(onvifEscape(namespace))\""
        // Prefix declarations keep qualified extension attributes valid on the preserved subtree.
        let prefixes = attributes.filter { $0.key.hasPrefix("xmlns:") }.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(onvifEscape($0.value))\"" }.joined()
        return "<\(local)\(xmlns)\(prefixes)\(attrs)>\(onvifEscape(text))\(children.map { $0.serialized() }.joined())</\(local)>"
    }
}

private final class ONVIFXMLParser: NSObject, XMLParserDelegate {
    var stack: [ONVIFXMLNode] = []
    var namespaces: [[String: String]] = []
    var root: ONVIFXMLNode?
    var count = 0
    var failed = false
    static func parse(_ data: Data) throws -> ONVIFXMLNode {
        guard data.count <= ONVIFHTTP.limit, let source = String(data: data, encoding: .utf8),
              !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !source.localizedCaseInsensitiveContains("<!ENTITY") else { throw ONVIFError.invalidResponse }
        let delegate = ONVIFXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root else { throw ONVIFError.invalidResponse }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 40, count < 20_000, attributes.count < 100 else { failed = true; parser.abortParsing(); return }
        var scope = namespaces.last ?? [:]
        for (key, value) in attributes where key == "xmlns" || key.hasPrefix("xmlns:") { scope[key] = value }
        namespaces.append(scope)
        let parts = elementName.split(separator: ":")
        let key = parts.count > 1 ? "xmlns:" + parts[0] : "xmlns"
        var preserved = attributes
        for (key, value) in scope where key.hasPrefix("xmlns:") { preserved[key] = value }
        stack.append(ONVIFXMLNode(name: elementName, namespace: scope[key] ?? "", attributes: preserved))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        guard stack[stack.count - 1].text.utf8.count + string.utf8.count <= 65_536 else { failed = true; parser.abortParsing(); return }
        stack[stack.count - 1].text += string
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { failed = true; parser.abortParsing(); return }
        self.parser(parser, foundCharacters: text)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.popLast() else { failed = true; return }
        _ = namespaces.popLast()
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }
}

private func onvifEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

actor ONVIFClient {
    private let host: String
    private let port: Int
    private let servicePath: String
    private let username: String?
    private let password: String?
    private let transport: ONVIFTransport
    private var endpoints: [String: URL] = [:]
    private var discoveredServices = false
    private var digest: [String: String] = [:]
    private var nonceCount = 0
    private var optionsCache: [String: ONVIFPTZOptions] = [:]
    private var velocitySpaces: [String: (String?, String?)] = [:]
    private var imagingSnapshots: [String: ONVIFXMLNode] = [:]
    private var writingImaging = false
    private var movementGeneration: UInt64 = 0
    private var pendingMove: Task<ONVIFXMLNode, Error>?
    private var timedOutPresetGeneration: UInt64?

    init(host: String, port: Int = 8899, servicePath: String = "/onvif/device_service", username: String? = nil, password: String? = nil) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.servicePath = servicePath
        transport = ONVIFHTTP.send
    }
    init(host: String, port: Int = 8899, servicePath: String = "/onvif/device_service", username: String? = nil, password: String? = nil, transport: @escaping ONVIFTransport) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.servicePath = servicePath
        self.transport = transport
    }

    func discover() async throws -> ONVIFDevice {
        let root = try await soap(service: "device", action: "GetServices", body: "<tds:IncludeCapability>false</tds:IncludeCapability>")
        var discovered: [String: URL] = [:]
        for service in root.descendants("Service") {
            guard let namespace = service.child("Namespace")?.value, let address = service.child("XAddr")?.value else { continue }
            let kind: String
            switch namespace {
            case "http://www.onvif.org/ver10/media/wsdl": kind = "media"
            case "http://www.onvif.org/ver20/ptz/wsdl": kind = "ptz"
            case "http://www.onvif.org/ver20/imaging/wsdl": kind = "imaging"
            default: continue
            }
            discovered[kind] = try safeURL(address)
        }
        endpoints = discovered
        discoveredServices = true
        guard endpoints["media"] != nil else { throw ONVIFError.unsupported }
        let profiles = try await soap(service: "media", action: "GetProfiles", body: "")
        return ONVIFDevice(profiles: profiles.descendants("Profiles").compactMap { node in
            guard let token = node.attributes["token"], !token.isEmpty else { return nil }
            return ONVIFProfile(token: token, name: node.child("Name")?.value ?? token,
                videoSourceToken: node.child("VideoSourceConfiguration")?.child("SourceToken")?.value,
                ptzConfigurationToken: node.child("PTZConfiguration")?.attributes["token"])
        })
    }

    func ptzOptions(profile: ONVIFProfile) async throws -> ONVIFPTZOptions {
        guard let token = profile.ptzConfigurationToken else { throw ONVIFError.unsupported }
        if let cached = optionsCache[token] { return cached }
        let root = try await soap(service: "ptz", action: "GetConfigurationOptions", body: "<tptz:ConfigurationToken>\(onvifEscape(token))</tptz:ConfigurationToken>")
        guard let options = root.descendants("PTZConfigurationOptions").first else { throw ONVIFError.invalidResponse }
        let spaces = options.child("Spaces")
        let panTilt = spaces?.child("ContinuousPanTiltVelocitySpace")
        let zoom = spaces?.child("ContinuousZoomVelocitySpace")
        let minimum = duration(options.child("PTZTimeout")?.child("Min")?.value ?? "PT0.1S")
        let maximum = duration(options.child("PTZTimeout")?.child("Max")?.value ?? "PT1S")
        guard let minimum, let maximum, minimum > 0, maximum >= minimum else { throw ONVIFError.invalidResponse }
        let result = ONVIFPTZOptions(panRange: range(panTilt?.child("XRange")), tiltRange: range(panTilt?.child("YRange")),
            zoomRange: range(zoom?.child("XRange")), minTimeout: minimum, maxTimeout: maximum)
        optionsCache[token] = result
        velocitySpaces[token] = (panTilt?.child("URI")?.value, zoom?.child("URI")?.value)
        return result
    }

    func move(profile: ONVIFProfile, pan: Double, tilt: Double, zoom: Double, timeout: Double) async throws {
        guard pan.isFinite, tilt.isFinite, zoom.isFinite, timeout.isFinite, timeout > 0 else { throw ONVIFError.invalidInput }
        let generation = movementGeneration
        let options = try await ptzOptions(profile: profile)
        try Task.checkCancellation()
        guard generation == movementGeneration else { throw CancellationError() }
        guard pendingMove == nil else { throw ONVIFError.conflict }
        guard options.minTimeout <= 1 else { throw ONVIFError.unsupported }
        for (value, range) in [(pan, options.panRange), (tilt, options.tiltRange), (zoom, options.zoomRange)] where value != 0 {
            guard let range else { throw ONVIFError.unsupported }
            guard range.contains(value) else { throw ONVIFError.invalidInput }
        }
        if pan == 0, tilt == 0, zoom == 0 { try await stop(profile: profile); return }
        let seconds = max(options.minTimeout, min(timeout, options.maxTimeout, 1))
        let spaces = velocitySpaces[profile.ptzConfigurationToken ?? ""]
        var velocity = ""
        if pan != 0 || tilt != 0 {
            let space = spaces?.0.map { " space=\"\(onvifEscape($0))\"" } ?? ""
            velocity += "<tt:PanTilt x=\"\(pan)\" y=\"\(tilt)\"\(space)/>"
        }
        if zoom != 0 {
            let space = spaces?.1.map { " space=\"\(onvifEscape($0))\"" } ?? ""
            velocity += "<tt:Zoom x=\"\(zoom)\"\(space)/>"
        }
        let body = profileBody(profile) + "<tptz:Velocity>\(velocity)</tptz:Velocity><tptz:Timeout>PT\(number(seconds))S</tptz:Timeout>"
        let task = Task { try await self.soap(service: "ptz", action: "ContinuousMove", body: body, readOnly: false) }
        pendingMove = task
        defer { if generation == movementGeneration { pendingMove = nil } }
        do {
            try await withTaskCancellationHandler { _ = try await task.value } onCancel: { task.cancel() }
        } catch {
            if generation == movementGeneration { try? await stop(profile: profile) }
            throw error
        }
    }

    func stop(profile: ONVIFProfile) async throws {
        movementGeneration &+= 1
        let pending = pendingMove
        pendingMove = nil
        pending?.cancel()
        if let pending { _ = try? await pending.value }
        let body = profileBody(profile) + "<tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom>"
        // A cancelled UI task must still be able to transmit its final Stop.
        _ = try await Task { try await self.soap(service: "ptz", action: "Stop", body: body, readOnly: false) }.value
    }
    func presets(profile: ONVIFProfile) async throws -> [ONVIFPreset] {
        guard profile.ptzConfigurationToken != nil else { throw ONVIFError.unsupported }
        let root = try await soap(service: "ptz", action: "GetPresets", body: profileBody(profile))
        return root.descendants("Preset").compactMap { node in
            guard let token = node.attributes["token"], !token.isEmpty else { return nil }
            return ONVIFPreset(token: token, name: node.child("Name")?.value ?? token)
        }
    }
    func gotoPreset(profile: ONVIFProfile, token: String) async throws {
        // GotoPreset is finite-target movement without a protocol Timeout; an independent watchdog sends Stop.
        guard !token.isEmpty, token.utf8.count <= 256, profile.ptzConfigurationToken != nil else { throw ONVIFError.invalidInput }
        guard pendingMove == nil else { throw ONVIFError.conflict }
        let generation = movementGeneration
        let deadline = ContinuousClock.now + .seconds(15)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            if generation == self.movementGeneration {
                self.timedOutPresetGeneration = generation
                try await self.stop(profile: profile)
            }
        }
        defer { watchdog.cancel() }
        let task = Task { try await self.soap(service: "ptz", action: "GotoPreset", body: self.profileBody(profile) + "<tptz:PresetToken>\(onvifEscape(token))</tptz:PresetToken>", readOnly: false) }
        pendingMove = task
        do {
            try await withTaskCancellationHandler { _ = try await task.value } onCancel: { task.cancel() }
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                try requireCurrentMovement(generation)
                do {
                    let status = try await soap(service: "ptz", action: "GetStatus", body: profileBody(profile))
                    let movement = status.descendants("MoveStatus").first
                    let states = movement?.children.map { $0.value.uppercased() } ?? []
                    if !states.isEmpty, states.allSatisfy({ $0 == "IDLE" }) {
                        try requireCurrentMovement(generation)
                        pendingMove = nil
                        return
                    }
                } catch ONVIFError.unsupported { /* Keep the deadline when status is unavailable. */ }
                try await Task.sleep(for: .milliseconds(300))
            }
            throw ONVIFError.verificationFailed
        } catch {
            if generation == movementGeneration { try? await stop(profile: profile) }
            else if timedOutPresetGeneration == generation { _ = try? await watchdog.value }
            throw error
        }
    }
    func savePreset(profile: ONVIFProfile, name: String) async throws -> String {
        guard !name.isEmpty, name.utf8.count <= 128, profile.ptzConfigurationToken != nil else { throw ONVIFError.invalidInput }
        let root = try await soap(service: "ptz", action: "SetPreset", body: profileBody(profile) + "<tptz:PresetName>\(onvifEscape(name))</tptz:PresetName>", readOnly: false)
        guard let token = root.descendants("PresetToken").first?.value, !token.isEmpty else { throw ONVIFError.invalidResponse }
        return token
    }

    func imaging(profile: ONVIFProfile) async throws -> [ONVIFImagingSetting] {
        guard let source = profile.videoSourceToken else { throw ONVIFError.unsupported }
        let optionsRoot = try await soap(service: "imaging", action: "GetOptions", body: sourceBody(source))
        let settings = try await imagingTree(source)
        guard let options = optionsRoot.descendants("ImagingOptions").first else { throw ONVIFError.invalidResponse }
        imagingSnapshots[source] = settings
        return imagingFields(settings, options: options)
    }
    func setImaging(profile: ONVIFProfile, path: String, value: String) async throws {
        try await setImaging(profile: profile, changes: [path: value])
    }
    func setImaging(profile: ONVIFProfile, changes: [String: String]) async throws {
        guard !writingImaging else { throw ONVIFError.conflict }
        guard !changes.isEmpty else { throw ONVIFError.invalidInput }
        guard let source = profile.videoSourceToken, let snapshot = imagingSnapshots[source] else { throw ONVIFError.unsupported }
        writingImaging = true
        defer { writingImaging = false }
        let optionsRoot = try await soap(service: "imaging", action: "GetOptions", body: sourceBody(source))
        guard let options = optionsRoot.descendants("ImagingOptions").first else { throw ONVIFError.invalidResponse }
        let fields = imagingFields(snapshot, options: options)
        let edits = changes.sorted { $0.key < $1.key }
        for (path, value) in edits {
            guard let field = fields.first(where: { $0.path == path }), field.isWritable else { throw ONVIFError.unsupported }
            if let range = field.range {
                guard let number = Double(value), number.isFinite, range.contains(number) else { throw ONVIFError.invalidInput }
            } else { guard field.choices.contains(value) else { throw ONVIFError.invalidInput } }
        }
        var current = try await imagingTree(source)
        // Validate the whole selection against one displayed baseline before changing any leaf.
        for (path, _) in edits {
            let parts = path.split(separator: ".").map(String.init)
            guard current.at(parts)?.value == snapshot.at(parts)?.value else { throw ONVIFError.conflict }
        }
        for (path, value) in edits {
            try current.replace(path.split(separator: ".").map(String.init), with: value)
        }
        // Reuse the full current subtree so unrelated standard and extension values survive.
        current = ONVIFXMLNode(name: "ImagingSettings", namespace: "http://www.onvif.org/ver20/imaging/wsdl", attributes: current.attributes, children: current.children, text: current.text)
        _ = try await soap(service: "imaging", action: "SetImagingSettings", body: sourceBody(source) + current.serialized() + "<timg:ForcePersistence>true</timg:ForcePersistence>", readOnly: false)
        let confirmed = try await imagingTree(source)
        imagingSnapshots[source] = confirmed
        for (path, value) in edits {
            let actual = confirmed.at(path.split(separator: ".").map(String.init))?.value
            guard actual == value || (Double(actual ?? "").map { $0 == Double(value) } ?? false) else { throw ONVIFError.verificationFailed }
        }
    }

    private func imagingTree(_ source: String) async throws -> ONVIFXMLNode {
        let root = try await soap(service: "imaging", action: "GetImagingSettings", body: sourceBody(source))
        guard let settings = root.descendants("ImagingSettings").first else { throw ONVIFError.invalidResponse }
        return settings
    }
    private func imagingFields(_ settings: ONVIFXMLNode, options: ONVIFXMLNode) -> [ONVIFImagingSetting] {
        func walk(_ node: ONVIFXMLNode, _ option: ONVIFXMLNode?, _ path: [String], _ unique: Bool) -> [ONVIFImagingSetting] {
            node.children.enumerated().flatMap { index, child -> [ONVIFImagingSetting] in
                let aliases = ["AutoFocusMode": "AutoFocusModes", "IrCutFilter": "IrCutFilterModes"]
                let optionName = aliases[child.local] ?? child.local
                let candidates = option?.children.filter { $0.local == optionName } ?? []
                let repeated = node.children.filter { $0.local == child.local }.count > 1
                let sameNames = !repeated && unique
                let childPath = path + [child.local + (repeated ? "[\(index)]" : "")]
                if !child.children.isEmpty { return walk(child, candidates.first, childPath, sameNames) }
                let range = range(candidates.first)
                let choices = candidates.filter { $0.children.isEmpty }.map(\.value).filter { !$0.isEmpty }
                return [ONVIFImagingSetting(path: childPath.joined(separator: "."), value: child.value,
                    range: range, choices: choices, isWritable: sameNames && (range != nil || !choices.isEmpty))]
            }
        }
        return walk(settings, options, [], true)
    }
    private func requireCurrentMovement(_ generation: UInt64) throws {
        if timedOutPresetGeneration == generation { throw ONVIFError.verificationFailed }
        guard generation == movementGeneration else { throw CancellationError() }
    }
    private func profileBody(_ profile: ONVIFProfile) -> String { "<tptz:ProfileToken>\(onvifEscape(profile.token))</tptz:ProfileToken>" }
    private func sourceBody(_ source: String) -> String { "<timg:VideoSourceToken>\(onvifEscape(source))</timg:VideoSourceToken>" }
    private func range(_ node: ONVIFXMLNode?) -> ClosedRange<Double>? {
        guard let node, let minimum = Double(node.child("Min")?.value ?? ""), let maximum = Double(node.child("Max")?.value ?? ""),
              minimum.isFinite, maximum.isFinite, minimum <= maximum else { return nil }
        return minimum...maximum
    }
    private func duration(_ value: String) -> Double? {
        guard value.hasPrefix("PT"), value.hasSuffix("S"), let result = Double(value.dropFirst(2).dropLast()), result.isFinite else { return nil }
        return result
    }
    private func number(_ value: Double) -> String { value == floor(value) ? String(Int(value)) : String(value) }
    private func safeURL(_ address: String? = nil) throws -> URL {
        guard !host.isEmpty, host.utf8.count <= 253, (1...65535).contains(port),
              !host.contains(where: { $0.isWhitespace || "/@?#\\".contains($0) }), !host.hasPrefix("-"),
              servicePath.hasPrefix("/"), !servicePath.hasPrefix("//"), servicePath.utf8.count <= 1024,
              !servicePath.contains(where: { $0.isNewline || "?#\\".contains($0) }) else { throw ONVIFError.invalidInput }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port; components.path = servicePath
        guard let base = components.url else { throw ONVIFError.invalidInput }
        guard let address else { return base }
        guard let url = URL(string: address), let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parsed.scheme == "http", parsed.host?.lowercased() == base.host?.lowercased(),
              (parsed.port ?? 80) == port, parsed.user == nil, parsed.password == nil,
              parsed.fragment == nil, parsed.query == nil else { throw ONVIFError.invalidResponse }
        return url
    }

    private func soap(service: String, action: String, body: String, readOnly: Bool = true) async throws -> ONVIFXMLNode {
        try Task.checkCancellation()
        let endpoint: URL
        if service == "device" { endpoint = try safeURL() }
        else if let url = endpoints[service] { endpoint = url }
        else {
            guard !discoveredServices else { throw ONVIFError.unsupported }
            // Before discovery, conventional same-origin paths allow direct tests and compatible devices.
            endpoint = try safeURL("http://\(host.contains(":") ? "[\(host)]" : host):\(port)/onvif/\(service)_service")
        }
        let ns: String
        let prefix: String
        switch service {
        case "media": ns = "http://www.onvif.org/ver10/media/wsdl"; prefix = "trt"
        case "ptz": ns = "http://www.onvif.org/ver20/ptz/wsdl"; prefix = "tptz"
        case "imaging": ns = "http://www.onvif.org/ver20/imaging/wsdl"; prefix = "timg"
        default: ns = "http://www.onvif.org/ver10/device/wsdl"; prefix = "tds"
        }
        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/soap+xml; charset=utf-8; action=\"\(ns)/\(action)\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"\(ns)/\(action)\"", forHTTPHeaderField: "SOAPAction")
            if !digest.isEmpty { request.setValue(try digestHeader(url: endpoint), forHTTPHeaderField: "Authorization") }
            request.httpBody = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:tt=\"http://www.onvif.org/ver10/schema\" xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\" xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\" xmlns:tptz=\"http://www.onvif.org/ver20/ptz/wsdl\" xmlns:timg=\"http://www.onvif.org/ver20/imaging/wsdl\"><s:Header>" + wsse() + "</s:Header><s:Body><\(prefix):\(action)>\(body)</\(prefix):\(action)></s:Body></s:Envelope>").utf8)
            guard let body = request.httpBody, body.count <= ONVIFHTTP.limit else { throw ONVIFError.invalidInput }
            return request
        }
        do {
            var response = try await transport(makeRequest())
            if response.status == 401 {
                if let challenge = response.headers.first(where: { $0.key.lowercased() == "www-authenticate" })?.value {
                    digest = try parseDigest(challenge)
                }
                guard readOnly, username != nil, password != nil, !digest.isEmpty else { throw ONVIFError.unauthorized }
                try Task.checkCancellation()
                response = try await transport(makeRequest())
            }
            guard response.status != 401, response.status != 403 else { throw ONVIFError.unauthorized }
            guard !(300...399).contains(response.status) else { throw ONVIFError.invalidResponse }
            let root = try ONVIFXMLParser.parse(response.body)
            guard root.local == "Envelope", ["http://www.w3.org/2003/05/soap-envelope", "http://schemas.xmlsoap.org/soap/envelope/"].contains(root.namespace),
                  let responseBody = root.child("Body"), responseBody.namespace == root.namespace else { throw ONVIFError.invalidResponse }
            if let fault = responseBody.child("Fault") {
                let codes = fault.descendants("Value").map(\.value) + fault.descendants("faultcode").map(\.value)
                if codes.contains(where: { $0.contains("NotAuthorized") || $0.contains("FailedAuthentication") }) { throw ONVIFError.unauthorized }
                if codes.contains(where: { $0.contains("ActionNotSupported") || $0.contains("OptionalActionNotImplemented") }) { throw ONVIFError.unsupported }
                throw ONVIFError.deviceFault
            }
            guard (200...299).contains(response.status) else { throw ONVIFError.deviceFault }
            guard let payload = responseBody.child(action + "Response"), payload.namespace == ns else { throw ONVIFError.invalidResponse }
            return root
        } catch is CancellationError { throw CancellationError() }
        catch let error as ONVIFError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw ONVIFError.transport }
    }

    private func wsse() -> String {
        guard let username, let password else { return "" }
        let nonce = Data(UUID().uuidString.utf8)
        let formatter = ISO8601DateFormatter()
        let created = formatter.string(from: Date())
        let hash = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(password.utf8))).base64EncodedString()
        let base = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-"
        return "<wsse:Security s:mustUnderstand=\"1\" xmlns:wsse=\"\(base)wssecurity-secext-1.0.xsd\" xmlns:wsu=\"\(base)wssecurity-utility-1.0.xsd\"><wsse:UsernameToken><wsse:Username>\(onvifEscape(username))</wsse:Username><wsse:Password Type=\"\(base)username-token-profile-1.0#PasswordDigest\">\(hash)</wsse:Password><wsse:Nonce EncodingType=\"\(base)soap-message-security-1.0#Base64Binary\">\(nonce.base64EncodedString())</wsse:Nonce><wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security>"
    }
    private func parseDigest(_ challenge: String) throws -> [String: String] {
        guard challenge.lowercased().hasPrefix("digest "), challenge.utf8.count < 8192 else { throw ONVIFError.unauthorized }
        let pattern = #"([A-Za-z0-9_-]+)\s*=\s*(?:"([^"\r\n]*)"|([^,\s]+))"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = challenge as NSString
        var fields: [String: String] = [:]
        for match in regex.matches(in: challenge, range: NSRange(location: 0, length: source.length)) {
            let capture = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            fields[source.substring(with: match.range(at: 1)).lowercased()] = source.substring(with: capture)
        }
        guard fields["realm"] != nil, let nonce = fields["nonce"], !nonce.isEmpty else { throw ONVIFError.unauthorized }
        let algorithm = (fields["algorithm"] ?? "MD5").uppercased()
        guard ["MD5", "MD5-SESS", "SHA-256", "SHA-256-SESS"].contains(algorithm) else { throw ONVIFError.unauthorized }
        if let qop = fields["qop"], !qop.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "auth" }) { throw ONVIFError.unauthorized }
        nonceCount = 0
        return fields
    }
    private func digestHeader(url: URL) throws -> String {
        guard let username, let password, let realm = digest["realm"], let nonce = digest["nonce"] else { throw ONVIFError.unauthorized }
        let algorithm = (digest["algorithm"] ?? "MD5").uppercased()
        func hash(_ value: String) -> String {
            let data = Data(value.utf8)
            let bytes = algorithm.hasPrefix("SHA-256") ? Array(SHA256.hash(data: data)) : Array(Insecure.MD5.hash(data: data))
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        func quote(_ value: String) throws -> String {
            guard !value.contains(where: { $0.isNewline || $0 == "\r" || $0 == "\0" }) else { throw ONVIFError.invalidInput }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        nonceCount += 1
        let nc = String(format: "%08x", nonceCount)
        let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ONVIFError.invalidInput }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let uri = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        var ha1 = hash("\(username):\(realm):\(password)")
        if algorithm.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(nonce):\(cnonce)") }
        let ha2 = hash("POST:\(uri)")
        let response = digest["qop"] == nil ? hash("\(ha1):\(nonce):\(ha2)") : hash("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        var result = "Digest username=\(try quote(username)), realm=\(try quote(realm)), nonce=\(try quote(nonce)), uri=\(try quote(uri)), response=\(try quote(response)), algorithm=\(algorithm)"
        if digest["qop"] != nil { result += ", qop=auth, nc=\(nc)" }
        if digest["qop"] != nil || algorithm.hasSuffix("-SESS") { result += ", cnonce=\(try quote(cnonce))" }
        if let opaque = digest["opaque"] { result += ", opaque=\(try quote(opaque))" }
        return result
    }
}
