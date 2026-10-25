import SwiftUI
import AppKit

@MainActor
final class CameraAppLifecycle: NSObject, NSApplicationDelegate {
    var store: CameraStore?
    var windows: CameraWindows?
    func applicationWillTerminate(_ notification: Notification) { windows?.closeAll(); store?.stopAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ReversedEngineeringIcseeApp: App {
    @NSApplicationDelegateAdaptor(CameraAppLifecycle.self) private var lifecycle
    @ViewState private var store = CameraStore()
    @ViewState private var windows = CameraWindows()
    var body: some Scene {
        Window("Reversed engineering Icsee", id: "main") {
            CameraBoard(store: store, windows: windows).frame(minWidth: 880, minHeight: 580)
                .onAppear { lifecycle.store = store; lifecycle.windows = windows }
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Tela cheia") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}

struct CameraBoard: View {
    @Bindable var store: CameraStore
    let windows: CameraWindows
    @ViewState private var selected = "all"
    @ViewState private var editing: Camera?
    @ViewState private var authenticating: Camera?
    @ViewState private var renaming: Camera?
    @ViewState private var cinemaID: UUID?
    private var visible: [Camera] { selected == "all" ? store.cameras : store.cameras.filter { $0.id.uuidString == selected } }
    private var cinemaCamera: Camera? { store.cameras.first { $0.id == cinemaID } }
    var body: some View {
        Group {
            if let camera = cinemaCamera {
                CameraStage(camera: camera, session: store.session(camera), back: { cinemaID = nil },
                    popup: { windows.open(camera: camera, store: store) },
                    fullscreen: { windows.open(camera: camera, store: store, fullscreen: true) }, connect: { authenticating = camera })
                .onExitCommand { cinemaID = nil }
            } else { board }
        }
        .toolbar(cinemaCamera == nil ? .automatic : .hidden, for: .windowToolbar)
        .sheet(item: $authenticating) { camera in
            CredentialSheet(camera: camera) { credentials in store.session(camera).start(camera: camera, credentials: credentials) }
        }
        .sheet(item: $editing) { camera in
            CameraEditor(camera: camera, existing: store.cameras.contains(where: { $0.id == camera.id }),
                save: { store.save($0) }, remove: { store.remove(camera); selected = "all" })
        }
        .sheet(item: $renaming) { camera in RenameSheet(camera: camera, save: { store.save($0) }) }
    }
    private var board: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Label("Todas as câmeras", systemImage: "square.grid.2x2").tag("all")
                Section("Câmeras") {
                    ForEach(store.cameras) { camera in Label(camera.name, systemImage: "video").tag(camera.id.uuidString) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button { editing = Camera(name: "Nova câmera", host: "") } label: {
                    Label("Adicionar câmera", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding().keyboardShortcut("n")
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected == "all" ? "Suas câmeras" : (visible.first?.name ?? "Câmeras")).font(.largeTitle.weight(.semibold))
                        Text("Vídeo direto da sua rede.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: visible.count == 1 ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 380), spacing: 20)], spacing: 20) {
                        ForEach(visible) { camera in
                            CameraTile(camera: camera, session: store.session(camera),
                                connect: { authenticating = camera }, edit: { editing = camera }, rename: { renaming = camera },
                                cinema: { cinemaID = camera.id }, popup: { windows.open(camera: camera, store: store) },
                                fullscreen: { windows.open(camera: camera, store: store, fullscreen: true) })
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("Nenhuma câmera", systemImage: "video", description: Text("Adicione endereço e credenciais para começar."))
                    }
                }.padding(28)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar { ToolbarItem { Button("Desconectar todas", systemImage: "stop.circle") { store.stopAll() } }
            }
        }
    }
}

struct CameraTile: View {
    let camera: Camera
    @Bindable var session: CameraSession
    var connect: () -> Void
    var edit: () -> Void
    var rename: () -> Void
    var cinema: () -> Void
    var popup: () -> Void
    var fullscreen: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            CameraVideo(session: session).aspectRatio(16/9, contentMode: .fit)
                .onTapGesture(count: 2, perform: cinema).help("Duplo clique para modo cinema")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.name).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(session.state == .live ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        Text(session.state == .live ? "Ao vivo · \(camera.host)" : camera.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if session.state == .live || session.state == .connecting {
                    Button("Parar", systemImage: "stop.fill") { session.stop() }
                } else { Button("Conectar", action: connect).buttonStyle(.borderedProminent) }
                Button(action: cinema) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("Modo cinema").accessibilityLabel("Modo cinema")
                Menu {
                    Button("Popup flutuante", systemImage: "rectangle.on.rectangle", action: popup)
                    Button("Modo cinema", systemImage: "rectangle.expand.vertical", action: cinema)
                    Button("Tela cheia", systemImage: "arrow.up.left.and.arrow.down.right", action: fullscreen)
                    Divider()
                    Button("Renomear…", systemImage: "pencil", action: rename)
                    Button("Configurar…", systemImage: "slider.horizontal.3", action: edit)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Opções de \(camera.name)").accessibilityLabel("Opções de \(camera.name)")
            }.padding(16).background(.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }
}
