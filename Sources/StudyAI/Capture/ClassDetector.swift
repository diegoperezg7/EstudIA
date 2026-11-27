import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import StudyAICore

/// Avisa cuando empieza una clase: una reunión de Zoom o un vídeo de clase sonando en el navegador.
/// Mira cada 4 s los títulos de las ventanas (los deja leer el permiso de grabación de pantalla que ya tiene la app)
/// y qué apps están sacando sonido (CoreAudio, sin permisos). Nunca graba sola: solo propone en la píldora.
@MainActor @Observable final class ClassDetector {
    /// Dónde se dan o se ven clases online: decide el logo de la píldora y qué pestañas se ofrecen sin palabra clave.
    enum Platform: String, CaseIterable {
        case meet, teams, zoom, webex, classroom, youtube, moodle

        var name: String {
            switch self {
            case .meet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .zoom: "Zoom"
            case .webex: "Webex"
            case .classroom: "Google Classroom"
            case .youtube: "YouTube"
            case .moodle: "Moodle"
            }
        }
        var logo: String {
            switch self {
            case .meet: "LogoGoogleMeet"
            case .teams: "LogoMicrosoftTeams"
            case .zoom: "LogoZoom"
            case .webex: "LogoWebex"
            case .classroom: "LogoGoogleClassroom"
            case .youtube: "LogoYouTube"
            case .moodle: "LogoMoodle"
            }
        }
        /// Una videollamada o un aula con sonido se ofrece siempre; en YouTube o Moodle hace falta una palabra clave.
        var isLive: Bool { ![.youtube, .moodle].contains(self) }

        /// Por el título de la pestaña: «Meet - abc-defg-hij», «Tema 3 - YouTube», «Reunión | Microsoft Teams».
        nonisolated static func detect(_ lowerTitle: String) -> Platform? {
            if lowerTitle.hasPrefix("meet - ") || lowerTitle.contains("google meet")
                || lowerTitle.range(of: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, options: .regularExpression) != nil { return .meet }
            let marks: [(String, Platform)] = [("microsoft teams", .teams), ("webex", .webex), ("zoom", .zoom),
                                                ("classroom", .classroom), ("youtube", .youtube), ("moodle", .moodle)]
            return marks.first { lowerTitle.contains($0.0) }?.1
        }
    }

    struct Source: Equatable {
        /// zoom: ventana de reunión de Zoom. browser: pestaña que suena. app: Teams o Webex de escritorio sonando.
        enum Kind { case zoom, browser, app }
        var kind: Kind
        var app: String
        var title: String
        /// Identifica la ventana para no volver a preguntar mientras siga abierta tras «Ahora no».
        var key: String
        /// Para enseñar el icono de la app en la píldora.
        var bundleID: String?
        /// Plataforma reconocida en el navegador: su logo va antes que el del navegador.
        var platform: Platform?
        /// Apps de escritorio: prefijo del bundle que suena, para saber si la llamada sigue.
        var audioPrefix: String?

        var displayName: String { platform?.name ?? app }
    }

    static let shared = ClassDetector()
    nonisolated static let enabledKey = "detectClasses", keywordsKey = "classKeywords"
    nonisolated static let defaultKeywords = "UNIR, Campus, Clase, Lección, Tema, Collaborate, Kaltura"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    nonisolated static var keywords: [String] {
        (UserDefaults.standard.string(forKey: keywordsKey) ?? defaultKeywords)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// La clase que se propone grabar ahora mismo (la píldora la enseña). nil = nada que ofrecer.
    private(set) var offer: Source?
    /// Durante una grabación: la fuente desapareció (terminó la reunión o se cerró la pestaña).
    private(set) var sourceEnded = false

    @ObservationIgnored private weak var session: RecordingSession?
    /// «Ahora no» y clases ya grabadas: clave → última vez que se vio la ventana. Caduca a los 10 min sin verla,
    /// no al dejar de sonar (una pausa o un anuncio no deben volver a preguntar).
    @ObservationIgnored private var dismissed: [String: Date] = [:]
    @ObservationIgnored private var recordingSource: Source?
    @ObservationIgnored private var wasRecording = false
    /// Comprobaciones seguidas sin rastro de la fuente que se graba (para no avisar por un corte de un momento).
    @ObservationIgnored private var missingTicks = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAppKeys: Set<String> = []

    func start(session: RecordingSession) {
        self.session = session
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { ClassDetector.shared.tick() }
        }
    }

