import Foundation
import StudyAICore
import SwiftData

@Model final class Subject {
    var name: String
    var createdAt: Date
    /// SF Symbol elegido; nil = se adivina por el nombre.
    var icon: String?
    @Relationship(deleteRule: .nullify, inverse: \Lecture.subject) var lectures: [Lecture] = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }
}

/// Idioma en que se habla la clase: decide el reconocedor y el idioma de resumen, apuntes y chat.
enum ClassLanguage: String, CaseIterable {
    case spanish = "es-ES", english = "en-US"

    /// Bandera (flag-icons, MIT) en Assets: España o Reino Unido.
    var flag: String { self == .spanish ? "FlagES" : "FlagGB" }
    var name: String { self == .spanish ? "Español" : "English" }
    /// Cómo se nombra el idioma dentro de las instrucciones al modelo.
    var inPrompt: String { self == .spanish ? "español" : "inglés" }
}

enum LectureStatus: String {
    case recording, processing, ready, transcriptOnly
}

@Model final class Lecture {
    var title: String
    var createdAt: Date
    var duration: Double = 0
    var subject: Subject?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.lecture) var segments: [TranscriptSegment] = []
    /// Diapositivas, PDF u otros ficheros que acompañan a la clase.
    @Relationship(deleteRule: .cascade, inverse: \Material.lecture) var materials: [Material] = []

    var statusRaw: String = LectureStatus.recording.rawValue
    var summary: String?
    var notesMarkdown: String?
    var reviewQuestions: [String] = []
    var processingError: String?
    /// Lo que Ana apunta a mano en la clase.
    var userNotes: String = ""
    var languageRaw: String = ClassLanguage.spanish.rawValue
    /// Texto aún provisional de la grabación en curso, guardado cada pocos segundos: el reconocedor puede tardar
    /// más de un minuto en cerrar un párrafo si el profesor no hace pausas, y un cuelgue no debe perderlo.
    var liveDraft: String?
    /// El resumen lleva texto añadido desde el chat: antes de volver a generarlo se pide confirmación.
    var summaryEdited: Bool = false
    /// Respuesta de cada pregunta de repaso, en el mismo orden. Vacío en clases procesadas antes de tenerlas.
    var reviewAnswers: [String] = []
    /// Términos que se vieron escritos en pantalla durante la grabación (diapositivas, nombres, productos):
    /// corrigen lo que el reconocedor oye mal y orientan a la IA.
    var screenTerms: [String] = []
    /// El proveedor externo agotó su cupo del día: la clase se procesa sola con él a partir de esta hora.
    var cloudRetryAt: Date?

    var language: ClassLanguage {
        get { ClassLanguage(rawValue: languageRaw) ?? .spanish }
        set { languageRaw = newValue.rawValue }
    }

    init(title: String, subject: Subject?) {
        self.title = title
        self.subject = subject
        self.createdAt = .now
    }

    var status: LectureStatus {
        get { LectureStatus(rawValue: statusRaw) ?? .transcriptOnly }
        set { statusRaw = newValue.rawValue }
    }

    /// Las grabaciones nacen sin nombre: lo pone Ana o, si no, la IA al procesar.
    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Clase sin nombre" : title }

    /// «martes, 25 de noviembre de 2026, 18:30».
    var dateTimeText: String {
        createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Locale(identifier: "es_ES")))
    }

    var orderedSegments: [TranscriptSegment] { segments.sorted { $0.start < $1.start } }

    var transcriptText: String {
        orderedSegments.filter { !$0.isGap }.map(\.text).joined(separator: " ")
    }

    /// Comienzo de la transcripción, para las tarjetas sin resumen y la búsqueda.
    var transcriptPreview: String {
        String(orderedSegments.lazy.filter { !$0.isGap }.prefix(2).map(\.text).joined(separator: " ").prefix(240))
    }

    var wordCount: Int { segments.reduce(0) { $0 + ($1.isGap ? 0 : $1.text.split(separator: " ").count) } }

    func markdown() -> String {
        MarkdownExport.render(
            title: displayTitle, subject: subject?.name, date: createdAt, duration: duration,
            summary: summary, notes: notesMarkdown, questions: reviewQuestions, userNotes: userNotes,
            segments: orderedSegments.map { .init(start: $0.start, text: $0.text, isGap: $0.isGap, speaker: $0.speaker) })
    }
}

