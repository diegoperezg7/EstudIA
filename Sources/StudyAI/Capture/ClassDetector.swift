import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Avisa cuando empieza una clase: una reunión de Zoom o un vídeo de clase sonando en el navegador.
/// Mira cada 4 s los títulos de las ventanas (los deja leer el permiso de grabación de pantalla que ya tiene la app)
/// y qué apps están sacando sonido (CoreAudio, sin permisos). Nunca graba sola: solo propone en la píldora.
@MainActor @Observable final class ClassDetector {
    struct Source: Equatable {
        enum Kind { case zoom, browser }
        var kind: Kind
        var app: String
        var title: String
        /// Identifica la ventana para no volver a preguntar mientras siga abierta tras «Ahora no».
        var key: String
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
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var recordingSource: Source?
    @ObservationIgnored private var timer: Timer?

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
            await session.start(subject: nil, language: ClassLanguage(rawValue: UserDefaults.standard.string(forKey: Prefs.languageKey) ?? "") ?? .spanish)
            if !session.isActive { recordingSource = nil }
        }
    }

    /// «Ahora no»: no vuelve a preguntar por esa ventana mientras siga abierta.
    func dismiss() {
        if let offer { dismissed.insert(offer.key) }
        offer = nil
        RecordingPill.hideOffer()
    }

    private func tick() {
        guard let session else { return }
        let sources = Self.currentSources()
        // Las ventanas que se cerraron dejan de estar descartadas: si vuelven a abrir la clase, se pregunta.
        dismissed.formIntersection(sources.map(\.key))

        if session.isActive || session.phase == .starting {
            if offer != nil { offer = nil; RecordingPill.hideOffer() }
            if let rec = recordingSource {
                let gone = !sources.contains { $0.kind == rec.kind && $0.app == rec.app }
                if gone != sourceEnded { sourceEnded = gone }
            }
            return
        }
        recordingSource = nil
        if sourceEnded { sourceEnded = false }
        guard Self.enabled, session.finished == nil else { return }

        let candidate = sources.first { !dismissed.contains($0.key) }
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

    nonisolated static func currentSources() -> [Source] {
        // Prueba: `--fake-class "Título"` simula una clase sonando en Safari (sin depender del autoplay).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--fake-class"), i + 1 < args.count {
            return [Source(kind: .browser, app: "Safari", title: args[i + 1], key: "fake")]
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let playing = audioBundles()
        var out: [Source] = []
        for w in windows {
            guard let app = w[kCGWindowOwnerName as String] as? String,
                  let title = w[kCGWindowName as String] as? String, !title.isEmpty else { continue }
            let lower = title.lowercased()
            if app.hasPrefix("zoom"), zoomTitles.contains(where: lower.contains) {
                out.append(Source(kind: .zoom, app: "Zoom", title: "Reunión de Zoom", key: "zoom:\(w[kCGWindowNumber as String] ?? 0)"))
            } else if let prefix = browsers[app], playing.contains(where: { $0.hasPrefix(prefix) }),
                      keywords.contains(where: lower.contains) {
                out.append(Source(kind: .browser, app: app, title: title, key: "\(app):\(title)"))
            }
        }
        return out
    }

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
