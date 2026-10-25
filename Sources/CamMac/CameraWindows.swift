import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class CameraWindows: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]
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
    func close(_ id: UUID) { windows[id]?.close() }
    func closeAll() { Array(windows.values).forEach { $0.close() } }
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
        guard let window = notification.object as? NSWindow, let id = cameraID(window) else { return }
        fullscreenIDs.remove(id)
        windows.removeValue(forKey: id)
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
                    isFullscreen: windows.fullscreenIDs.contains(cameraID), connect: { authenticating = true })
                .sheet(isPresented: $authenticating) {
                    CredentialSheet(camera: camera) { credentials in store.session(camera).start(camera: camera, credentials: credentials) }
                }
                .onChange(of: camera.name) { _, name in windows.updateTitle(name, id: cameraID) }
            } else { Color.black.onAppear { windows.close(cameraID) } }
        }.onExitCommand { windows.exitFullscreen(cameraID) }
    }
}
