import AppKit
import SwiftUI

struct CameraControlsView: View {
    let cameraID: UUID
    @Bindable var store: CameraStore
    let windows: CameraWindows
    @Bindable var model: CameraControlModel
    @ViewState private var authenticating = false
    @ViewState private var connectVideo = false
    @ViewState private var search = ""
    @ViewState private var showUnverified = false
    @ViewState private var confirmApply = false
    @ViewState private var confirmRestart = false
    @ViewState private var confirmDiscard = false
    private enum DiscardAction { case section(DeviceSettingSection), profile(String), refresh, authenticate(Bool) }
    @ViewState private var pendingAction: DiscardAction?
    private var camera: Camera? { store.cameras.first { $0.id == cameraID } }
    private var visibleSections: [DeviceSettingSection] {
        DeviceSettingSection.all.filter { section in
            (showUnverified || model.availableSections.contains(section.id)) &&
            (search.isEmpty || section.title.localizedCaseInsensitiveContains(search) || section.name.localizedCaseInsensitiveContains(search))
        }
    }
    private var groups: [String] { Array(Set(visibleSections.map(\.group))).sorted() }
    var body: some View {
        Group {
            if let camera {
                VStack(spacing: 0) {
                    header(camera)
                    if let error = model.error { message(error, error: true) }
                    if let notice = model.notice { message(notice) }
                    TabView {
                        movement(camera).tabItem { Label("Movement", systemImage: "move.3d") }
                        imageSettings.tabItem { Label("Image", systemImage: "camera.filters") }
                        deviceSettings.tabItem { Label("Device settings", systemImage: "slider.horizontal.3") }
                    }.padding(12)
                }
                .onAppear {
                    guard !model.credentialsProvided, !model.discovering, model.profiles.isEmpty else { return }
                    if let credentials = store.sessions[cameraID]?.credentialsForControls() { model.authenticate(credentials) }
                    else { model.discover() }
                }
                .onChange(of: camera) { _, value in model.update(camera: value); windows.updateControlTitle(value.name, id: value.id) }
                .sheet(isPresented: $authenticating) {
                    CredentialSheet(camera: camera) { credentials in
                        guard store.cameras.contains(where: { $0.id == cameraID }) else { return }
                        if connectVideo { store.sessions[cameraID]?.start(camera: camera, credentials: credentials) }
                        model.authenticate(credentials)
                    }
                }
            } else {
                Color.clear.onAppear { windows.closeControls(cameraID) }
            }
        }
        .onExitCommand { model.stopMovement() }
        .confirmationDialog("Apply device settings?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Apply changes") { model.applyDeviceSettings() }
        } message: {
            if model.selectedSection?.mayDisconnect == true { Text("Network changes can interrupt this connection.") }
            else { Text("Only edited fields will be applied. The app reads the camera again to verify the result.") }
        }
        .confirmationDialog("Restart this camera?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart camera", role: .destructive) { model.restartCamera() }
        } message: { Text("Video and controls will disconnect while the camera restarts.") }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { if let pendingAction { perform(pendingAction) }; pendingAction = nil }
        }
    }
    private func header(_ camera: Camera) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name).font(.title2.weight(.semibold)).lineLimit(1)
                Text("Camera controls").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.discovering || model.loadingDetails || model.connectingDevice || model.restarting { ProgressView().controlSize(.small) }
            Button("Refresh controls", systemImage: "arrow.clockwise") { request(.refresh, needsDiscard: model.hasImageChanges) }
                .disabled(model.profile == nil || model.busy || model.moving || model.loadingDetails || model.restarting)
            Button(model.credentialsProvided ? String(localized: "Change credentials…") : String(localized: "Authenticate…"), systemImage: "lock") {
                request(.authenticate(false), needsDiscard: model.hasDeviceChanges || model.hasImageChanges)
            }.disabled(model.restarting || model.busy || model.moving)
        }.padding(16)
    }
    private func message(_ value: String, error: Bool = false) -> some View {
        HStack { Image(systemName: error ? "exclamationmark.triangle" : "info.circle"); Text(value).font(.callout); Spacer() }
            .foregroundStyle(error ? Color.red : Color.secondary).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private func movement(_ camera: Camera) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                CameraVideo(session: store.session(camera)).frame(minHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    if store.session(camera).state == .live || store.session(camera).state == .connecting {
                        Button("Stop video", systemImage: "stop.fill") { store.session(camera).stop() }
                    } else { Button("Connect video", systemImage: "video") { request(.authenticate(true), needsDiscard: model.hasDeviceChanges || model.hasImageChanges) } }
                    Spacer()
                    profilePicker
                }
                if let error = model.onvifError { message(error, error: true) }
                if !model.credentialsProvided { Text("Authenticate to enable movement and changes.").font(.callout).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 16) {
                    Text("Pan and tilt").font(.headline)
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            moveButton("arrow.up.left", pan: -1, tilt: 1, label: "Move up and left")
                            moveButton("arrow.up", pan: 0, tilt: 1, label: "Move up")
                            moveButton("arrow.up.right", pan: 1, tilt: 1, label: "Move up and right")
                        }
                        GridRow {
                            moveButton("arrow.left", pan: -1, tilt: 0, label: "Move left")
                            Button { model.stopMovement() } label: { Image(systemName: "stop.fill").frame(width: 36, height: 30) }
                                .tint(.red).help("Stop movement").accessibilityLabel("Stop movement")
                                .disabled(model.profile == nil)
                            moveButton("arrow.right", pan: 1, tilt: 0, label: "Move right")
                        }
                        GridRow {
                            moveButton("arrow.down.left", pan: -1, tilt: -1, label: "Move down and left")
                            moveButton("arrow.down", pan: 0, tilt: -1, label: "Move down")
                            moveButton("arrow.down.right", pan: 1, tilt: -1, label: "Move down and right")
                        }
                    }
                    if let failure = model.ptzError { message(failure, error: true) }
                    Text("Each click makes a short movement.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Speed"); Slider(value: $model.speed, in: 0.05...1).disabled(model.moving) }
                    HStack {
                        Button("Zoom out", systemImage: "minus.magnifyingglass") { model.nudge(pan: 0, tilt: 0, zoom: velocity(-1, range: model.ptzOptions?.zoomRange)) }
                        Button("Zoom in", systemImage: "plus.magnifyingglass") { model.nudge(pan: 0, tilt: 0, zoom: velocity(1, range: model.ptzOptions?.zoomRange)) }
                    }.disabled(!canMove || model.ptzOptions?.zoomRange == nil)
                    Divider()
                    Text("Presets").font(.headline)
                    if let failure = model.presetError { message(failure, error: true) }
                    if model.presets.isEmpty { Text("No presets returned by this camera.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.presets) { preset in
                        HStack { Text(preset.name.isEmpty ? String(localized: "Preset") : preset.name).lineLimit(1); Spacer(); Button("Go") { model.goToPreset(preset.token) }.disabled(!canMove) }
                    }
                    HStack {
                        TextField("Preset name", text: $model.presetName)
                        Button("Save preset") { model.savePreset() }.disabled(!model.credentialsProvided || model.busy || model.moving || model.profile == nil || model.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if model.ptzOptions == nil && !model.loadingDetails { Text("No supported movement options were returned.").font(.caption).foregroundStyle(.secondary) }
                }.padding(12)
            }.frame(width: 290)
        }.padding(12)
    }
    private var canMove: Bool { model.credentialsProvided && !model.moving && !model.busy && !model.restarting && model.ptzOptions != nil }
    private func velocity(_ direction: Double, range: ClosedRange<Double>?) -> Double {
        guard direction != 0, let range else { return 0 }
        return direction < 0 ? min(0, range.lowerBound) * model.speed : max(0, range.upperBound) * model.speed
    }
    private func moveButton(_ icon: String, pan: Double, tilt: Double, label: LocalizedStringKey) -> some View {
        let x = velocity(pan, range: model.ptzOptions?.panRange), y = velocity(tilt, range: model.ptzOptions?.tiltRange)
        return Button { model.nudge(pan: x, tilt: y, zoom: 0) } label: { Image(systemName: icon).frame(width: 36, height: 30) }
            .disabled(!canMove || (pan != 0 && x == 0) || (tilt != 0 && y == 0))
            .help(Text(label)).accessibilityLabel(Text(label))
    }
    private var profilePicker: some View {
        Picker("Video profile", selection: Binding(get: { model.profileToken }, set: { if let token = $0 { request(.profile(token), needsDiscard: model.hasImageChanges) } })) {
            ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.token)) }
        }.frame(maxWidth: 280).disabled(model.profiles.isEmpty || model.moving || model.busy || model.restarting)
    }
    private var imageSettings: some View {
        VStack {
            HStack { profilePicker; Spacer(); Button("Reset changes") { model.imagingDraft = Dictionary(uniqueKeysWithValues: model.imaging.map { ($0.path, $0.value) }) }.disabled(model.busy); Button("Apply image settings") { model.applyImaging() }.disabled(!model.credentialsProvided || model.busy || model.moving || !model.hasImageChanges || !imageDraftValid) }.padding(12)
            if model.imaging.isEmpty {
                ContentUnavailableView("No image controls", systemImage: "camera.filters", description: Text(model.imagingError ?? String(localized: "Select a profile and refresh. Controls depend on the camera's advertised options.")))
            } else {
                Form {
                    ForEach(model.imaging) { field in
                        LabeledContent(imageLabel(field.path)) {
                            if !field.isWritable { Text(field.value).foregroundStyle(.secondary) }
                            else if !field.choices.isEmpty {
                                Picker(field.path, selection: imageBinding(field)) { ForEach(field.choices, id: \.self) { Text(optionLabel($0)).tag($0) } }.labelsHidden()
                            } else if let range = field.range {
                                HStack {
                                    if range.lowerBound < range.upperBound {
                                        Slider(value: Binding(get: { Double(model.imagingDraft[field.path] ?? field.value) ?? range.lowerBound }, set: { model.imagingDraft[field.path] = String($0) }), in: range)
                                    }
                                    TextField(field.path, text: imageBinding(field)).frame(width: 100)
                                }.disabled(range.lowerBound == range.upperBound)
                            } else { Text(field.value).foregroundStyle(.secondary) }
                        }
                    }
                }.formStyle(.grouped).disabled(model.busy || !model.credentialsProvided)
            }
        }
    }
    private func optionLabel(_ value: String) -> String {
        switch value {
        case "AUTO": String(localized: "Automatic")
        case "MANUAL": String(localized: "Manual")
        case "ON": String(localized: "On")
        case "OFF": String(localized: "Off")
        case "LowNoise": String(localized: "Low noise")
        case "FrameRate": String(localized: "Frame rate")
        default: value
        }
    }
    private func imageBinding(_ field: ONVIFImagingSetting) -> Binding<String> { Binding(get: { model.imagingDraft[field.path] ?? field.value }, set: { model.imagingDraft[field.path] = $0 }) }
    private var imageDraftValid: Bool {
        model.imaging.allSatisfy { field in
            guard field.isWritable else { return true }
            let value = model.imagingDraft[field.path] ?? field.value
            if !field.choices.isEmpty { return field.choices.contains(value) }
            if let range = field.range { guard let number = Double(value), number.isFinite else { return false }; return range.contains(number) }
            return value == field.value
        }
    }
    private func imageLabel(_ path: String) -> String {
        let labels: [String: String] = ["Brightness": String(localized: "Brightness"), "Contrast": String(localized: "Contrast"), "ColorSaturation": String(localized: "Saturation"), "Sharpness": String(localized: "Sharpness"), "IrCutFilter": String(localized: "Night vision"), "Exposure.Mode": String(localized: "Exposure mode"), "WhiteBalance.Mode": String(localized: "White balance"), "WideDynamicRange.Mode": String(localized: "Wide dynamic range")]
        return labels[path] ?? path.replacingOccurrences(of: ".", with: " · ")
    }
    private var deviceSettings: some View {
        HStack(spacing: 0) {
            VStack {
                TextField("Search settings", text: $search).textFieldStyle(.roundedBorder).padding(10)
                List(selection: Binding(get: { model.selectedSection?.id }, set: { id in
                    guard let next = DeviceSettingSection.all.first(where: { $0.id == id }) else { return }
                    request(.section(next), needsDiscard: model.hasDeviceChanges)
                })) {
                    ForEach(groups, id: \.self) { group in
                        Section(localizedGroup(group)) {
                            ForEach(visibleSections.filter { $0.group == group }) { section in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title)
                                    if let failure = model.sectionErrors[section.id] { Text(failure).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                                }.tag(section.id).help(section.name)
                            }
                        }
                    }
                }.disabled(model.busy || model.restarting)
                Text("Checked \(model.checkedSettings) of \(DeviceSettingSection.all.count)").font(.caption).foregroundStyle(.secondary)
                Toggle("Show unverified settings", isOn: $showUnverified).toggleStyle(.checkbox).font(.caption).padding(.horizontal, 10)
                if model.checkingSettings {
                    HStack { ProgressView().controlSize(.small); Text("Checking settings…").font(.caption); Button("Pause") { model.pauseCheckingSettings() } }.padding(10)
                } else {
                    Button("Check device settings") { model.startCheckingSettings() }.disabled(!model.deviceReady).padding(10)
                }
            }.frame(width: 240)
            Divider()
            VStack(alignment: .leading) {
                if let section = model.selectedSection {
                    HStack { Text(section.title).font(.title3.weight(.semibold)); Spacer(); Button("Reload") { request(.section(section), needsDiscard: model.hasDeviceChanges) }.disabled(!model.deviceReady || model.busy) }.padding(12)
                }
                if let value = model.deviceDraft, let section = model.selectedSection {
                    ScrollView {
                        DeviceSettingsEditor(value: Binding(get: { model.deviceDraft ?? value }, set: { model.deviceDraft = $0 }), invalidPaths: $model.invalidPaths, readOnly: section.readOnly || model.busy || model.requiresRestart)
                            .id(model.settingsRevision).padding(16)
                    }
                } else if model.busy { ProgressView("Loading settings…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView(model.deviceReady ? String(localized: "Choose a settings category") : String(localized: "Connect for device settings"), systemImage: "slider.horizontal.3", description: Text("Authenticate with local camera credentials to load supported device settings.")) }
                if let error = model.deviceError { message(error, error: true) }
                HStack {
                    Button("Restart camera…", systemImage: "arrow.clockwise") { confirmRestart = true }.disabled(!model.deviceReady || model.busy || model.moving || model.restarting)
                    Spacer()
                    if model.selectedSection?.readOnly == true { Text("Read only").font(.caption).foregroundStyle(.secondary) }
                    Button("Apply changes") { confirmApply = true }.buttonStyle(.borderedProminent)
                        .disabled(!model.deviceReady || model.busy || model.moving || model.requiresRestart || model.selectedSection?.readOnly != false || !model.hasDeviceChanges || !model.invalidPaths.isEmpty)
                }.padding(12)
            }.frame(maxWidth: .infinity)
        }
    }
    private func request(_ action: DiscardAction, needsDiscard: Bool) {
        if needsDiscard { pendingAction = action; confirmDiscard = true }
        else { perform(action) }
    }
    private func perform(_ action: DiscardAction) {
        switch action {
        case .section(let section): model.loadSection(section)
        case .profile(let token): model.selectProfile(token)
        case .refresh: model.refreshProfile()
        case .authenticate(let video): connectVideo = video; authenticating = true
        }
    }
    private func localizedGroup(_ group: String) -> String {
        switch group {
        case "Device information": String(localized: "Device information")
        case "Image and lighting": String(localized: "Image and lighting")
        case "Video and audio": String(localized: "Video and audio")
        case "Detection and alarms": String(localized: "Detection and alarms")
        case "Recording and storage": String(localized: "Recording and storage")
        case "Network": String(localized: "Network")
        case "Time and privacy": String(localized: "Time and privacy")
        default: String(localized: "Movement settings")
        }
    }
}
