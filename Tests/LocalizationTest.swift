import Foundation
import AppKit
import ApplicationServices
import SwiftUI

@main
enum LocalizationTest {
    @MainActor static func main() {
        guard let index = CommandLine.arguments.firstIndex(of: "--expected-language"),
              CommandLine.arguments.indices.contains(index + 1) else {
            print("Usage: localization-tests --expected-language en|pt-BR [-AppleLanguages '(en)']")
            exit(1)
        }
        let expectedLanguage = CommandLine.arguments[index + 1]
        let portuguese = expectedLanguage == "pt-BR"
        var failures: [String] = []
        func check(_ actual: String, en: String, pt: String, _ label: String) {
            if actual != (portuguese ? pt : en) { failures.append("\(label): \(actual)") }
        }
        if Bundle.main.preferredLocalizations.first != expectedLanguage {
            failures.append("Native bundle language selection: \(Bundle.main.preferredLocalizations)")
        }
        check(CameraSession.State.stopped.label, en: "Disconnected", pt: "Desconectada", "Session state")
        check(CameraSession.State.connecting.label, en: "Connecting…", pt: "Conectando…", "Connection state")
        check(DecoderFailure.authentication.message,
              en: "The camera rejected RTSP login (401). Check the device's local username and password.",
              pt: "A câmera recusou o login RTSP (401). Confira usuário e senha locais do dispositivo.", "Safe diagnostic")
        check(CameraError.invalidEndpoint.localizedDescription,
              en: "Check the camera address, port, channel and username.",
              pt: "Confira endereço, porta, canal e usuário da câmera.", "Validation error")
        check(String(localized: "Your cameras"), en: "Your cameras", pt: "Suas câmeras", "Board title")
        check(String(localized: "Connect"), en: "Connect", pt: "Conectar", "Connection action")
        check(String(localized: "Back"), en: "Back", pt: "Voltar", "Cinema control")
        check(String(localized: "Double-click for cinema mode"),
              en: "Double-click for cinema mode", pt: "Duplo clique para modo cinema", "Tooltip")
        check(String(localized: "Preview camera"), en: "Preview camera", pt: "Câmera da prévia", "Menu camera selector")
        check(String(localized: "Use for menu bar preview"), en: "Use for menu bar preview", pt: "Usar na prévia da barra de menus", "Menu default action")
        check(String(localized: "Camera controls"), en: "Camera controls", pt: "Controles da câmera", "Native camera controls")
        check(String(localized: "Recordings"), en: "Recordings", pt: "Gravações", "Native recording history")
        check(String(localized: "Camera time"), en: "Camera time", pt: "Horário da câmera", "Recording wall-clock label")
        check(String(localized: "Image settings"), en: "Image settings", pt: "Ajustes de imagem", "Image settings title")
        let cameraName = "Entrada 100% %@ — 🚪"
        check(String(localized: "Connect to \(cameraName)"),
              en: "Connect to \(cameraName)", pt: "Conectar a \(cameraName)", "Interpolated camera name")
        check(String(localized: "Options for \(cameraName)"),
              en: "Options for \(cameraName)", pt: "Opções de \(cameraName)", "Accessibility label")
        let channel = 7
        check(String(localized: "Channel \(channel)"), en: "Channel 7", pt: "Canal 7", "Integer interpolation")
        let status = -50
        check(String(localized: "Could not save in macOS Keychain (\(status))."),
              en: "Could not save in macOS Keychain (-50).",
              pt: "Não foi possível salvar no Chaves do macOS (-50).", "Keychain diagnostic")
        let networkMessage = Bundle.main.localizedInfoDictionary?["NSLocalNetworkUsageDescription"] as? String ?? ""
        check(networkMessage,
              en: "Reversed engineering Icsee connects directly to cameras on your local network.",
              pt: "Reversed engineering Icsee conecta diretamente às suas câmeras na rede local.", "OS permission message")
        if CommandLine.arguments.contains("--render-ui") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let suite = "REI-localization-ui-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            let store = CameraStore(defaults: defaults)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 650),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Localization QA"
            window.contentView = NSHostingView(rootView: CameraBoard(store: store, windows: CameraWindows()))
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            var stack = [AXUIElementCreateApplication(getpid())]
            var labels = Set<String>()
            var count = 0
            while let node = stack.popLast(), count < 800 {
                count += 1
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
                       let text = value as? String { labels.insert(text) }
                }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { stack += children }
            }
            let expectedTitle = portuguese ? "Suas câmeras" : "Your cameras"
            let expectedButton = portuguese ? "Adicionar câmera" : "Add camera"
            if !labels.contains(expectedTitle) || !labels.contains(expectedButton) {
                failures.append("Rendered SwiftUI strings do not match \(expectedLanguage); nodes=\(count), labels=\(labels.sorted())")
            }
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS: native \(expectedLanguage) selection, UI strings, dynamic text, errors and OS permission message")
    }
}
