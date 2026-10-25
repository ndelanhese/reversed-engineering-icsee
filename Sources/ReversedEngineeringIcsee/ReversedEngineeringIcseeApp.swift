import SwiftUI
import AppKit

@main
struct ReversedEngineeringIcseeApp: App {
    @NSApplicationDelegateAdaptor(CameraAppLifecycle.self) private var lifecycle
    @ViewState private var store = CameraStore()
    @ViewState private var windows = CameraWindows()
    var body: some Scene {
        Window("Reversed engineering Icsee", id: "main") {
            MainCameraWindow(store: store, windows: windows, lifecycle: lifecycle)
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .windowArrangement) {
                Button("Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}
