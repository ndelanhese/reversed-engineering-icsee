import AppKit
import Foundation

@MainActor final class MenuBarCheck: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let suite = "REI-menu-native-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let camera = Camera(name: "Synthetic menu preview", host: "127.0.0.1")
            defaults.set(try! JSONEncoder().encode([camera]), forKey: "cameras")
            let store = CameraStore(defaults: defaults)
            let session = store.session(camera)
            session.state = .live
            session.image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
                NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.35, alpha: 1).setFill()
                rect.fill()
                let title = "Synthetic camera preview" as NSString
                title.draw(at: NSPoint(x: 140, y: 170), withAttributes: [.font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.white])
                return true
            }
            let lifecycle = CameraAppLifecycle()
            var openedMain = false
            lifecycle.configure(store: store, windows: CameraWindows(), openMain: { openedMain = true })
            let menu = lifecycle.menuBar!
            @MainActor func check(_ value: Bool, _ message: String) {
                if !value { menu.uninstall(); defaults.removePersistentDomain(forName: suite); print("FAIL: \(message)"); exit(1) }
            }
            check(!lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApp), "closing last window would quit the menu app")
            menu.install()
            let item = menu.statusItem
            menu.install()
            check(menu.statusItem === item && item?.button?.image?.isTemplate == true, "menu item duplicated or missing native icon")
            menu.pointerEnteredStatusItem()
            menu.pointerExitedStatusItem()
            try? await Task.sleep(for: .milliseconds(400))
            check(!menu.isShown, "brief pointer crossing opened preview")
            menu.pointerEnteredStatusItem()
            try? await Task.sleep(for: .milliseconds(400))
            check(menu.isShown, "hover did not open native preview")
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1),
               let window = NSApp.windows.first(where: { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") }),
               let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            }

            menu.pointerExitedStatusItem()
            menu.pointerEnteredPreview()
            try? await Task.sleep(for: .milliseconds(400))
            check(menu.isShown, "preview closed while pointer entered content")
            menu.pointerExitedPreview()
            try? await Task.sleep(for: .milliseconds(500))
            check(!menu.isShown && session.state == .live && store.session(camera) === session, "hover exit interrupted shared video")
            item?.button?.performClick(nil)
            menu.pointerExitedStatusItem()
            menu.pointerExitedPreview()
            try? await Task.sleep(for: .milliseconds(500))
            check(menu.isShown, "click did not pin preview")
            item?.button?.performClick(nil)
            check(!menu.isShown, "second click did not close preview")
            item?.button?.performClick(nil)
            menu.openMainWindow()
            check(openedMain && !menu.isShown, "Open app did not route to the main scene")
            menu.pointerEnteredStatusItem()
            menu.uninstall()
            try? await Task.sleep(for: .milliseconds(400))
            check(!menu.isShown && menu.statusItem == nil && session.state == .live, "cleanup left item/timer or stopped shared stream")
            lifecycle.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            check(session.state == .stopped, "Quit did not stop shared streams")
            defaults.removePersistentDomain(forName: suite)
            print("PASS: native menu icon, hover cancellation/handoff/dismissal, click pinning, cleanup and shared stream")
            NSApp.terminate(nil)
        }
    }
}
@main struct MenuBarPreviewTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarCheck()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
