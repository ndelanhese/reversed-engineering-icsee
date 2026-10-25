import SwiftUI
import AppKit

@MainActor
final class CameraAppLifecycle: NSObject, NSApplicationDelegate {
    var store: CameraStore?
    var windows: CameraWindows?
    func applicationWillTerminate(_ notification: Notification) { windows?.closeAll(); store?.stopAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ReversedEngineeringIcseeApp: App {
    @NSApplicationDelegateAdaptor(CameraAppLifecycle.self) private var lifecycle
    @ViewState private var store = CameraStore()
    @ViewState private var windows = CameraWindows()
    var body: some Scene {
        Window("Reversed engineering Icsee", id: "main") {
            CameraBoard(store: store, windows: windows).frame(minWidth: 880, minHeight: 580)
                .onAppear { lifecycle.store = store; lifecycle.windows = windows }
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
