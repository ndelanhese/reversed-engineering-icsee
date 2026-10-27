import Foundation
import Observation

@MainActor @Observable
final class CameraControlModel {
    private(set) var camera: Camera
    var profiles: [ONVIFProfile] = []
    var profileToken: String?
    var ptzOptions: ONVIFPTZOptions?
    var imaging: [ONVIFImagingSetting] = []
    var imagingDraft: [String: String] = [:]
    var presets: [ONVIFPreset] = []
    var presetName = ""
    var speed = 0.25
    var discovering = false
    var loadingDetails = false
    var connectingDevice = false
    var deviceReady = false
    var credentialsProvided = false
    var moving = false
    var busy = false
    var restarting = false
    var error: String?
    var ptzError: String?
    var imagingError: String?
    var presetError: String?
    var onvifError: String?
    var deviceError: String?
    var notice: String?
    var selectedSection: DeviceSettingSection?
    var deviceOriginal: DeviceJSON?
    var deviceDraft: DeviceJSON?
    var invalidPaths = Set<String>()
    var settingsRevision = UUID()
    var requiresRestart = false
    var checkingSettings = false
    var checkedSettings = 0
    var availableSections = Set<String>()
    var sectionErrors: [String: String] = [:]
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var movementID = UUID()
    @ObservationIgnored private var onvif: ONVIFClient?
    @ObservationIgnored private var dvrip: DVRIPClient?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var movementTask: Task<Void, Never>?
    var profile: ONVIFProfile? { profiles.first { $0.token == profileToken } }
    var hasDeviceChanges: Bool { if !invalidPaths.isEmpty { return true }; if let original = deviceOriginal, let draft = deviceDraft { return original != draft }; return false }
    var hasImageChanges: Bool { imaging.contains { $0.isWritable && imagingDraft[$0.path] != $0.value } }

