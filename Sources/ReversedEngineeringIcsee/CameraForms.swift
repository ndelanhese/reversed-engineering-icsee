import SwiftUI

struct RenameSheet: View {
    let camera: Camera
    var save: (Camera) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename camera").font(.title2.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    var renamed = camera
                    renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(renamed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 360)
        .onAppear { name = camera.name }
    }
}

struct CredentialSheet: View {
    let camera: Camera
    var connect: (Credentials) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var username = "admin"
    @ViewState private var password = ""
    @ViewState private var remember = false
    @ViewState private var loadedSavedCredentials = false
    @ViewState private var attemptedLoad = false
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to \(camera.name)").font(.title2.weight(.semibold))
            Text(camera.host).foregroundStyle(.secondary)
            Form {
                TextField("Local username", text: $username)
                SecureField("Camera password", text: $password)
                Toggle("Save in macOS Keychain", isOn: $remember)
            }
            Text("Use device credentials. They may differ from your iCSee account.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Connect") {
                    let value = Credentials(username: username, password: password)
                    do {
                        if remember { try CredentialStore.save(value, for: camera.id) }
                        else if loadedSavedCredentials { CredentialStore.remove(camera.id) }
                        connect(value)
                        password = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(username.isEmpty)
            }
        }
        .padding(28).frame(width: 420)
        .onAppear {
            guard !attemptedLoad else { return }
            attemptedLoad = true
            do {
                if let saved = try CredentialStore.load(camera.id) {
                    username = saved.username; password = saved.password; remember = true
                    loadedSavedCredentials = true
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CameraEditor: View {
    @ViewState var camera: Camera
    let existing: Bool
    var save: (Camera) -> Void
    var remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var error: String?
    @ViewState private var discovery = CameraDiscoveryModel()
    @ViewState private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing ? String(localized: "Edit camera") : String(localized: "Add camera")).font(.title2.weight(.semibold))
            if !existing { discoverySection }
            Form {
                TextField("Name", text: $camera.name)
                if !camera.host.isEmpty && !advanced { LabeledContent("Address", value: camera.host) }
                DisclosureGroup("Manual setup and advanced", isExpanded: $advanced) {
                    TextField("IP address or hostname", text: $camera.host)
                    TextField("RTSP port", value: $camera.port, format: .number.grouping(.never))
                    Stepper("Channel \(camera.channel)", value: $camera.channel, in: 1...64)
                    Toggle("Substream", isOn: $camera.substream)
                    TextField("ONVIF port", value: $camera.onvifPort, format: .number.grouping(.never))
                    TextField("ONVIF service path", text: $camera.onvifPath)
                    TextField("Device control port", value: $camera.controlPort, format: .number.grouping(.never))
                }
            }
            Text("For remote access, the address must be reachable over a VPN. iCSee cloud login is not available yet.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if existing { Button("Remove", role: .destructive) { remove(); dismiss() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    do {
                        _ = try camera.endpoint.playlist(username: "validation", password: "")
                        guard (1...65535).contains(camera.onvifPort), (1...65535).contains(camera.controlPort),
                              camera.onvifPath.hasPrefix("/"), !camera.onvifPath.hasPrefix("//"), camera.onvifPath.utf8.count <= 1024,
                              !camera.onvifPath.contains(where: { $0.isNewline || "?#\\".contains($0) }) else { throw CameraError.invalidEndpoint }
                        save(camera); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(camera.name.trimmingCharacters(in: .whitespaces).isEmpty || camera.host.isEmpty || discovery.isScanning)
            }
        }.padding(28).frame(width: 480)
        .onAppear { advanced = existing }
        .onDisappear { discovery.cancel() }
    }
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Find cameras", systemImage: "magnifyingglass") { discovery.start() }
                    .disabled(discovery.isScanning)
                if discovery.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel search") { discovery.cancel() }
                }
            }
            Text("Search this network for ONVIF cameras. No login is sent. The search takes about five seconds.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = discovery.error { Text(error).font(.callout).foregroundStyle(.red) }
            if discovery.hasSearched && discovery.devices.isEmpty {
                Text("No cameras found. Check that ONVIF is enabled and both devices are on the same network, or use manual setup.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !discovery.devices.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discovery.devices) { device in
                            Button {
                                camera.apply(device)
                                advanced = false
                                error = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).lineLimit(1)
                                        Text(verbatim: "\(device.host) · ONVIF \(device.onvifPort.formatted(.number.grouping(.never)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if camera.host == device.host { Image(systemName: "checkmark.circle.fill") }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.bordered)
                        }
                    }
                }.frame(maxHeight: 150)
            }
            if !camera.host.isEmpty {
                Text("Address and ONVIF port are filled in. RTSP and device control use standard ports; change them in advanced settings if needed. Save, then connect with the camera's local login.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
