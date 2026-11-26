import AVFoundation
import os
import Speech
import StudyAICore

enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale: "Este Mac no ofrece transcripción en ese idioma."
        case .noAudioFormat: "El motor de transcripción no aceptó ningún formato de audio."
        }
    }
}

/// Transcripción en streaming con SpeechAnalyzer, en el propio Mac.
/// El audio entra por `append` (desde la cola de captura) y no se acumula en memoria.
final class LiveTranscriber: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    /// Se escribe desde el hilo principal y se lee desde la cola de audio: siempre bajo el candado.
    private let input = OSAllocatedUnfairLock<AsyncStream<AnalyzerInput>.Continuation?>(initialState: nil)
    private var resampler: AudioResampler?
    private var resultsTask: Task<Void, Never>?

    // MARK: Modelo de idioma

    static func resolvedLocale(_ language: ClassLanguage) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw TranscriptionError.unsupportedLocale
        }
        return locale
    }

    static func isLanguageInstalled(_ language: ClassLanguage = .spanish) async -> Bool {
        guard let locale = try? await resolvedLocale(language) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Descarga el modelo del idioma si falta. `progress` informa de 0 a 1.
    static func installLanguage(_ language: ClassLanguage = .spanish, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let transcriber = makeTranscriber(locale: try await resolvedLocale(language))
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    /// Un resultado puede abarcar minutos si el profesor no hace pausas: se parte en párrafos con su propio tiempo.
    static func paragraphs(of result: SpeechTranscriber.Result) -> [(start: Double, end: Double, text: String)] {
        let text = result.text
        let pieces = text.runs[\.audioTimeRange].map { timeRange, range in
            Paragrapher.Piece(text: String(text[range].characters),
                              start: timeRange.map { $0.start.seconds }, end: timeRange.map { $0.end.seconds })
        }
        return Paragrapher.split(pieces, fallbackStart: result.range.start.seconds, fallbackEnd: result.range.end.seconds)
    }

    // MARK: Fichero

    /// Transcribe un fichero de audio o vídeo. El analizador lo lee a su ritmo: no se carga entero en memoria.
    /// Devuelve la duración en segundos.
    static func transcribeFile(_ url: URL, language: ClassLanguage, progress: @escaping @Sendable (Double) -> Void,
                               onFinal: @escaping @Sendable (Double, Double, String) -> Void) async throws -> Double {
        try await installLanguage(language)
        let transcriber = makeTranscriber(locale: try await resolvedLocale(language))
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let results = Task {
            for try await r in transcriber.results where r.isFinal {
                for p in paragraphs(of: r) { onFinal(p.start, p.end, p.text) }
                if duration > 0 { progress(min(1, r.range.end.seconds / duration)) }
            }
        }
        try await withTaskCancellationHandler {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await results.value
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        return duration
    }

    // MARK: Sesión

    /// `onVolatile`: texto provisional de la frase en curso. `onFinal`: segmento definitivo (inicio, fin, texto).
    /// `onFailure`: el analizador dejó de dar resultados por un error. Los tiempos son de audio recibido: las pausas no cuentan.
    func start(language: ClassLanguage,
               onVolatile: @escaping @Sendable (String) -> Void,
               onFinal: @escaping @Sendable (Double, Double, String) -> Void,
               onFailure: @escaping @Sendable () -> Void = {}) async throws {
        try await Self.installLanguage(language)
        let transcriber = Self.makeTranscriber(locale: try await Self.resolvedLocale(language))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        resampler = AudioResampler(outputFormat: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        input.withLock { $0 = continuation }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        for p in Self.paragraphs(of: result) { onFinal(p.start, p.end, p.text) }
                        onVolatile("")
                    } else {
                        onVolatile(text)
                    }
                }
            } catch is CancellationError {
            } catch {
                NSLog("StudyAI: resultados de transcripción interrumpidos: \(error)")
                if !Task.isCancelled { onFailure() }
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
    }

    /// Llamar siempre desde la misma cola (la de captura).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler?.convert(buffer), converted.frameLength > 0 else { return }
        input.withLock { _ = $0?.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Cierra la entrada y espera a que se emitan los últimos segmentos definitivos.
    func finish() async {
        closeInput()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer?.cancelAndFinishNow()
        }
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
    }

    private func closeInput() {
        input.withLock { $0?.finish(); $0 = nil }
    }

    func cancel() async {
        resultsTask?.cancel() // primero: así un error al cancelar no se toma por un fallo
        closeInput()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }
}