    /// «Grabar» desde la píldora.
    func accept() {
        guard let offer, let session else { return }
        recordingSource = offer
        self.offer = nil
        RecordingPill.hideOffer()
        Task {
            await session.start(subject: nil, language: ClassLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.languageKey) ?? "") ?? .spanish,
                                hint: offer.title)
            if !session.isActive { recordingSource = nil }
        }
    }

    /// «Ahora no»: no vuelve a preguntar por esa ventana mientras siga abierta.
    func dismiss() {
        if let offer { dismissed[offer.key] = .now }
        offer = nil
        RecordingPill.hideOffer()
    }

    private func clearOffer() {
        guard offer != nil else { return }
        offer = nil
        RecordingPill.hideOffer()
    }

    private func tick() {
        guard let session else { return }
        let snap = Self.snapshot()
        let now = Date.now
        for key in snap.openKeys.union(snap.candidates.map(\.key)) where dismissed[key] != nil { dismissed[key] = now }
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) < 600 }

        if session.isActive || session.phase == .starting {
            wasRecording = true
            clearOffer()
            if let rec = recordingSource {
                let present: Bool = switch rec.kind {
                case .zoom: snap.zoomMeeting || snap.playing.contains { $0.hasPrefix("us.zoom") }
                // Cambiar de pestaña cambia el título, pero el navegador sigue sonando: solo se da por acabada
                // si la ventana ya no está y el navegador lleva un rato callado.
                case .browser: snap.openKeys.contains(rec.key)
                    || Self.browsers[rec.app].map { prefix in snap.playing.contains { $0.hasPrefix(prefix) } } ?? false
                case .app: rec.audioPrefix.map { prefix in snap.playing.contains { $0.hasPrefix(prefix) } } ?? false
                }
                missingTicks = present ? 0 : missingTicks + 1
                let gone = missingTicks >= (rec.kind == .zoom ? 2 : 8)
                if gone != sourceEnded { sourceEnded = gone }
            }
            return
        }
        if wasRecording {
            // Recién finalizada: la clase que seguía abierta ya está grabada, no se vuelve a proponer.
            wasRecording = false
            for source in snap.candidates { dismissed[source.key] = now }
        }
        recordingSource = nil
        missingTicks = 0
        if sourceEnded { sourceEnded = false }
        guard Self.enabled else { clearOffer(); return }
        guard session.finished == nil else { return }

        // Teams o Webex de escritorio solo cuentan si siguen sonando en la siguiente comprobación: un aviso
        // de mensaje nuevo dura un segundo, una llamada no.
        let seenBefore = lastAppKeys
        lastAppKeys = Set(snap.candidates.filter { $0.kind == .app }.map(\.key))
        let candidate = snap.candidates.first { dismissed[$0.key] == nil && ($0.kind != .app || seenBefore.contains($0.key)) }
        if candidate != offer {
            offer = candidate
            if candidate != nil { RecordingPill.showOffer(detector: self) } else { RecordingPill.hideOffer() }
        }
    }

    // MARK: Qué hay abierto

    nonisolated private static let browsers = [
        "Safari": "com.apple.WebKit", "Google Chrome": "com.google.Chrome", "Microsoft Edge": "com.microsoft.edgemac",
        "Arc": "company.thebrowser", "Firefox": "org.mozilla.firefox", "Brave Browser": "com.brave.Browser",
    ]
    nonisolated private static let zoomTitles = ["zoom meeting", "reunión de zoom", "reunión zoom", "zoom webinar", "seminario web de zoom"]

    struct Snapshot {
        /// Clases que se podrían proponer: reunión de Zoom, o pestaña con palabra clave en un navegador que suena.
        var candidates: [Source] = []
        /// Claves de todas las ventanas de navegador y Zoom abiertas, suenen o no.
        var openKeys: Set<String> = []
        var playing: [String] = []
        var zoomMeeting = false
    }

    nonisolated static func currentSources() -> [Source] { snapshot().candidates }

    nonisolated static func snapshot() -> Snapshot {
        // Prueba: `--fake-class "Título"` simula una clase sonando en Safari (sin depender del autoplay).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--fake-class"), i + 1 < args.count {
            let fake = Source(kind: .browser, app: "Google Chrome", title: WindowTitle.clean(args[i + 1], prefer: keywords) ?? "",
                              key: "fake", bundleID: "com.google.Chrome", platform: Platform.detect(args[i + 1].lowercased()))
            return Snapshot(candidates: [fake], openKeys: [fake.key])
        }
        // Todas las ventanas, no solo las visibles: Zoom a pantalla completa vive en otro escritorio.
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var snap = Snapshot(playing: audioBundles())
        for w in windows {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let app = w[kCGWindowOwnerName as String] as? String,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            let lower = title.lowercased()
            let bundle = (w[kCGWindowOwnerPID as String] as? pid_t).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            if app.hasPrefix("zoom"), zoomTitles.contains(where: lower.contains) {
                let key = "zoom:\(w[kCGWindowNumber as String] ?? 0)"
                snap.zoomMeeting = true
                snap.openKeys.insert(key)
                snap.candidates.append(Source(kind: .zoom, app: "Zoom", title: "Reunión de Zoom", key: key, bundleID: bundle))
            } else if let prefix = browsers[app] {
                let key = "\(app):\(title)"
                snap.openKeys.insert(key)
                let platform = Platform.detect(lower)
                if snap.playing.contains(where: { $0.hasPrefix(prefix) }),
                   platform?.isLive == true || keywords.contains(where: lower.contains) {
                    let shown = WindowTitle.clean(title, prefer: keywords) ?? "" // sin ids ni «- Google Chrome»
                    snap.candidates.append(Source(kind: .browser, app: app, title: shown, key: key, bundleID: bundle, platform: platform))
                }
            }
        }
        for (prefix, name) in desktopCalls where snap.playing.contains(where: { $0.hasPrefix(prefix) }) {
            let bundle = NSWorkspace.shared.runningApplications
                .first { $0.activationPolicy == .regular && $0.bundleIdentifier?.hasPrefix(prefix) == true }?.bundleIdentifier
            snap.candidates.append(Source(kind: .app, app: name, title: "", key: "app:\(prefix)", bundleID: bundle, audioPrefix: prefix))
        }
        return snap
    }

    /// Videollamadas de escritorio que no dejan título reconocible: se detectan porque suenan.
    nonisolated private static let desktopCalls = [("com.microsoft.teams", "Microsoft Teams"), ("Cisco-Systems.Spark", "Webex")]

    /// Bundle id de los procesos que están sacando sonido ahora (el navegador suena desde un proceso auxiliar).
    nonisolated static func audioBundles() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> String? in
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &runSize, &running) == noErr, running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            a.mSelector = kAudioProcessPropertyBundleID
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &bSize, &bundle) == noErr else { return nil }
            return bundle?.takeRetainedValue() as String?
        }
    }
}
