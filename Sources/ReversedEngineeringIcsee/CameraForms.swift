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
            Text(camera.host.isEmpty ? String(localized: "Remote connection") : camera.host).foregroundStyle(.secondary)
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

private enum RemoteSettingsError: LocalizedError {
    case invalidSerial
    var errorDescription: String? { String(localized: "Enter a valid camera serial number from iCSee.") }
}

struct CameraEditor: View {
    @ViewState var camera: Camera
    let existing: Bool
    var save: (Camera) -> Void
    var remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing ? String(localized: "Edit camera") : String(localized: "Add camera")).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $camera.name)
                Toggle("Allow remote access", isOn: $camera.remoteEnabled)
                if camera.remoteEnabled {
                    TextField("Camera serial number", text: $camera.remoteSerial)
                    Text("Remote access uses vendor servers and may expose video and a reusable camera password hash.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("The local IP is used on the same network; otherwise the app connects remotely. Find the serial number in iCSee device information.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                TextField("IP address or hostname", text: $camera.host)
                TextField("RTSP port", value: $camera.port, format: .number.grouping(.never))
                Stepper("Channel \(camera.channel)", value: $camera.channel, in: 1...64)
                Toggle("Substream", isOn: $camera.substream)
                TextField("ONVIF port", value: $camera.onvifPort, format: .number.grouping(.never))
                TextField("Device control port", value: $camera.controlPort, format: .number.grouping(.never))
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if existing { Button("Remove", role: .destructive) { remove(); dismiss() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    do {
                        if camera.remoteEnabled {
                            camera.remoteSerial = camera.remoteSerial.trimmingCharacters(in: .whitespacesAndNewlines)
                            do { _ = try RemoteProtocol.lookupRequest(serial: camera.remoteSerial) }
                            catch { throw RemoteSettingsError.invalidSerial }
                        }
                        if !camera.host.isEmpty || !camera.remoteEnabled { _ = try camera.endpoint.playlist(username: "validation", password: "") }
                        guard (1...65535).contains(camera.onvifPort), (1...65535).contains(camera.controlPort) else { throw CameraError.invalidEndpoint }
                        save(camera); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(camera.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 440)
    }
}
