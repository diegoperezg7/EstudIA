import AVFoundation
import Foundation
import os
import StudyAICore
import SwiftData

/// Procesado con IA en segundo plano, una clase cada vez, con progreso y cancelación.
@MainActor @Observable final class LectureProcessor {
    struct Progress { var fraction: Double; var step: String }

    private(set) var progress: [PersistentIdentifier: Progress] = [:]
    /// «Volver a generar todos»: cuántas clases van hechas. nil si no hay tanda en marcha.
    private(set) var batch: (done: Int, total: Int)?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) { self.context = context }

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
                for (s, e, text) in Paragrapher.mergeShort(found.withLock({ $0 }).map { (start: $0.0, end: $0.1, text: $0.2) }) {
                    let segment = TranscriptSegment(start: s, end: e, text: text)
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

    func process(_ lecture: Lecture) {
        let id = lecture.persistentModelID
        guard tasks[id] == nil else { return }

        // Volver a generar: lo que ya había sigue a la vista y solo se sustituye si lo nuevo sale bien.
        let regenerating = lecture.summary != nil || !(lecture.notesMarkdown ?? "").isEmpty
        if case .unavailable(let reason) = AIAvailability.current, AIEngine.usable == .local {
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

        tasks[id] = Task {
            defer { tasks[id] = nil; progress[id] = nil }
            do {
                let out = try await StudyAI.process(transcript: transcript, language: language,
                                                    material: { Materials.context(for: $0, pages: pages) }) { f, step in
                    self.progress[id] = Progress(fraction: f, step: step)
                }
                guard !lecture.isGone else { return }
                lecture.notesMarkdown = out.notesMarkdown
                if let summary = out.summary {
                    lecture.summary = summary
                    lecture.reviewQuestions = out.reviewQuestions
                    lecture.summaryEdited = false
                }
                // Solo si Ana no le ha puesto nombre: su título nunca se pisa.
                if lecture.title.trimmingCharacters(in: .whitespaces).isEmpty, let t = out.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    lecture.title = t
                }
                lecture.status = .ready
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
