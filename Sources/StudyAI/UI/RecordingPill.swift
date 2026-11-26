import AppKit
import StudyAICore
import SwiftUI

/// Píldora flotante de grabación, como en Wispr Flow: punto, tiempo y ondas.
/// Al pasar el ratón (o al pulsarla) se despliega con Pausar y Finalizar. Se arrastra a cualquier sitio, o se coloca
/// en una esquina con clic derecho, y recuerda dónde se dejó. Panel no activable: no quita el foco al vídeo.
///
/// El panel tiene tamaño fijo y transparente (los clics en lo transparente lo atraviesan): así el despliegue
/// se anima entero en SwiftUI, sin redimensionar la ventana a saltos.
@MainActor enum RecordingPill {
    static let panelSize = CGSize(width: 600, height: 80)
    private static var panel: NSPanel?
    private static var moveObserver: NSObjectProtocol?
    private static let originKey = "pillOrigin"
    private static let margin: CGFloat = 12
    static let layout = PillLayout()

    enum Spot: String, CaseIterable {
        case topLeft = "Arriba a la izquierda", top = "Arriba al centro", topRight = "Arriba a la derecha"
        case bottomLeft = "Abajo a la izquierda", bottom = "Abajo al centro", bottomRight = "Abajo a la derecha"
    }

    static func show(session: RecordingSession) {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = false // el arrastre lo lleva la propia píldora (drag)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // la sombra la dibuja SwiftUI: la del sistema no sigue a la cápsula al animarse
        p.contentView = NSHostingView(rootView: PillView(session: session, layout: layout))
        panel = p
        p.setFrameOrigin(savedOrigin() ?? origin(for: .bottom, on: NSScreen.main))
        updateLayout()
        p.orderFrontRegardless()
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { if dragStart == nil { moved() } }
        }
    }

    /// La píldora sin grabar, para proponer grabar una clase que acaba de empezar.
    static func showOffer(detector: ClassDetector) {
        guard let session = AppDelegate.session else { return }
        show(session: session)
    }

    static func hideOffer() {
        guard let session = AppDelegate.session, !session.isActive, session.finished == nil else { return }
        hide()
    }

    static func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        guard let p = panel else { return }
        panel = nil
        // Se desvanece en lugar de desaparecer de golpe.
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    private static var dragStart: (mouse: CGPoint, origin: CGPoint)?

    /// Arrastre con el ratón: la ventana sigue al puntero por toda la pantalla (o pantallas).
    static func drag(ended: Bool = false) {
        guard let panel else { return }
        if ended { dragStart = nil; moved(); return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let s = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
        updateLayout()
    }

    static func resetPosition() {
        UserDefaults.standard.removeObject(forKey: originKey)
        if let panel { panel.animator().setFrameOrigin(origin(for: .bottom, on: panel.screen ?? NSScreen.main)) }
    }

    static func place(_ spot: Spot) {
        guard let panel else { return }
        panel.animator().setFrameOrigin(origin(for: spot, on: panel.screen ?? NSScreen.main))
    }

    /// Tras arrastrarla: se mantiene dentro de la pantalla, se guarda, y la cápsula se alinea al lado donde quedó.
    private static func moved() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var o = panel.frame.origin
        o.x = min(max(o.x, v.minX - panelSize.width / 2 + 80), v.maxX - panelSize.width / 2 - 80)
        o.y = min(max(o.y, v.minY + margin - 20), v.maxY - panelSize.height - margin + 20)
        if o != panel.frame.origin { panel.setFrameOrigin(o) }
        UserDefaults.standard.set([o.x, o.y], forKey: originKey)
        updateLayout()
    }

    /// Cerca del borde izquierdo crece hacia la derecha y viceversa; en la mitad superior se pega arriba.
    private static func updateLayout() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let f = panel.frame
        let third = v.width / 3
        let h: HorizontalAlignment = f.midX < v.minX + third ? .leading : f.midX > v.maxX - third ? .trailing : .center
        let top = f.midY > v.midY
        if layout.horizontal != h { layout.horizontal = h }
        if layout.top != top { layout.top = top }
    }

    private static func origin(for spot: Spot, on screen: NSScreen?) -> CGPoint {
        let v = screen?.visibleFrame ?? .zero
        let w = panelSize.width, h = panelSize.height
        let x: CGFloat = switch spot {
        case .topLeft, .bottomLeft: v.minX + margin
        case .top, .bottom: v.midX - w / 2
        case .topRight, .bottomRight: v.maxX - w - margin
        }
        let y: CGFloat = switch spot {
        case .topLeft, .top, .topRight: v.maxY - h - margin + 14
        default: v.minY + margin - 14
        }
        return CGPoint(x: x, y: y)
    }

    /// La posición guardada, solo si sigue cayendo dentro de alguna pantalla (pudo desconectarse un monitor).
    private static func savedOrigin() -> CGPoint? {
        guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
        let center = CGPoint(x: a[0] + panelSize.width / 2, y: a[1] + panelSize.height / 2)
        return NSScreen.screens.contains { $0.frame.contains(center) } ? CGPoint(x: a[0], y: a[1]) : nil
    }
}

