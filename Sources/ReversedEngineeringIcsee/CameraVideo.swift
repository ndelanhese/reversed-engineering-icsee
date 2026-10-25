import SwiftUI
import AppKit

// Select the property wrapper without the SDK's separate State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

struct CameraVideo: View {
    @Bindable var session: CameraSession
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
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if let back {
                    Button(action: back) { Label("Voltar", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                }
                Text(camera.name).font(.headline).lineLimit(1)
                if session.state == .live {
                    Label("Ao vivo", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                if session.state == .live || session.state == .connecting {
                    Button("Parar", systemImage: "stop.fill") { session.stop() }
                } else { Button("Conectar", action: connect) }
                if let popup {
                    Button(action: popup) { Image(systemName: "rectangle.on.rectangle") }
                        .help("Abrir popup flutuante").accessibilityLabel("Abrir popup")
                }
                Button(action: fullscreen) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isFullscreen ? "Sair da tela cheia" : "Tela cheia")
                .accessibilityLabel(isFullscreen ? "Sair da tela cheia" : "Tela cheia")
            }
            .buttonStyle(.borderless).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12).background(Color(white: 0.08))
            CameraVideo(session: session)
        }.background(.black)
    }
}
