import AppKit
import Foundation

@MainActor
final class FullscreenCheck: NSObject, NSApplicationDelegate {
    var windows = CameraWindows()
    var fixtureStore: CameraStore?
    var suite = "CamMac-fullscreen-\(UUID())"
    func sendEscape(_ id: UUID) {
        let window = NSApp.windows.first { $0.identifier?.rawValue == "camera-\(id)" }!
        window.makeFirstResponder(window.contentView)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(event)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let defaults = UserDefaults(suiteName: suite)!
            let camera = Camera(name: "Teste de tela cheia", host: "127.0.0.1")
            defaults.set(try! JSONEncoder().encode([camera]), forKey: "cameras")
            let store = CameraStore(defaults: defaults)
            fixtureStore = store
            let session = store.session(camera)
            session.state = .live
            session.image = NSImage(size: NSSize(width: 640, height: 960))
            windows.open(camera: camera, store: store, fullscreen: true)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                if windows.fullscreenIDs.contains(camera.id) { break }
            }
            guard windows.fullscreenIDs.contains(camera.id) else {
                print("FAIL: native fullscreen did not enter")
                windows.closeAll(); defaults.removePersistentDomain(forName: suite); exit(1)
            }
            sendEscape(camera.id)
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                if !windows.fullscreenIDs.contains(camera.id) { break }
            }
            let popup = NSApp.windows.first { $0.identifier?.rawValue == "camera-\(camera.id)" }
            guard !windows.fullscreenIDs.contains(camera.id), popup?.level == .floating, session.state == .live else {
                print("FAIL: fullscreen exit did not restore floating shared view")
                windows.closeAll(); defaults.removePersistentDomain(forName: suite); exit(1)
            }
            popup?.close()
            guard popup?.isVisible == false, session.state == .live else {
                print("FAIL: closing popup changed stream state")
                defaults.removePersistentDomain(forName: suite); exit(1)
            }
            defaults.removePersistentDomain(forName: suite)
            print("PASS: native fullscreen entry, Escape exit, floating restoration, shared stream")
            NSApp.terminate(nil)
        }
    }
}

@main
struct FullscreenCheckMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FullscreenCheck()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
