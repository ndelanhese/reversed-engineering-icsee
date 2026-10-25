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
                        else { CredentialStore.remove(camera.id) }
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
            if let saved = CredentialStore.load(camera.id) {
                username = saved.username; password = saved.password; remember = true
            }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing ? String(localized: "Edit camera") : String(localized: "Add camera")).font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $camera.name)
                TextField("IP address or hostname", text: $camera.host)
                TextField("RTSP port", value: $camera.port, format: .number.grouping(.never))
                Stepper("Channel \(camera.channel)", value: $camera.channel, in: 1...64)
                Toggle("Substream", isOn: $camera.substream)
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
                        save(camera); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).disabled(camera.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(28).frame(width: 440)
    }
}
