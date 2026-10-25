import Foundation

@main struct MenuBarSelectionTest {
    @MainActor static func main() throws {
        let suite = "REI-menu-selection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Camera(name: "First", host: "127.0.0.1")
        var second = Camera(name: "Second", host: "127.0.0.2")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "cameras")
        let store = CameraStore(defaults: defaults)
        guard store.menuBarCamera?.id == first.id else { print("FAIL: first camera must be initial preview"); exit(1) }
        store.selectMenuBarCamera(second.id)
        guard CameraStore(defaults: defaults).menuBarCamera?.id == second.id else { print("FAIL: preview selection was forgotten after relaunch"); exit(1) }
        let session = store.session(second)
        second.name = "Renamed second"
        store.save(second)
        guard store.menuBarCamera?.name == second.name, store.session(second) === session else { print("FAIL: rename lost selection or shared session"); exit(1) }
        store.selectMenuBarCamera(UUID())
        guard store.menuBarCamera?.id == second.id else { print("FAIL: invalid selection replaced the default"); exit(1) }
        // Only delete nonexistent, randomly generated fixture accounts; never load credentials.
        store.remove(second)
        guard store.menuBarCamera?.id == first.id else { print("FAIL: deleted preview did not fall back"); exit(1) }
        store.remove(first)
        guard store.menuBarCamera == nil, CameraStore(defaults: defaults).menuBarCamera == nil else { print("FAIL: empty library retained a missing preview"); exit(1) }
        print("PASS: persistent menu camera, rename/shared session, invalid selection, deletion fallback and empty library")
    }
}