@Model final class TranscriptSegment {
    var start: Double
    var end: Double
    var text: String
    /// Marca de hueco: el audio se interrumpió entre `start` y `end`.
    var isGap: Bool
    /// Quién habla, deducido de la pantalla (recuadro resaltado, rótulo). nil si no se pudo saber.
    var speaker: String?
    var lecture: Lecture?

    init(start: Double, end: Double, text: String, isGap: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.isGap = isGap
    }
}

extension TranscriptSegment {
    /// Añade el trozo a este párrafo si es su continuación natural. false = va en párrafo aparte.
    func absorb(start: Double, end: Double, text: String, speaker: String?) -> Bool {
        let same = speaker == nil || self.speaker == nil || speaker == self.speaker
        guard !isGap, Paragrapher.continues(previous: self.text, previousEnd: self.end, next: text, nextStart: start, sameSpeaker: same) else { return false }
        self.text += " " + text
        self.end = max(self.end, end)
        if self.speaker == nil { self.speaker = speaker }
        return true
    }
}

enum Store {
    /// Las clases grabadas antes de unir párrafos tienen trozos de dos palabras: se unen una sola vez.
    @MainActor static func mergeShortParagraphs(_ context: ModelContext) {
        let key = "paragraphsMerged.v1"
        guard testDirectory != nil || !UserDefaults.standard.bool(forKey: key) else { return }
        for lecture in (try? context.fetch(FetchDescriptor<Lecture>())) ?? [] where lecture.status != .recording {
            var last: TranscriptSegment?
            for segment in lecture.orderedSegments {
                if segment.isGap { last = nil; continue }
                if let l = last, l.absorb(start: segment.start, end: segment.end, text: segment.text, speaker: segment.speaker) {
                    context.delete(segment)
                } else {
                    last = segment
                }
            }
        }
        guard (try? context.save()) != nil, testDirectory == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Al estrenar versión, antes de abrir la biblioteca con ella: copia de la base de datos en Copias/<versión anterior>.
    /// Si una actualización saliera mal, las clases siguen ahí. Se guardan las 3 últimas.
    /// La 1.0 no guardaba su versión: si hay biblioteca y no hay versión anotada, viene de la 1.0.
    static func backupOnNewVersion(_ dir: URL) {
        let key = testDirectory == nil ? "lastOpenedVersion" : "lastOpenedVersion.test" // la prueba no toca la real
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let previous = UserDefaults.standard.string(forKey: key)
        guard previous != current else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("StudyAI.store") }
        guard !files.isEmpty else { // instalación nueva: nada que copiar
            UserDefaults.standard.set(current, forKey: key)
            return
        }
        let backups = dir.appending(path: "Copias", directoryHint: .isDirectory)
        let dest = backups.appending(path: "\(previous ?? "1.0") \(Date.now.formatted(.iso8601.year().month().day()))", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in files where !fm.fileExists(atPath: dest.appending(path: name).path) {
                try fm.copyItem(at: dir.appending(path: name), to: dest.appending(path: name))
            }
        } catch {
            // Sin anotar la versión: se vuelve a intentar en el próximo arranque.
            NSLog("StudyAI: no se pudo copiar la biblioteca antes de actualizar: \(error)")
            return
        }
        UserDefaults.standard.set(current, forKey: key)
        let old = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for url in old.dropFirst(3) { try? fm.removeItem(at: url) }
    }

    /// Carpeta de datos alternativa para probar con una copia de la biblioteca sin tocar la real.
    static let testDirectory = ProcessInfo.processInfo.environment["STUDYAI_STORE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let directory = testDirectory ?? URL.applicationSupportDirectory.appending(path: "StudyAI", directoryHint: .isDirectory)

    static func container() throws -> ModelContainer {
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backupOnNewVersion(dir)
        let config = ModelConfiguration(url: dir.appending(path: "StudyAI.store"))
        return try ModelContainer(for: Subject.self, Lecture.self, TranscriptSegment.self, Material.self, configurations: config)
    }
}

extension Lecture {
    /// Borrada: tras guardar el borrado, SwiftData puede dejar `isDeleted` en false y solo queda sin contexto.
    var isGone: Bool { isDeleted || modelContext == nil }
}
