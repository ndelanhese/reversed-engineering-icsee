import SwiftUI
import AppKit

// Select the property wrapper without the SDK's separate State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CameraVideo: View {
    @Bindable var session: CameraSession
    var profile: CameraRenderProfile = .window
    var body: some View {
        ZStack {
            Color.black
            if let image = session.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 12) {
                    if session.state == .connecting { ProgressView().tint(.white) }
                    else { Image(systemName: "video").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.5)) }
                    if case .failed(let message) = session.state {
                        Text(message).font(.callout).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(.horizontal)
                    } else { Text(session.state.label).foregroundStyle(.white.opacity(0.6)) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .background(CameraVideoVisibility(session: session, profile: profile))
    }
}

private struct CameraVideoVisibility: NSViewRepresentable {
    let session: CameraSession
    let profile: CameraRenderProfile
    func makeNSView(context: Context) -> CameraVisibilityView { CameraVisibilityView() }
    func updateNSView(_ view: CameraVisibilityView, context: Context) { view.configure(session, profile: profile) }
    static func dismantleNSView(_ view: CameraVisibilityView, coordinator: ()) { view.detach() }
}

@MainActor final class CameraVisibilityView: NSView {
    private let viewerID = UUID()
    private weak var session: CameraSession?
    private var profile = CameraRenderProfile.window
    private var sleeping = false
    func configure(_ session: CameraSession, profile: CameraRenderProfile) {
        if self.session !== session { self.session?.updateViewer(viewerID, profile: nil) }
        self.session = session
        self.profile = profile
        updateVisibility()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(powerChanged(_:)), name: name, object: nil)
            }
        }
        updateVisibility()
    }
    @objc private func windowChanged(_ note: Notification) {
        if note.name == NSWindow.willCloseNotification { session?.updateViewer(viewerID, profile: nil) }
        else { updateVisibility() }
    }
    @objc private func powerChanged(_ note: Notification) {
        sleeping = note.name == NSWorkspace.willSleepNotification
        updateVisibility()
    }
    private func updateVisibility() {
        let visible = !sleeping && !NSApp.isHidden && window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
        session?.updateViewer(viewerID, profile: visible ? profile : nil)
    }
    func detach() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        session?.updateViewer(viewerID, profile: nil)
        session = nil
    }
}

struct CameraStage: View {
    let camera: Camera
    @Bindable var session: CameraSession
    var back: (() -> Void)? = nil
    var popup: (() -> Void)? = nil
    var fullscreen: () -> Void
    var isFullscreen = false
    var connect: () -> Void
    var controls: (() -> Void)? = nil
    var recordings: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if let back {
                    Button(action: back) { Label("Back", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                }
                Text(camera.name).font(.headline).lineLimit(1)
                if session.state == .live {
                    Label("Live", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                if let recordings {
                    Button(action: recordings) { Image(systemName: "clock.arrow.circlepath") }
                        .help("Recordings").accessibilityLabel("Recordings")
                }
                if let controls {
                    Button(action: controls) { Image(systemName: "slider.horizontal.3") }
                        .help("Camera controls").accessibilityLabel("Camera controls")
                }
                if session.state == .live || session.state == .connecting {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                } else { Button("Connect", action: connect) }
                if let popup {
                    Button(action: popup) { Image(systemName: "rectangle.on.rectangle") }
                        .help("Open floating window").accessibilityLabel("Open window")
                }
                Button(action: fullscreen) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isFullscreen ? String(localized: "Exit full screen") : String(localized: "Full screen"))
                .accessibilityLabel(isFullscreen ? String(localized: "Exit full screen") : String(localized: "Full screen"))
            }
            .buttonStyle(.borderless).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12).background(Color(white: 0.08))
            CameraVideo(session: session)
        }.background(.black)
    }
}
