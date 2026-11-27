import AVFoundation
import Foundation
import os
import StudyAICore
import SwiftData
import UserNotifications

/// Procesado con IA en segundo plano, una clase cada vez, con progreso y cancelación.
@MainActor @Observable final class LectureProcessor {
    struct Progress { var fraction: Double; var step: String }

    private(set) var progress: [PersistentIdentifier: Progress] = [:]
    /// «Volver a generar todos»: cuántas clases van hechas. nil si no hay tanda en marcha.
    private(set) var batch: (done: Int, total: Int)?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        // Clases que esperan a que el proveedor renueve su cupo diario: se miran al abrir y cada 5 minutos.
        pendingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let processor = self else { return }
                await processor.processDue()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    /// De una en una, como la tanda: a la vez chocarían con el límite por minuto del proveedor.
    private func processDue() async {
        let now = Date.now
        let all = (try? context.fetch(FetchDescriptor<Lecture>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        for lecture in all where !lecture.isGone && (lecture.cloudRetryAt ?? .distantFuture) <= now {
            process(lecture)
            await tasks[lecture.persistentModelID]?.value
            // Sigue sin cupo: las demás esperan con la hora que ya tenían.
            if !lecture.isGone, lecture.cloudRetryAt != nil { break }
        }
    }

    func isProcessing(_ lecture: Lecture) -> Bool { tasks[lecture.persistentModelID] != nil }

    /// Importa una grabación (audio o vídeo descargado) por el mismo pipeline que la captura en vivo.
    @discardableResult
    func importFile(_ url: URL, subject: Subject?, language: ClassLanguage = .spanish) -> Lecture {
        var language = language
        let lecture = Lecture(title: url.deletingPathExtension().lastPathComponent, subject: subject)
        lecture.language = language
        context.insert(lecture)
        try? context.save()
        let id = lecture.persistentModelID
        progress[id] = Progress(fraction: 0, step: "Transcribiendo")

        tasks[id] = Task {
            let found = OSAllocatedUnfairLock(initialState: [(Double, Double, String)]())
            do {
                if Prefs.autoLanguage, let audio = try? LanguageDetector.buffers(of: url),
                   let detected = await LanguageDetector.detect(audio) {
                    language = detected
                    lecture.language = detected
                }
                let language = language
                // Fuera del hilo principal; la cancelación se propaga a mano porque un detached no la hereda.
                let work = Task.detached(priority: .userInitiated) { [self] in
                    try await Self.transcribe(url, language: language, into: found) { f in
                        Task { @MainActor in self.progress[id] = Progress(fraction: f, step: "Transcribiendo") }
                    }
                }
                let duration = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !lecture.isGone else { throw CancellationError() }
                let terms = Prefs.vocabulary + ((try? context.fetch(FetchDescriptor<Subject>())) ?? []).map(\.name)
                for (s, e, text) in Paragrapher.mergeShort(found.withLock({ $0 }).map { (start: $0.0, end: $0.1, text: $0.2) }) {
                    let segment = TranscriptSegment(start: s, end: e, text: TermFixer.fix(text, terms: terms))
                    segment.lecture = lecture
                    context.insert(segment)
                }
                lecture.duration = duration
                lecture.status = lecture.segments.isEmpty ? .transcriptOnly : .processing
                if lecture.segments.isEmpty { lecture.processingError = "No se detectó voz en el archivo." }
            } catch {
                if !lecture.isGone {
                    lecture.status = .transcriptOnly
                    lecture.processingError = error is CancellationError
                        ? "Importación cancelada." : "No se pudo leer el archivo: \(error.localizedDescription)"
                }
            }
            tasks[id] = nil
            progress[id] = nil
            guard !lecture.isGone else { return }
            try? context.save()
            if lecture.status == .processing { process(lecture) }
        }
        return lecture
    }

    nonisolated private static func transcribe(_ url: URL, language: ClassLanguage, into found: OSAllocatedUnfairLock<[(Double, Double, String)]>,
                                               progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        try await LiveTranscriber.transcribeFile(url, language: language, progress: progress) { s, e, text in
            found.withLock { $0.append((s, e, text)) }
        }
    }

    /// `local`: con el modelo del Mac aunque haya otro elegido (la clase esperaba al cupo del proveedor y Ana no quiere esperar).
    func process(_ lecture: Lecture, local: Bool = false) {
        let id = lecture.persistentModelID
        guard tasks[id] == nil else { return }
        lecture.cloudRetryAt = nil

        // Volver a generar: lo que ya había sigue a la vista y solo se sustituye si lo nuevo sale bien.
        let regenerating = lecture.summary != nil || !(lecture.notesMarkdown ?? "").isEmpty
        if case .unavailable(let reason) = AIAvailability.current, local || AIEngine.usable == .local {
            if !regenerating { lecture.status = .transcriptOnly }
            lecture.processingError = reason
            try? context.save()
            return
        }

        if !regenerating { lecture.status = .processing }
        lecture.processingError = nil
        progress[id] = Progress(fraction: 0, step: "Preparando")
        let transcript = lecture.transcriptText
        let language = lecture.language
        let pages = lecture.materials.sorted { $0.createdAt < $1.createdAt }.flatMap(\.pageTexts).filter { !$0.isEmpty }
        let terms = Self.terms(for: lecture)

        tasks[id] = Task {
            defer { tasks[id] = nil; progress[id] = nil }
            do {
                let out = try await StudyAI.process(transcript: transcript, language: language,
                                                    material: { Materials.context(for: $0, pages: pages) },
                                                    terms: terms, engine: local ? .local : nil) { f, step in
                    self.progress[id] = Progress(fraction: f, step: step)
                }
                guard !lecture.isGone else { return }
                lecture.notesMarkdown = out.notesMarkdown
                if let summary = out.summary {
                    lecture.summary = summary
                    lecture.reviewQuestions = out.reviewQuestions
                    lecture.reviewAnswers = out.reviewAnswers
                    lecture.summaryEdited = false
                }
                // Solo si Ana no le ha puesto nombre: su título nunca se pisa.
                if lecture.title.trimmingCharacters(in: .whitespaces).isEmpty, let t = out.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    lecture.title = t
                }
                if lecture.subject == nil, !regenerating { // al rehacer, «sin asignatura» puede ser a propósito
                    let subjects = (try? context.fetch(FetchDescriptor<Subject>())) ?? []
                    lecture.subject = SubjectGuess.byTitle(lecture.title, subjects: subjects.map(\.name)).flatMap { n in subjects.first { $0.name == n } }
                }
                lecture.status = .ready
                if !regenerating || batch == nil { Self.notifyReady(lecture) }
                var notes: [String] = []
                if out.summary == nil {
                    notes.append(regenerating && lecture.summary != nil
                        ? "El resumen no se pudo volver a generar y se mantiene el anterior; los apuntes sí son nuevos."
                        : "El resumen no se pudo generar; los apuntes sí.")
                }
                if let reason = out.fallbackReason {
                    notes.append("Se generó con el modelo del Mac porque el de la nube no respondió (\(reason)).")
                }
                if out.skippedBlocks > 0 {
                    notes.append("\(out.skippedBlocks) bloque(s) no se pudieron resumir y solo están en la transcripción.")
                }
                lecture.processingError = notes.isEmpty ? nil : notes.joined(separator: " ")
            } catch CloudError.dailyQuota(let until) {
                guard !lecture.isGone else { return }
                lecture.cloudRetryAt = until
                if !regenerating { lecture.status = .transcriptOnly }
                lecture.processingError = "El proveedor ha agotado el cupo gratuito de hoy. Se hará solo con él a partir de las \(until.formatted(date: .omitted, time: .shortened))."
            } catch is CancellationError {
                guard !lecture.isGone, !regenerating else { return }
                lecture.status = .transcriptOnly
                lecture.processingError = "Procesado cancelado."
            } catch {
                guard !lecture.isGone else { return }
                if regenerating {
                    lecture.processingError = "No se pudo volver a generar y se mantiene lo que había: \(error.localizedDescription)"
                } else {
                    lecture.status = .transcriptOnly
                    lecture.processingError = "No se pudieron generar los apuntes: \(error.localizedDescription)"
                }
            }
            try? context.save()
        }
    }

    /// Lo que la transcripción suele traer mal escrito: vocabulario de Ajustes, asignaturas y lo visto en pantalla.
    static func terms(for lecture: Lecture) -> [String] {
        var seen = Set<String>()
        return (Prefs.vocabulary + [lecture.subject?.name].compactMap { $0 } + lecture.screenTerms)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Aviso de macOS: con un proveedor externo el procesado tarda unos minutos y Ana puede estar en otra cosa.
    /// Clases avisadas, por identificador del aviso: al pulsarlo se abre la clase.
    static var notified: [String: Lecture] = [:]

    static func notifyReady(_ lecture: Lecture) {
        let center = UNUserNotificationCenter.current()
        let title = lecture.displayTitle
        let id = UUID().uuidString
        notified[id] = lecture
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Resumen listo"
            content.body = "«\(title)»: ya tienes el resumen, los apuntes y las preguntas de repaso."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    @ObservationIgnored private var batchCurrent: PersistentIdentifier?

    func cancel(_ lecture: Lecture) {
        tasks[lecture.persistentModelID]?.cancel()
    }

    /// Rehace resumen y apuntes de todas las clases con transcripción, de la más reciente a la más antigua y de una en una.
    func regenerateAll() {
        guard batchTask == nil else { return }
        let all = (try? context.fetch(FetchDescriptor<Lecture>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        // Las clases con texto añadido desde el chat se rehacen solo a mano (piden confirmación una a una).
        let lectures = all.filter { $0.status != .recording && !$0.transcriptText.isEmpty && !$0.summaryEdited }
        guard !lectures.isEmpty else { return }
        batch = (0, lectures.count)
        batchTask = Task {
            for (i, lecture) in lectures.enumerated() {
                guard !Task.isCancelled else { break }
                if !lecture.isGone {
                    batchCurrent = lecture.persistentModelID
                    process(lecture)
                    await tasks[lecture.persistentModelID]?.value
                    // Cupo del día agotado: el resto fallaría igual; quedan pendientes para cuando se reponga.
                    if !lecture.isGone, let retry = lecture.cloudRetryAt {
                        for rest in lectures.dropFirst(i + 1) where !rest.isGone {
                            rest.cloudRetryAt = retry
                            rest.processingError = lecture.processingError
                        }
                        try? context.save()
                        break
                    }
                }
                batch = (i + 1, lectures.count)
            }
            batch = nil
            batchTask = nil
            batchCurrent = nil
        }
    }

    /// Para la tanda y la clase que está rehaciendo; no toca importaciones ni la clase recién grabada.
    func cancelBatch() {
        batchTask?.cancel()
        if let batchCurrent { tasks[batchCurrent]?.cancel() }
    }
}