/// Hacia dónde se alinea la cápsula dentro del panel transparente.
@MainActor @Observable final class PillLayout {
    var horizontal: HorizontalAlignment = .center
    var top = false
}

private struct PillView: View {
    let session: RecordingSession
    let layout: PillLayout
    private let detector = ClassDetector.shared
    @State private var hover = false
    @State private var pinned = false
    @State private var appeared = false

    /// Desplegada al pasar el ratón, al pulsarla, o sola cuando hay algo que contar (pausa, sin sonido, error).
    private var expanded: Bool { hover || pinned || warning != nil }

    var body: some View {
        Group {
            if let done = session.finished, !session.isActive {
                savedPill(done)
            } else if !session.isActive, session.phase == .idle, let offer = detector.offer {
                offerPill(offer)
            } else {
                pill
            }
        }
            .scaleEffect(appeared ? (hover ? 1.03 : 1) : 0.4, anchor: layout.top ? .top : .bottom)
            .opacity(appeared ? 1 : 0)
            .blur(radius: appeared ? 0 : 6)
            .frame(width: RecordingPill.panelSize.width, height: RecordingPill.panelSize.height,
                   alignment: Alignment(horizontal: layout.horizontal, vertical: layout.top ? .top : .bottom))
            .padding(0)
            .animation(.spring(response: 0.38, dampingFraction: 0.78), value: expanded)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: session.finished != nil)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .animation(.spring(response: 0.45, dampingFraction: 0.75), value: layout.horizontal)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true } }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            statusDot
            Text(TimeFormat.clock(session.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            SpectrumBars(session: session, height: 16).frame(width: 36)
            if expanded {
                if let warning {
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(BlurReplaceTransition(configuration: .downUp).combined(with: MoveTransition(edge: .leading)))
                }
                controls.transition(BlurReplaceTransition(configuration: .downUp).combined(with: ScaleTransition(0.6, anchor: .leading)))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, expanded ? 6 : 14)
        .frame(height: 40)
        // Cristal azul medianoche, como el fondo del logo; siempre oscura para leerse sobre cualquier web.
        .background(Theme.night.opacity(0.9), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Theme.lavender.opacity(0.5), Theme.glow.opacity(0.15)],
                                                       startPoint: .top, endPoint: .bottom)))
        .shadow(color: Theme.violet.opacity(hover ? 0.55 : 0.3), radius: hover ? 16 : 10, y: 4)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture { pinned.toggle() }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in RecordingPill.drag() }
            .onEnded { _ in RecordingPill.drag(ended: true) })
        .contextMenu {
            ForEach(RecordingPill.Spot.allCases, id: \.self) { spot in
                Button(spot.rawValue) { RecordingPill.place(spot) }
            }
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(.vertical, 14) // aire para la sombra dentro del panel
        .padding(.horizontal, 20)
        .help("Arrástrala a cualquier sitio · clic derecho para colocarla en una esquina")
    }

    /// «¿Grabar esta clase?»: aparece sola al entrar en una reunión de Zoom o al poner un vídeo de clase.
    private func offerPill(_ offer: ClassDetector.Source) -> some View {
        HStack(spacing: 10) {
            Image(systemName: offer.kind == .zoom ? "video.fill" : "play.rectangle.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.lavender)
                .frame(width: 30, height: 30).background(.white.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(offer.kind == .zoom ? "Has entrado en una reunión de Zoom" : "Parece una clase en \(offer.app)")
                    .font(.system(size: 12, weight: .semibold))
                Text(offer.kind == .zoom ? "¿Grabar y transcribir esta clase?" : offer.title)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .foregroundStyle(.white)
            Button("Ahora no") { detector.dismiss() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
            Button { detector.accept() } label: {
                Label("Grabar", systemImage: "record.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.recording, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(height: 44)
        .background(Theme.night.opacity(0.92), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.lavender.opacity(0.4)))
        .shadow(color: Theme.violet.opacity(0.45), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in RecordingPill.drag() }
            .onEnded { _ in RecordingPill.drag(ended: true) })
        .transition(BlurReplaceTransition(configuration: .downUp))
    }

    /// Al finalizar: la cápsula se vuelve verde con un check y dice que la clase está a salvo.
    private func savedPill(_ lecture: Lecture) -> some View {
        let ok = lecture.status != .transcriptOnly
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white, ok ? Theme.successColor : .orange)
                .symbolEffect(.bounce, options: .nonRepeating, value: lecture.persistentModelID)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            VStack(alignment: .leading, spacing: 0) {
                Text("Clase guardada").font(.system(size: 13, weight: .semibold))
                Text(ok ? "\(TimeFormat.clock(lecture.duration)) · preparando el resumen" : "Sin voz: se guardó sin resumen")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(LinearGradient(colors: ok ? [Color(hex: 0x0E8F6A), Color(hex: 0x10B981)] : [Color(hex: 0x9A5B06), .orange],
                                   startPoint: .leading, endPoint: .trailing).opacity(0.95), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
        .shadow(color: (ok ? Theme.successColor : .orange).opacity(0.45), radius: 14, y: 4)
        .contentShape(Capsule())
        .onTapGesture { OpenLecture.post(lecture) }
        .fixedSize()
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .transition(BlurReplaceTransition(configuration: .downUp))
        .help("Abrir la clase")
    }

    private var warning: String? {
        switch session.phase {
        case .paused: return "En pausa"
        case .reconnecting: return "Recuperando el audio…"
        case .finishing: return "Terminando…"
        case .starting: return "Empezando…"
        case .failed(let msg): return msg
        default:
            if detector.sourceEnded { return "Parece que la clase ha terminado" }
            return session.silentFor > 60 ? "No llega sonido" : nil
        }
    }

    @ViewBuilder private var statusDot: some View {
        let color: Color = switch session.phase {
        case .recording: session.silentFor > 60 ? .orange : Theme.recording
        case .failed, .reconnecting: .orange
        default: .white.opacity(0.5)
        }
        // Sin parpadeo continuo: una animación infinita redibuja a 120 fps y era la mitad del consumo de la app.
        // Las ondas ya dicen que está grabando.
        Circle().fill(color).frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.8), radius: 4)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            switch session.phase {
            case .recording:
                pillButton("pause.fill", "Pausar") { session.pause() }
            case .paused:
                pillButton("play.fill", "Seguir") { session.resume() }
            case .failed:
                pillButton("arrow.clockwise", "Reintentar") { Task { await session.retry() } }
            default:
                EmptyView()
            }
            Button { Task { await session.finish() } } label: {
                Label("Finalizar", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .finishing)
        }
    }

    private func pillButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 28)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
