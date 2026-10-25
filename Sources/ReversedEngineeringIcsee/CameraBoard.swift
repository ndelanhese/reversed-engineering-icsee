import SwiftUI

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
                    fullscreen: { windows.open(camera: camera, store: store, fullscreen: true) }, connect: { authenticating = camera },
                    controls: { windows.openControls(camera: camera, store: store) })
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
                Label("All cameras", systemImage: "square.grid.2x2").tag("all")
                Section("Cameras") {
                    ForEach(store.cameras) { camera in Label(camera.name, systemImage: "video").tag(camera.id.uuidString) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button { editing = Camera(name: String(localized: "New camera"), host: "") } label: {
                    Label("Add camera", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding().keyboardShortcut("n")
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selected == "all" ? String(localized: "Your cameras") : (visible.first?.name ?? String(localized: "Cameras"))).font(.largeTitle.weight(.semibold))
                        Text("Video directly from your network.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: visible.count == 1 ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 380), spacing: 20)], spacing: 20) {
                        ForEach(visible) { camera in
                            CameraTile(camera: camera, session: store.session(camera),
                                connect: { authenticating = camera }, edit: { editing = camera }, rename: { renaming = camera },
                                cinema: { cinemaID = camera.id }, popup: { windows.open(camera: camera, store: store) },
                                fullscreen: { windows.open(camera: camera, store: store, fullscreen: true) },
                                isPreviewCamera: store.menuBarCamera?.id == camera.id,
                                useForPreview: { store.selectMenuBarCamera(camera.id) },
                                controls: { windows.openControls(camera: camera, store: store) })
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("No cameras", systemImage: "video", description: Text("Add an address and credentials to get started."))
                    }
                }.padding(28)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar { ToolbarItem { Button("Disconnect all", systemImage: "stop.circle") { windows.disconnectControls(); store.stopAll() } }
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
    var isPreviewCamera: Bool
    var useForPreview: () -> Void
    var controls: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            CameraVideo(session: session).aspectRatio(16/9, contentMode: .fit)
                .onTapGesture(count: 2, perform: cinema).help("Double-click for cinema mode")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.name).font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(session.state == .live ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        Text(session.state == .live ? String(localized: "Live · \(camera.host)") : camera.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if session.state == .live || session.state == .connecting {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                } else { Button("Connect", action: connect).buttonStyle(.borderedProminent) }
                Button(action: cinema) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).help("Cinema mode").accessibilityLabel("Cinema mode")
                Menu {
                    Button("Camera controls…", systemImage: "slider.horizontal.3", action: controls)
                    Divider()
                    Button("Floating window", systemImage: "rectangle.on.rectangle", action: popup)
                    Button("Cinema mode", systemImage: "rectangle.expand.vertical", action: cinema)
                    Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right", action: fullscreen)
                    Divider()
                    Button(isPreviewCamera ? String(localized: "Default preview camera") : String(localized: "Use for menu bar preview"),
                           systemImage: isPreviewCamera ? "checkmark" : "menubar.rectangle", action: useForPreview)
                        .disabled(isPreviewCamera)
                    Divider()
                    Button("Rename…", systemImage: "pencil", action: rename)
                    Button("Configure…", systemImage: "slider.horizontal.3", action: edit)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help(String(localized: "Options for \(camera.name)")).accessibilityLabel(String(localized: "Options for \(camera.name)"))
            }.padding(16).background(.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }
}
