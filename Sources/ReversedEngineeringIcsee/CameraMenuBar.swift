import AppKit
import SwiftUI

@MainActor
final class CameraAppLifecycle: NSObject, NSApplicationDelegate {
    private var store: CameraStore?
    private var windows: CameraWindows?
    private(set) var menuBar: CameraMenuBar?
    private var terminationPending = false
    func configure(store: CameraStore, windows: CameraWindows, openMain: @escaping () -> Void) {
        guard menuBar == nil else { return }
        self.store = store
        self.windows = windows
        let menu = CameraMenuBar(store: store, windows: windows, openMain: openMain)
        menuBar = menu
        menu.install()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windows, windows.hasControlsToShutdown else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await windows.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.uninstall()
        windows?.closeAll()
        store?.stopAll()
    }
}

@MainActor
final class CameraMenuBar: NSObject, NSPopoverDelegate {
    private(set) var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let store: CameraStore
    private let windows: CameraWindows
    private let openMain: () -> Void
    private var trackingArea: NSTrackingArea?
    private var clickMonitor: Any?
    private var showTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var overButton = false
    private var overPreview = false
    private var pinned = false
    var isShown: Bool { popover.isShown }

    init(store: CameraStore, windows: CameraWindows, openMain: @escaping () -> Void) {
        self.store = store
        self.windows = windows
        self.openMain = openMain
    }
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = Self.icon()
        button.setAccessibilityLabel("Reversed engineering Icsee")
        button.toolTip = String(localized: "Hover for camera preview. Click to keep it open.")
        button.target = self
        button.action = #selector(togglePreview)
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        button.addTrackingArea(area)
        trackingArea = area
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 330)
        popover.contentViewController = NSHostingController(rootView: CameraMenuBarPreview(store: store, menuBar: self))
        // Any explicit interaction pins the panel before a picker or sheet moves the pointer away.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isShown, event.window === self.popover.contentViewController?.view.window { self.pin() }
            }
            return event
        }
    }
    func uninstall() {
        showTask?.cancel(); closeTask?.cancel()
        showTask = nil; closeTask = nil
        popover.close()
        popover.contentViewController = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let button = statusItem?.button, let trackingArea { button.removeTrackingArea(trackingArea) }
        trackingArea = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        overButton = false; overPreview = false; pinned = false
    }
    @objc func mouseEntered(with event: NSEvent) { pointerEnteredStatusItem() }
    @objc func mouseExited(with event: NSEvent) { pointerExitedStatusItem() }
    func pointerEnteredStatusItem() {
        overButton = true
        closeTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.overButton else { return }
            self.showPreview()
        }
    }
    func pointerExitedStatusItem() {
        overButton = false
        showTask?.cancel()
        scheduleClose()
    }
    func pointerEnteredPreview() { overPreview = true; closeTask?.cancel() }
    func pointerExitedPreview() { overPreview = false; scheduleClose() }
    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, !self.overButton, !self.overPreview, !self.pinned else { return }
            self.popover.close()
        }
    }
    private func showPreview() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func pin() { pinned = true; closeTask?.cancel() }
    @objc func togglePreview() {
        showTask?.cancel()
        if isShown && pinned { popover.close() }
        else { pin(); showPreview() }
    }
    func setAuthenticating(_ active: Bool) {
        if active { pin() }
        popover.behavior = active ? .applicationDefined : .transient
    }
    func openMainWindow() { popover.close(); NSApp.activate(); openMain() }
    func openPopup(_ camera: Camera) { popover.close(); windows.open(camera: camera, store: store) }
    func openControls(_ camera: Camera) { popover.close(); windows.openControls(camera: camera, store: store) }
    func popoverDidClose(_ notification: Notification) {
        pinned = false; overPreview = false
        closeTask?.cancel()
        popover.behavior = .transient
    }
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let lens = NSBezierPath(ovalIn: NSRect(x: 4, y: 2.5, width: 10, height: 10))
            lens.lineWidth = 1.5; lens.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7, y: 5.5, width: 4, height: 4)).fill()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 7.5), radius: 7.3, startAngle: 25, endAngle: 150)
            arc.lineWidth = 1.5; arc.lineCapStyle = .round; arc.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 1.4, y: 10.5))
            arrow.line(to: NSPoint(x: 2.2, y: 15.7))
            arrow.line(to: NSPoint(x: 5.5, y: 12.2)); arrow.close(); arrow.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private struct CameraMenuBarPreview: View {
    @Bindable var store: CameraStore
    let menuBar: CameraMenuBar
    @ViewState private var authenticating: Camera?
    var body: some View {
        VStack(spacing: 12) {
            if let camera = store.menuBarCamera {
                Picker("Preview camera", selection: Binding(get: { store.menuBarCamera?.id }, set: { if let id = $0 { store.selectMenuBarCamera(id) } })) {
                    ForEach(store.cameras) { camera in Text(camera.name).tag(Optional(camera.id)) }
                }
                CameraVideo(session: store.session(camera))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(store.session(camera).state.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.session(camera).state == .live || store.session(camera).state == .connecting {
                        Button("Stop", systemImage: "stop.fill") { store.session(camera).stop() }
                    } else {
                        Button("Connect") { menuBar.setAuthenticating(true); authenticating = camera }
                    }
                    Button("Floating window", systemImage: "rectangle.on.rectangle") { menuBar.openPopup(camera) }
                }.controlSize(.small)
                Button("Camera controls…", systemImage: "slider.horizontal.3") { menuBar.openControls(camera) }
                    .controlSize(.small)
            } else {
                ContentUnavailableView("No cameras", systemImage: "video", description: Text("Add an address and credentials to get started."))
                    .frame(height: 220)
            }
            Divider()
            HStack {
                Button("Open app", systemImage: "macwindow") { menuBar.openMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless)
        }
        .padding(14).frame(width: 380)
        .onHover { inside in
            if inside { menuBar.pointerEnteredPreview() } else { menuBar.pointerExitedPreview() }
        }
        .sheet(item: $authenticating, onDismiss: { menuBar.setAuthenticating(false) }) { camera in
            CredentialSheet(camera: camera) { credentials in store.sessions[camera.id]?.start(camera: camera, credentials: credentials) }
        }
    }
}

struct MainCameraWindow: View {
    let store: CameraStore
    let windows: CameraWindows
    let lifecycle: CameraAppLifecycle
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        CameraBoard(store: store, windows: windows).frame(minWidth: 880, minHeight: 580)
            .onAppear {
                let action = openWindow
                lifecycle.configure(store: store, windows: windows, openMain: { action(id: "main") })
            }
    }
}

