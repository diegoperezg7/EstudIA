import AppKit
import StudyAICore
import SwiftData
import SwiftUI

/// Dónde se ve que está grabando: la píldora flotante, el reloj en la barra de menús, o las dos (Configuración).
/// El icono de EstudIA en la barra de menús está siempre; la preferencia decide si muestra el reloj al grabar.
@MainActor enum RecordingIndicators {
    private static weak var session: RecordingSession?

    static func show(session: RecordingSession) {
        self.session = session
        apply()
    }

    /// Al finalizar, la píldora enseña «Clase guardada» un momento antes de irse.
    static func finished() {
        session = nil
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if !(AppDelegate.session?.isActive ?? false) { RecordingPill.hide() }
        }
    }

    static func hide() {
        session = nil
        RecordingPill.hide()
    }

    /// Aplica la preferencia; también si se cambia en Configuración a mitad de grabación.
    static func apply() {
        guard let session, session.isActive else { return }
        if Prefs.indicator.pill { RecordingPill.show(session: session) } else { RecordingPill.hide() }
    }
}

/// Pide a la ventana principal que enseñe los Ajustes, dentro de la propia ventana.
enum ShowSettings {
    static let notification = Notification.Name("EstudIA.showSettings")
    @MainActor static func post() {
        NSApp.activate()
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// Pide a la ventana principal que abra una clase (desde la barra de menús o la píldora).
enum OpenLecture {
    static let notification = Notification.Name("EstudIA.openLecture")
    @MainActor static func post(_ lecture: Lecture?) {
        NSApp.activate()
        NotificationCenter.default.post(name: notification, object: lecture)
    }
}

/// Ondas que siguen al sonido: cada barra es una banda del espectro (graves en el centro, agudos a los lados).
/// Se refresca a 30 fps solo mientras graba; en pausa o en silencio quedan quietas y planas.
struct SpectrumBars: View {
    let session: RecordingSession
    var height: CGFloat = 16
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var colors: [Color] = [Theme.glow, Theme.lavender]

    /// Orden de dibujo de las 7 bandas: la voz (bandas bajas) en el centro.
    private static let order = [5, 3, 1, 0, 2, 4, 6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: session.phase != .recording)) { _ in
            let bands = session.spectrum()
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Self.order, id: \.self) { b in
                    let v = CGFloat(bands[safe: b] ?? 0)
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
                        .frame(width: barWidth, height: max(barWidth, height * v))
                }
            }
            .frame(height: height)
        }
    }
}

/// Icono de la barra de menús: el logo y, al grabar, un punto rojo con el tiempo.
struct MenuBarLabel: View {
    let session: RecordingSession

    var body: some View {
        if session.isActive && Prefs.indicator.menuBar {
            let paused = session.phase == .paused
            Image(nsImage: Self.dot(paused ? .systemOrange : .systemRed))
            Text(TimeFormat.clock(session.elapsed)).monospacedDigit()
        } else {
            Image(nsImage: Self.logo)
        }
    }

    /// El logo como glifo de plantilla (auriculares con un libro), sin fondo: macOS lo pinta en blanco o negro
    /// según la barra, como el resto de iconos de arriba.
    static let logo: NSImage = {
        let size: CGFloat = 22
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let phones = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.78, weight: .semibold))
            let book = NSImage(systemSymbolName: "book.pages.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.30, weight: .bold))
            if let phones {
                let s = phones.size
                phones.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.04, width: s.width, height: s.height))
            }
            if let book {
                let s = book.size
                book.draw(in: NSRect(x: (size - s.width) / 2, y: size * 0.16, width: s.width, height: s.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "EstudIA"
        return image
    }()

    static func dot(_ color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white, color]))
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Grabando")?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }
}

