import AppKit
import Foundation

@main
struct CameraWindowsTest {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let suite = "CamMac-window-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard CameraStore(defaults: defaults).cameras.isEmpty else {
            print("FAIL: new installations must not contain personal camera profiles")
            exit(1)
        }
        let camera = Camera(name: "Janela de teste", host: "127.0.0.1")
        defaults.set(try JSONEncoder().encode([camera]), forKey: "cameras")
        let store = CameraStore(defaults: defaults)
        guard store.cameras == [camera] else {
            print("FAIL: existing camera profiles must survive startup")
            exit(1)
        }
        let session = store.session(camera)
        session.state = .live
        session.image = NSImage(size: NSSize(width: 16, height: 16))
        let windows = CameraWindows()
        windows.open(camera: camera, store: store)
        let identifier = NSUserInterfaceItemIdentifier("camera-\(camera.id)")
        guard let first = NSApp.windows.first(where: { $0.identifier == identifier }) else {
            print("FAIL: popup was not created")
            exit(1)
        }
        guard first.level == .floating, first.styleMask.contains(.resizable) else {
            print("FAIL: popup must float and resize")
            exit(1)
        }
        windows.open(camera: camera, store: store)
        guard NSApp.windows.filter({ $0.identifier == identifier && $0.isVisible }).count == 1 else {
            print("FAIL: repeated open created duplicate camera windows")
            exit(1)
        }
        first.close()
        guard session.state == .live, session.image != nil else {
            print("FAIL: closing popup interrupted the shared stream")
            exit(1)
        }
        windows.open(camera: camera, store: store)
        guard NSApp.windows.contains(where: { $0.identifier == identifier && $0 !== first && $0.isVisible }) else {
            print("FAIL: closed popup did not reopen")
            exit(1)
        }
        windows.closeAll()
        guard !NSApp.windows.contains(where: { $0.identifier == identifier && $0.isVisible }), session.state == .live else {
            print("FAIL: viewer cleanup changed the stream or left a window open")
            exit(1)
        }
        print("PASS: resizable floating popup, window reuse, reopen, shared stream lifetime")
    }
}