    init(camera: Camera) { self.camera = camera }
    func discover() { connect(credentials: nil) }
    func authenticate(_ credentials: Credentials) { connect(credentials: credentials) }
    func update(camera: Camera) {
        let changed = self.camera.host != camera.host || self.camera.onvifPort != camera.onvifPort || self.camera.onvifPath != camera.onvifPath || self.camera.controlPort != camera.controlPort || self.camera.channel != camera.channel
        self.camera = camera
        if changed { disconnect(); discover() }
    }
    private func connect(credentials: Credentials?) {
        guard !restarting else { return }
        disconnect()
        let cleanup = cleanupTask
        credentialsProvided = credentials != nil
        error = nil; onvifError = nil; deviceError = nil; notice = nil
        let stamp = generation
        let client = ONVIFClient(host: camera.host, port: camera.onvifPort, servicePath: camera.onvifPath, username: credentials?.username, password: credentials?.password)
        onvif = client
        discovering = true
        discoveryTask = Task { [weak self] in
            await cleanup?.value
            guard !Task.isCancelled else { return }
            do {
                let result = try await client.discover()
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.profiles = result.profiles
                let desired = self.camera.substream ? "sub" : "main"
                self.profileToken = result.profiles.first { $0.name.lowercased().contains(desired) }?.token ?? result.profiles.first?.token
                self.discovering = false
                self.refreshProfile()
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.discovering = false
                self.onvifError = error.localizedDescription
            }
        }
        if let credentials {
            let device = DVRIPClient(host: camera.host, port: camera.controlPort, username: credentials.username, password: credentials.password)
            dvrip = device
            connectingDevice = true
            deviceTask = Task { [weak self] in
                await cleanup?.value
                guard !Task.isCancelled else { return }
                do {
                    try await device.connect()
                    guard let self, self.generation == stamp, !Task.isCancelled else { await device.disconnect(); return }
                    self.connectingDevice = false; self.deviceReady = true
                    self.startCheckingSettings()
                } catch {
                    guard let self, self.generation == stamp, !Task.isCancelled else { return }
                    self.connectingDevice = false
                    self.deviceError = error.localizedDescription
                }
            }
        }
    }
    func selectProfile(_ token: String) {
        guard profiles.contains(where: { $0.token == token }), !moving else { return }
        profileToken = token
        refreshProfile()
    }
    func refreshProfile() {
        detailTask?.cancel()
        ptzOptions = nil; imaging = []; imagingDraft = [:]; presets = []
        guard let profile, let client = onvif else { return }
        let stamp = generation
        loadingDetails = true
        detailTask = Task { [weak self] in
            var options: ONVIFPTZOptions?, fields: [ONVIFImagingSetting] = [], saved: [ONVIFPreset] = []
            var movementFailure: String?, imageFailure: String?, presetFailure: String?
            do { options = try await client.ptzOptions(profile: profile) } catch { movementFailure = error.localizedDescription }
            do { fields = try await client.imaging(profile: profile) } catch { imageFailure = error.localizedDescription }
            do { saved = try await client.presets(profile: profile) } catch { presetFailure = error.localizedDescription }
            guard let self, self.generation == stamp, self.profileToken == profile.token, !Task.isCancelled else { return }
            self.ptzOptions = options
            self.imaging = fields
            self.imagingDraft = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0.value) })
            self.presets = saved
            self.ptzError = movementFailure; self.imagingError = imageFailure; self.presetError = presetFailure
            self.loadingDetails = false
        }
    }
    func nudge(pan: Double, tilt: Double, zoom: Double) {
        guard credentialsProvided, !moving, let client = onvif, let profile, ptzOptions != nil else {
            error = String(localized: "Connect and select a supported movement profile first."); return
        }
        let stamp = generation
        let motion = UUID(); movementID = motion
        moving = true; error = nil; notice = nil
        movementTask = Task { [weak self] in
            var failure: String?
            do {
                try await client.move(profile: profile, pan: pan, tilt: tilt, zoom: zoom, timeout: 1)
                try await Task.sleep(for: .milliseconds(250))
            } catch { if !(error is CancellationError) { failure = error.localizedDescription } }
            // Stop must survive cancellation of the movement/delay task.
            let stop = Task { try await client.stop(profile: profile) }
            do { try await stop.value } catch { failure = error.localizedDescription }
            guard let self, self.generation == stamp, self.movementID == motion else { return }
            self.moving = false
            if let failure { self.error = failure }
        }
    }
    func stopMovement() {
        let pending = movementTask
        let hadMovement = moving
        let motion = movementID
        movementTask?.cancel()
        guard let client = onvif, let profile else { moving = false; return }
        let stamp = generation
        moving = true
        movementTask = Task { [weak self] in
            if hadMovement, let pending { await pending.value }
            else {
                do { try await client.stop(profile: profile) }
                catch { if let self, self.generation == stamp { self.error = error.localizedDescription } }
            }
            if let self, self.generation == stamp, self.movementID == motion { self.moving = false }
        }
    }
    func goToPreset(_ token: String) {
        guard credentialsProvided, !moving, let client = onvif, let profile else { return }
        moving = true; error = nil
        let stamp = generation
        let motion = UUID(); movementID = motion
        movementTask = Task { [weak self] in
            do { try await client.gotoPreset(profile: profile, token: token) }
            catch { if let self, self.generation == stamp, !(error is CancellationError) { self.error = error.localizedDescription } }
            if let self, self.generation == stamp, self.movementID == motion { self.moving = false }
        }
    }
    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credentialsProvided, !busy, !name.isEmpty, let client = onvif, let profile else { return }
        busy = true; error = nil
        let stamp = generation
        operationTask = Task { [weak self] in
            do {
                _ = try await client.savePreset(profile: profile, name: name)
                let values = try await client.presets(profile: profile)
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.presets = values; self.presetName = ""; self.busy = false
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.busy = false; self.error = error.localizedDescription
            }
        }
    }
    func applyImaging() {
        guard credentialsProvided, !busy, let client = onvif, let profile else { return }
        let changes = imaging.filter { $0.isWritable && imagingDraft[$0.path] != $0.value }
        guard !changes.isEmpty else { return }
        let values = Dictionary(uniqueKeysWithValues: changes.compactMap { field in
            imagingDraft[field.path].map { (field.path, $0) }
        })
        busy = true; error = nil; notice = nil
        let stamp = generation
        operationTask = Task { [weak self] in
            do {
                try await client.setImaging(profile: profile, changes: values)
                let fields = try await client.imaging(profile: profile)
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.imaging = fields; self.imagingDraft = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0.value) })
                self.busy = false; self.notice = String(localized: "Image settings applied and verified.")
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.busy = false; self.error = error.localizedDescription
                self.notice = String(localized: "Some values may have changed. Refresh to read the camera again.")
            }
        }
    }
    func startCheckingSettings() {
        guard deviceReady, !checkingSettings, !restarting, let client = dvrip else { return }
        checkingSettings = true
        let scan = UUID(); scanID = scan
        let stamp = generation
        let preferred = selectedSection?.id ?? "Camera.Param"
        let sections = DeviceSettingSection.all.sorted { ($0.id == preferred ? 0 : 1) < ($1.id == preferred ? 0 : 1) }
        scanTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            for section in sections {
                guard let self, self.generation == stamp, self.scanID == scan, self.checkingSettings, !Task.isCancelled, Date() < deadline else { break }
                if self.availableSections.contains(section.id) || self.sectionErrors[section.id] != nil { continue }
                do {
                    let value = try await client.read(name: section.name, capability: section.capability)
                    guard self.generation == stamp, self.scanID == scan, !Task.isCancelled else { return }
                    self.availableSections.insert(section.id)
                    if self.selectedSection == nil && !self.busy {
                        self.selectedSection = section; self.deviceOriginal = value; self.deviceDraft = value; self.settingsRevision = UUID()
                    }
                } catch {
                    guard self.generation == stamp, self.scanID == scan, !Task.isCancelled else { return }
                    self.sectionErrors[section.id] = error.localizedDescription
                    if let failure = error as? DVRIPError, [.forbidden, .rejected].contains(failure) {
                        self.deviceError = String(localized: "Some settings could not be read. Show unverified settings for details.")
                    }
                    if let failure = error as? DVRIPError, ![.unsupported, .forbidden, .rejected].contains(failure) {
                        self.deviceReady = false; self.deviceError = error.localizedDescription; break
                    }
                }
                self.checkedSettings = self.availableSections.count + self.sectionErrors.count
            }
            if let self, self.generation == stamp, self.scanID == scan { self.checkingSettings = false }
        }
    }
    func pauseCheckingSettings() { checkingSettings = false; scanID = UUID() }
    func loadSection(_ section: DeviceSettingSection) {
        guard !busy else { return }
        selectedSection = section
        deviceOriginal = nil; deviceDraft = nil; invalidPaths = []; requiresRestart = false
        settingsRevision = UUID()
        guard deviceReady, let client = dvrip else { return }
        busy = true; deviceError = nil; notice = nil
        let stamp = generation
        operationTask = Task { [weak self] in
            do {
                let value = try await client.read(name: section.name, capability: section.capability)
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.availableSections.insert(section.id); self.sectionErrors[section.id] = nil
                self.deviceOriginal = value; self.deviceDraft = value; self.busy = false; self.settingsRevision = UUID()
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.busy = false; self.deviceError = error.localizedDescription
            }
        }
    }
    func applyDeviceSettings() {
        guard !busy, !requiresRestart, deviceReady, let client = dvrip, let section = selectedSection, !section.readOnly,
              let original = deviceOriginal, let updated = deviceDraft, original != updated, invalidPaths.isEmpty else { return }
        busy = true; deviceError = nil; notice = nil
        let stamp = generation
        operationTask = Task { [weak self] in
            do {
                let result = try await client.write(name: section.name, original: original, updated: updated)
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.deviceOriginal = result.value
                self.deviceDraft = result.requiresRestart ? updated : result.value
                self.requiresRestart = result.requiresRestart
                self.settingsRevision = UUID(); self.busy = false
                self.notice = result.requiresRestart ? String(localized: "The camera accepted the change and requires a restart. Current values may not change until it restarts.") : String(localized: "Device settings applied and verified.")
            } catch {
                guard let self, self.generation == stamp, !Task.isCancelled else { return }
                self.busy = false; self.deviceError = error.localizedDescription
            }
        }
    }
    func restartCamera() {
        guard deviceReady, !busy, !restarting, let client = dvrip else { return }
        restarting = true; deviceReady = false; deviceError = nil
        let stamp = generation
        restartTask = Task { [weak self] in
            defer { self?.restarting = false; self?.restartTask = nil }
            do {
                try await client.reboot()
                if let self, self.generation == stamp { self.notice = String(localized: "Restart requested. Keep the app running while the camera restarts.") }
                // Some firmware cancels reboot if its acknowledged TCP connection closes too soon.
                try? await Task.sleep(for: .seconds(15))
                await client.disconnect()
                guard let self else { return }
                self.requiresRestart = false
                self.notice = String(localized: "Reconnect after the camera finishes restarting.")
            } catch {
                guard let self else { return }
                self.deviceError = error.localizedDescription
            }
        }
    }
    func shutdown() async {
        disconnect()
        await cleanupTask?.value
    }
    func disconnect() {
        generation = UUID()
        discoveryTask?.cancel(); detailTask?.cancel(); movementTask?.cancel()
        deviceTask?.cancel()
        operationTask?.cancel()
        checkingSettings = false; scanTask?.cancel()
        let oldONVIF = onvif, oldProfile = profile, oldDevice = dvrip
        let pendingMovement = movementTask
        let wasMoving = moving
        let restart = restartTask, previousCleanup = cleanupTask
        cleanupTask = Task {
            await previousCleanup?.value
            if wasMoving {
                if let pendingMovement { await pendingMovement.value }
                else if let oldONVIF, let oldProfile { try? await oldONVIF.stop(profile: oldProfile) }
            }
            await restart?.value
            await oldDevice?.disconnect()
        }
        onvif = nil; dvrip = nil
        credentialsProvided = false; deviceReady = false; connectingDevice = false; discovering = false
        profiles = []; profileToken = nil; ptzOptions = nil; imaging = []; imagingDraft = [:]; presets = []
        deviceOriginal = nil; deviceDraft = nil; selectedSection = nil; invalidPaths = []; moving = false; busy = false; loadingDetails = false
        availableSections = []; sectionErrors = [:]; checkedSettings = 0
    }
}
