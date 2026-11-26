import AVFoundation
import Speech
import StudyAICore

/// Detecta en qué idioma se habla: transcribe el mismo audio en español y en inglés y se queda con el
/// reconocedor que lo entiende con más confianza (el del idioma equivocado da palabras dudosas).
enum LanguageDetector {
    struct Score { var language: ClassLanguage; var confidence: Double; var words: Int }

    /// Confianza media de cada idioma sobre unos segundos de audio (buffers ya capturados).
    static func scores(_ buffers: [AVAudioPCMBuffer]) async -> [Score] {
        await withTaskGroup(of: Score?.self) { group in
            for language in ClassLanguage.allCases {
                group.addTask { try? await score(buffers, language: language) }
            }
            return await group.reduce(into: []) { if let s = $1 { $0.append(s) } }
        }
    }

    /// El idioma ganador, o nil si no hay voz suficiente para decidir.
    static func detect(_ buffers: [AVAudioPCMBuffer]) async -> ClassLanguage? {
        let all = await scores(buffers)
        guard let best = all.max(by: { $0.confidence < $1.confidence }), best.words >= 8 else { return nil }
        return best.language
    }

    private static func score(_ buffers: [AVAudioPCMBuffer], language: ClassLanguage) async throws -> Score {
        guard let locale = try? await LiveTranscriber.resolvedLocale(language),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
        else { return Score(language: language, confidence: 0, words: 0) } // sin el modelo de ese idioma no compite
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return Score(language: language, confidence: 0, words: 0)
        }
        let resampler = AudioResampler(outputFormat: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var total = 0.0, count = 0, words = 0
            for try await r in transcriber.results where r.isFinal {
                for run in r.text.runs {
                    guard let c = run.transcriptionConfidence else { continue }
                    let n = r.text[run.range].characters.split(separator: " ").count
                    total += c * Double(max(n, 1)); count += max(n, 1); words += n
                }
            }
            return (count == 0 ? 0 : total / Double(count), words)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        for b in buffers { if let c = resampler.convert(b), c.frameLength > 0 { input.yield(AnalyzerInput(buffer: c)) } }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (confidence, words) = try await collect.value
        return Score(language: language, confidence: confidence, words: words)
    }

    /// Los primeros segundos de un fichero, en buffers de un segundo.
    static func buffers(of url: URL, seconds: Double = 40) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < min(file.length, AVAudioFramePosition(seconds * format.sampleRate)) {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: b, frameCount: chunk)
            if b.frameLength == 0 { break }
            out.append(b)
        }
        return out
    }
}
