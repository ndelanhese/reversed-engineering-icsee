import AppKit
import Foundation
import Darwin
import SwiftUI

@MainActor private final class EnergyCheck: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let camera = Camera(name: "Synthetic live video", host: "127.0.0.1", port: Int(CommandLine.arguments[1])!)
            let suite = "REI-energy-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(try! JSONEncoder().encode([camera]), forKey: "cameras")
            let store = CameraStore(defaults: defaults)
            let session = store.session(camera)
            let credentials = Credentials(username: "fixture", password: "fixture")
            let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            // Keep the fixture visible while the test runner is active in another app.
            main.level = .floating
            main.collectionBehavior = [.canJoinAllSpaces]
            main.isReleasedWhenClosed = false
            main.contentView = NSHostingView(rootView: CameraVideo(session: session))
            main.center()
            main.makeKeyAndOrderFront(nil)
            NSApp.activate()
            session.start(camera: camera, credentials: credentials)
            @MainActor func wait(_ condition: @MainActor () -> Bool, _ message: String) async {
                for _ in 0..<200 {
                    if condition() { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print("FAIL: \(message); state=\(session.state.label)")
                session.stop()
                exit(1)
            }
            await wait({ session.state == .live && session.image?.size.width == 1280 }, "visible window did not decode synthetic RTSP")
            let preview = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 240, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            preview.level = .floating
            preview.collectionBehavior = [.canJoinAllSpaces]
            preview.isReleasedWhenClosed = false
            preview.contentView = NSHostingView(rootView: CameraVideo(session: session, profile: .preview))
            preview.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            guard session.image?.size.width == 1280 else { print("FAIL: preview downgraded an existing full-size viewer"); exit(1) }
            main.close()
            await wait({ session.state == .live && session.image?.size.width == 480 }, "preview-only did not reduce output size")
            // Fill the live stdout pipe before cancellation to exercise blocked muxer shutdown.
            usleep(2_000_000)
            preview.close()
            await wait({ session.state == .suspended && session.image == nil }, "closed viewers kept decoding")
            await wait({ decoderCount() == 0 }, "suspend left a decoder process behind")
            guard session.credentialsForControls()?.username == "fixture" else { print("FAIL: suspend lost authentication"); exit(1) }
            main.contentView = NSHostingView(rootView: CameraVideo(session: session, profile: .grid))
            main.makeKeyAndOrderFront(nil)
            await wait({ session.state == .live && session.image?.size.width == 800 }, "grid did not resume at reduced size")
            let beforeFrames = session.frames
            try? await Task.sleep(for: .seconds(2))
            guard (7...13).contains(session.frames - beforeFrames) else { print("FAIL: grid did not cap rendered frame rate"); exit(1) }
            main.contentView = NSHostingView(rootView: CameraVideo(session: session))
            await wait({ session.state == .live && session.image?.size.width == 1280 }, "enlarged view did not restore full size")
            main.miniaturize(nil)
            await wait({ session.state == .suspended }, "minimizing kept decoding")
            main.deminiaturize(nil)
            main.makeKeyAndOrderFront(nil)
            await wait({ session.state == .live }, "restore did not resume")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            await wait({ session.state == .suspended }, "sleep kept decoding")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            await wait({ session.state == .live }, "wake did not resume visible viewer")
            main.close()
            await wait({ session.state == .suspended }, "closing main before preview did not suspend")
            preview.makeKeyAndOrderFront(nil)
            await wait({ session.state == .live && session.image?.size.width == 480 }, "preview did not resume at reduced size")
            var alternate = camera
            alternate.id = UUID()
            alternate.name = "Alternate synthetic camera"
            let alternateSession = CameraSession()
            alternateSession.start(camera: alternate, credentials: credentials)
            preview.contentView = NSHostingView(rootView: CameraVideo(session: alternateSession, profile: .preview))
            await wait({ session.state == .suspended && alternateSession.state == .live }, "preview selection left old camera decoding")
            preview.close()
            await wait({ alternateSession.state == .suspended }, "dismissed preview kept decoding")
            alternateSession.stop()
            session.stop()
            main.close()
            main.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            guard session.state == .stopped && session.credentialsForControls() == nil else { print("FAIL: reopening restarted an explicitly stopped camera"); exit(1) }
            main.close()
            print("PASS: real RTSP frames, shared grid/window/preview sizing and FPS, close/suspend/reopen, minimize/restore, sleep/wake, preview selection/dismiss, explicit Stop")
            NSApp.terminate(nil)
        }
    }
}

private func decoderCount() -> Int {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "ppid=,comm="]
    process.standardOutput = pipe
    try! process.run()
    let rows = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let owner = String(ProcessInfo.processInfo.processIdentifier)
    return rows.split(separator: "\n").filter {
        let parts = $0.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        return parts.count == 2 && parts[0] == owner && parts[1].hasSuffix("/ffmpeg")
    }.count
}

@main struct CameraEnergyWindowTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = EnergyCheck()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
