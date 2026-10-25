import AppKit
import SwiftUI

@MainActor private final class SceneFixture {
    let suite = "REI-menu-scene-\(UUID())"
    let defaults: UserDefaults
    let store: CameraStore
    let windows = CameraWindows()
    var started = false
    init() {
        defaults = UserDefaults(suiteName: suite)!
        store = CameraStore(defaults: defaults)
        let camera = Camera(name: "Synthetic background camera", host: "127.0.0.1")
        store.save(camera)
        store.session(camera).state = .live
    }
    func run(_ lifecycle: CameraAppLifecycle) async {
        guard !started else { return }
        started = true
        try? await Task.sleep(for: .milliseconds(400))
        guard let first = NSApp.windows.first(where: { $0.title == "Menu bar scene QA" && $0.isVisible }), let menu = lifecycle.menuBar else { fail("main scene/menu did not appear", lifecycle) }
        let session = store.session(store.cameras[0])
        first.close()
        try? await Task.sleep(for: .milliseconds(400))
        guard !first.isVisible, menu.statusItem != nil, session.state == .live else { fail("closing main scene lost background menu/stream", lifecycle) }
        menu.openMainWindow()
        try? await Task.sleep(for: .milliseconds(600))
        guard NSApp.windows.contains(where: { $0.title == "Menu bar scene QA" && $0.isVisible }), lifecycle.menuBar === menu, session.state == .live else { fail("Open app did not reopen real SwiftUI main scene", lifecycle) }
        defaults.removePersistentDomain(forName: suite)
        print("PASS: production main-window integration stays in menu bar and reopens its SwiftUI scene")
        NSApp.terminate(nil)
    }
    private func fail(_ message: String, _ lifecycle: CameraAppLifecycle) -> Never {
        lifecycle.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        defaults.removePersistentDomain(forName: suite)
        print("FAIL: \(message)")
        exit(1)
    }
}

@main @MainActor struct MenuBarSceneTest: App {
    @NSApplicationDelegateAdaptor(CameraAppLifecycle.self) private var lifecycle
    @ViewState private var fixture = SceneFixture()
    var body: some Scene {
        Window("Menu bar scene QA", id: "main") {
            MainCameraWindow(store: fixture.store, windows: fixture.windows, lifecycle: lifecycle)
                .task { await fixture.run(lifecycle) }
        }
    }
}