/// Panel de la barra de menús: grabar, pausar o finalizar, ver lo que se está transcribiendo y abrir las últimas clases.
struct MenuBarPanel: View {
    @Environment(RecordingSession.self) private var session
    @Environment(LectureProcessor.self) private var processor
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.languageKey) private var language: ClassLanguage = .spanish
    @Query(sort: \Lecture.createdAt, order: .reverse) private var lectures: [Lecture]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if session.isActive || session.phase == .starting {
                recordingCard
            } else if let done = session.finished {
                FinishedCard(lecture: done) { open(done) }
            } else {
                Button { Task { await session.start(subject: nil, language: language) } } label: {
                    Label("Grabar clase", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentButtonStyle())
                if let problem = session.startProblem {
                    Text(problem.message).font(.caption).foregroundStyle(.orange)
                }
            }
            recent
            Divider()
            HStack(spacing: 6) {
                footerButton("Abrir EstudIA", "macwindow") { open(nil) }
                footerButton("Ajustes", "gearshape") { openWindow(id: "main"); ShowSettings.post() }
                Spacer()
                footerButton("Salir", "power") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Theme.canvas)
        .tint(Theme.ink)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("EstudIA").font(.system(size: 15, weight: .bold))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Flag(language: language, height: 12).help("Idioma de las clases: \(language.name)")
        }
    }

    private var statusText: String {
        switch session.phase {
        case .recording: session.silentFor > 60 ? "Grabando, pero no llega sonido" : "Grabando la clase"
        case .paused: "En pausa"
        case .starting: "Empezando…"
        case .reconnecting: "Recuperando el audio…"
        case .finishing: "Guardando…"
        case .failed(let m): m
        case .idle: session.finished != nil ? "Clase guardada" : "Lista para grabar"
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Spacer()
                SpectrumBars(session: session, height: 30, barWidth: 4, spacing: 3, colors: [Theme.indigo, Theme.glow])
            }
            Text(session.liveText.isEmpty ? "Escuchando…" : session.liveText)
                .font(.callout).foregroundStyle(.secondary).italic()
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 8) {
                switch session.phase {
                case .recording:
                    Button { session.pause() } label: { Label("Pausar", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                case .paused:
                    Button { session.resume() } label: { Label("Seguir", systemImage: "play.fill").frame(maxWidth: .infinity) }
                case .failed:
                    Button { Task { await session.retry() } } label: { Label("Reintentar", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                default:
                    EmptyView()
                }
                Button { Task { await session.finish() } } label: {
                    Label("Finalizar", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(session.phase == .finishing || session.phase == .starting)
            }
            .controlSize(.large)
        }
        .padding(14)
        .card()
    }

    @ViewBuilder private var recent: some View {
        let list = lectures.filter { $0 != session.lecture }.prefix(3)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Últimas clases").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(list)) { l in
                    Button { open(l) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: processor.progress[l.persistentModelID] != nil ? "sparkles" : "text.book.closed")
                                .foregroundStyle(Theme.ink).frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(l.displayTitle).lineLimit(1)
                                Text(processor.progress[l.persistentModelID].map { $0.step } ?? l.createdAt.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func footerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.callout) }
            .buttonStyle(.borderless)
    }

    private func open(_ lecture: Lecture?) {
        openWindow(id: "main")
        OpenLecture.post(lecture)
    }
}

/// «Clase guardada»: un check que se dibuja y lo que pasa ahora con la clase.
struct FinishedCard: View {
    let lecture: Lecture
    var onOpen: () -> Void = {}
    @State private var shown = false

    var body: some View {
        let ok = lecture.status != .transcriptOnly
        HStack(spacing: 12) {
            ZStack {
                Circle().fill((ok ? Theme.successColor : Color.orange).opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(ok ? Theme.successColor : .orange)
                    .symbolEffect(.bounce, value: shown)
                    .scaleEffect(shown ? 1 : 0.2)
                    .opacity(shown ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Clase guardada").font(.headline)
                Text(ok ? "\(TimeFormat.clock(lecture.duration)) grabados. Escribiendo el resumen y los apuntes…"
                        : lecture.processingError ?? "Se guardó sin resumen.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Ver", action: onOpen)
        }
        .padding(14)
        .card()
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.1)) { shown = true } }
    }
}
