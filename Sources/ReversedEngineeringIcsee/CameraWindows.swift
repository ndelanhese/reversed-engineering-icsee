import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class CameraWindows: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]
    private var controlWindows: [UUID: NSWindow] = [:]
    private var controlModels: [UUID: CameraControlModel] = [:]
    private var recordingWindows: [UUID: NSWindow] = [:]
    private var recordingModels: [UUID: CameraRecordingsModel] = [:]
    private var pendingControlShutdowns: [UUID: Task<Void, Never>] = [:]
    private var terminating = false
    var hasControlsToShutdown: Bool { !controlModels.isEmpty || !recordingModels.isEmpty || !pendingControlShutdowns.isEmpty }
    var fullscreenIDs: Set<UUID> = []
    func open(camera: Camera, store: CameraStore, fullscreen: Bool = false) {
        guard store.cameras.contains(where: { $0.id == camera.id }) else { return }
        let window: NSWindow
        if let existing = windows[camera.id] { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("camera-\(camera.id)")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 320, height: 240)
            window.collectionBehavior = [.fullScreenPrimary]
            window.backgroundColor = .black
            window.delegate = self
            windows[camera.id] = window
            window.contentView = NSHostingView(rootView: DetachedCameraView(cameraID: camera.id, store: store, windows: self))
            window.center()
        }
        window.title = camera.name
        window.level = fullscreen ? .normal : .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if fullscreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func toggleFullscreen(_ id: UUID) {
        guard let window = windows[id] else { return }
        window.level = .normal
        window.toggleFullScreen(nil)
    }
    func exitFullscreen(_ id: UUID) {
        guard let window = windows[id], window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
    func updateTitle(_ title: String, id: UUID) { windows[id]?.title = title }
    @discardableResult func openControls(camera: Camera, store: CameraStore) -> CameraControlModel? {
        guard !terminating, store.cameras.contains(where: { $0.id == camera.id }) else { return nil }
        let window: NSWindow
        if let existing = controlWindows[camera.id] { window = existing }
        else {
            let model = CameraControlModel(camera: camera)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("controls-\(camera.id)")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 900, height: 640)
            window.delegate = self
            controlWindows[camera.id] = window
            controlModels[camera.id] = model
            window.contentView = NSHostingView(rootView: CameraControlsView(cameraID: camera.id, store: store, windows: self, model: model))
            window.center()
        }
        window.title = camera.name
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return controlModels[camera.id]
    }
    @discardableResult func openRecordings(camera: Camera, store: CameraStore) -> CameraRecordingsModel? {
        guard !terminating, store.cameras.contains(where: { $0.id == camera.id }) else { return nil }
        let window: NSWindow
        if let existing = recordingWindows[camera.id] { window = existing }
        else {
            let model = CameraRecordingsModel(camera: camera)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("recordings-\(camera.id)")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 940, height: 740)
            window.delegate = self
            recordingWindows[camera.id] = window; recordingModels[camera.id] = model
            window.contentView = NSHostingView(rootView: CameraRecordingsView(cameraID: camera.id, store: store, windows: self, model: model))
            window.center()
        }
        window.title = camera.name
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        return recordingModels[camera.id]
    }
    func updateRecordingsTitle(_ title: String, id: UUID) { recordingWindows[id]?.title = title }
    func closeRecordings(_ id: UUID) { recordingWindows[id]?.close() }
    func disconnectRecordings() { recordingModels.values.forEach { $0.disconnect() } }
    func prepareForTermination() async {
        terminating = true
        Array(controlWindows.values).forEach { $0.close() }
        Array(recordingWindows.values).forEach { $0.close() }
        let pending = Array(pendingControlShutdowns.values)
        await withTaskGroup(of: Void.self) { group in
            for task in pending { group.addTask { await task.value } }
        }
    }
    func updateControlTitle(_ title: String, id: UUID) { controlWindows[id]?.title = title }
    func closeControls(_ id: UUID) { controlWindows[id]?.close() }
    func disconnectControls() { controlModels.values.forEach { $0.disconnect() } }
    func close(_ id: UUID) { windows[id]?.close() }
    func closeAll() {
        Array(controlWindows.values).forEach { $0.close() }
        Array(recordingWindows.values).forEach { $0.close() }
        Array(windows.values).forEach { $0.close() }
    }
    private func cameraID(_ window: NSWindow) -> UUID? { windows.first { $0.value === window }?.key }
    func windowWillEnterFullScreen(_ notification: Notification) { (notification.object as? NSWindow)?.level = .normal }
    func windowDidEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let id = cameraID(window) { fullscreenIDs.insert(id) }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = cameraID(window) else { return }
        fullscreenIDs.remove(id)
        window.level = .floating
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let id = recordingWindows.first(where: { $0.value === window })?.key {
            if let model = recordingModels.removeValue(forKey: id) { trackShutdown(Task { await model.shutdown() }) }
            recordingWindows.removeValue(forKey: id)
            return
        }
        if let id = controlWindows.first(where: { $0.value === window })?.key {
            if let model = controlModels.removeValue(forKey: id) {
                trackShutdown(Task { await model.shutdown() })
            }
            controlWindows.removeValue(forKey: id)
            return
        }
        guard let id = cameraID(window) else { return }
        fullscreenIDs.remove(id)
        windows.removeValue(forKey: id)
    }
    private func trackShutdown(_ task: Task<Void, Never>) {
        let ticket = UUID()
        pendingControlShutdowns[ticket] = task
        Task { [weak self] in await task.value; self?.pendingControlShutdowns[ticket] = nil }
    }
}

struct DetachedCameraView: View {
    let cameraID: UUID
    @Bindable var store: CameraStore
    @Bindable var windows: CameraWindows
    @ViewState private var authenticating = false
    var body: some View {
        Group {
            if let camera = store.cameras.first(where: { $0.id == cameraID }) {
                CameraStage(camera: camera, session: store.session(camera),
                    fullscreen: { windows.toggleFullscreen(cameraID) },
                    isFullscreen: windows.fullscreenIDs.contains(cameraID), connect: { authenticating = true },
                    controls: { windows.openControls(camera: camera, store: store) },
                    recordings: { windows.openRecordings(camera: camera, store: store) })
                .sheet(isPresented: $authenticating) {
                    CredentialSheet(camera: camera) { credentials in store.session(camera).start(camera: camera, credentials: credentials) }
                }
                .onChange(of: camera.name) { _, name in windows.updateTitle(name, id: cameraID) }
            } else { Color.black.onAppear { windows.close(cameraID) } }
        }.onExitCommand { windows.exitFullscreen(cameraID) }
    }
}
