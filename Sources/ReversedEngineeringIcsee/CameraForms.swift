import SwiftUI

struct RenameSheet: View {
    let camera: Camera
    var save: (Camera) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Renomear câmera").font(.title2.weight(.semibold))
            TextField("Nome", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                Spacer()
                Button("Salvar") {
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
            Text("Conectar a \(camera.name)").font(.title2.weight(.semibold))
            Text(camera.host).foregroundStyle(.secondary)
            Form {
                TextField("Usuário local", text: $username)
                SecureField("Senha da câmera", text: $password)
                Toggle("Salvar no Chaves do macOS", isOn: $remember)
            }
            Text("Use credenciais do dispositivo. Elas podem ser diferentes da conta iCSee.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                Spacer()
                Button("Conectar") {
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
            Text(existing ? "Editar câmera" : "Adicionar câmera").font(.title2.weight(.semibold))
            Form {
                TextField("Nome", text: $camera.name)
                TextField("IP ou nome de rede", text: $camera.host)
                TextField("Porta RTSP", value: $camera.port, format: .number.grouping(.never))
                Stepper("Canal \(camera.channel)", value: $camera.channel, in: 1...64)
                Toggle("Fluxo leve", isOn: $camera.substream)
            }
            Text("Fora de casa, endereço precisa estar acessível por VPN. Login pela nuvem iCSee ainda não está disponível.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if existing { Button("Remover", role: .destructive) { remove(); dismiss() } }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                Button("Salvar") {
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
