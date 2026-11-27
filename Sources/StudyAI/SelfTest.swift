import AVFoundation
import Foundation
import ImageIO
import StudyAICore
import SwiftData

/// Pruebas reales del pipeline sin interfaz, para validar cada pieza en un Mac concreto.
///   --selftest-capture <salida.wav> <segundos>   (lanzar con `open`, necesita el permiso de la app)
///   --selftest-transcribe <audio>                 transcribe un fichero por el mismo camino que la captura
///   --selftest-ai <transcripcion.txt>             genera apuntes, resumen y preguntas
enum SelfTest {
    static func run(mode: String, args: [String]) async -> Int32 {
        do {
            switch mode {
            case "--selftest-capture": try await capture(to: args[0], seconds: Double(args[safe: 1] ?? "10") ?? 10)
            case "--selftest-transcribe": try await transcribe(path: args[0], language: args[safe: 1] == "en" ? .english : .spanish)
            case "--selftest-ai": try await ai(path: args[0], language: args[safe: 1] == "en" ? .english : .spanish)
            case "--selftest-chat":
                // texto de transcripción + mensaje → respuesta y acción
                let text = try String(contentsOfFile: args[0], encoding: .utf8)
                let started = Date()
                let r = try await StudyAI.chat(args[1], history: [], transcript: text, summary: nil, language: args[safe: 2] == "en" ? .english : .spanish)
                log("acción=\(r.action) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)\nrespuesta: \(r.answer)\nañadir: \(r.addition)")
            case "--selftest-answer":
                // transcripción + pregunta → respuesta de «Preguntar a la asignatura» (fragmentos como en la app)
                let text = try String(contentsOfFile: args[0], encoding: .utf8)
                let chunks = Chunker.chunk(text, maxChars: 900)
                let top = Retriever.top(chunks, for: args[1], k: 4).map { "Clase «Prueba», minuto 0:00: \($0)" }
                log(try await StudyAI.answer(args[1], fragments: top, language: .spanish, terms: Prefs.vocabulary))
            case "--selftest-guide":
                // biblioteca (STUDYAI_STORE_DIR) → guía de examen de la primera asignatura con resúmenes, en Markdown
                let container = try Store.container()
                let ctx = ModelContext(container)
                var subjects = try ctx.fetch(FetchDescriptor<Subject>()).filter { $0.lectures.contains { $0.summary != nil } }
                if subjects.isEmpty, Store.testDirectory != nil {
                    // Solo en una copia: asignatura de prueba con las clases que tienen resumen.
                    let s = Subject(name: "Asignatura de prueba")
                    ctx.insert(s)
                    for l in try ctx.fetch(FetchDescriptor<Lecture>()) where l.summary != nil { l.subject = s }
                    try ctx.save()
                    subjects = [s]
                }
                guard let s = subjects.first else { log("no hay asignaturas con resúmenes"); return 1 }
                log(ExamGuide.markdown(s))
                if let out = args.first {
                    let md = ExamGuide.markdown(s)
                    await MainActor.run { ExamGuide.writePDF(md, to: URL(fileURLWithPath: out)) }
                    log("PDF: \(out)")
                }
            case "--selftest-language":
                // audio → confianza de cada idioma y el detectado
                let buffers = try LanguageDetector.buffers(of: URL(fileURLWithPath: args[0]))
                for s in await LanguageDetector.scores(buffers) { log("\(s.language.name): confianza \(String(format: "%.3f", s.confidence)), \(s.words) palabras") }
                log("detectado: \(await LanguageDetector.detect(buffers)?.name ?? "(no se pudo)")")
            case "--selftest-detector":
                // qué apps suenan y qué clases se ofrecerían ahora mismo
                log("suenan: \(ClassDetector.audioBundles())")
                log("clases: \(ClassDetector.currentSources().map { "\($0.app) · \($0.title)" })")
            case "--selftest-speaker":
                // Una o varias capturas (PNG/JPG) → quién habla en cada una.
                log("visión disponible: \(SpeakerVision.isAvailable)")
                for path in args {
                    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { log("\(path): no se pudo leer"); continue }
                    log("\((path as NSString).lastPathComponent): rótulos \(SpeakerVision.nameLabels(in: image).map(\.name))")
                    log("\((path as NSString).lastPathComponent): términos \(await SpeakerVision.read(image).terms.sorted())")
                    log("\((path as NSString).lastPathComponent) → \(await SpeakerVision.guess(image) ?? "(nadie)")")
                    // Rótulos que Vision sitúa un poco fuera de la imagen: no deben tumbar la app.
                    if let p = Pixels(image) {
                        let w = CGFloat(p.width), h = CGFloat(p.height)
                        for r in [CGRect(x: -30, y: -10, width: 60, height: 20), CGRect(x: w - 10, y: h - 5, width: 80, height: 30),
                                  CGRect(x: w + 40, y: h + 40, width: 50, height: 20), CGRect(x: -200, y: -200, width: 50, height: 20)] {
                            _ = p.hasBorder(near: r)
                        }
                        log("rótulos fuera de la imagen: sin fallo")
                    }
                }
            case "--selftest-batch":
                // «Volver a generar todos» sobre una copia (STUDYAI_STORE_DIR) y el estado en que queda cada clase.
                guard Store.testDirectory != nil else { log("solo con STUDYAI_STORE_DIR"); return 1 }
                try await batch()
            default: log("Modo desconocido: \(mode)"); return 2
            }
            return 0
        } catch {
            log("ERROR: \(error.localizedDescription) [\(error)]")
            return 1
        }
    }

    private static var logURL: URL?
    private static func log(_ s: String) {
        print(s)
        if let logURL, let data = (s + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: logURL) }
        }
    }

    // MARK: Captura → WAV

    private static func capture(to path: String, seconds: Double) async throws {
        logURL = URL(fileURLWithPath: path + ".log")
        try? FileManager.default.removeItem(at: logURL!)
        log("permiso=\(ScreenAudioPermission.isGranted)")
        let capture = SystemAudioCapture()
        let lock = NSLock()
        var file: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var peak: Float = 0
        capture.onBuffer = { buf in
            lock.lock(); defer { lock.unlock() }
            if file == nil {
                file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: buf.format.settings)
            }
            try? file?.write(from: buf)
            frames += AVAudioFramePosition(buf.frameLength)
            peak = max(peak, AudioLevel.rms(buf))
        }
        capture.onStop = { log("stream detenido: \($0)") }
        try await capture.start()
        log("capturando \(seconds) s…")
        try await Task.sleep(for: .seconds(seconds))
        await capture.stop()
        lock.withLock {
            log("frames=\(frames) formato=\(file?.processingFormat.description ?? "-") rms_max=\(peak)")
            file = nil
        }
    }

    // MARK: Fichero → transcripción

    private static func transcribe(path: String, language: ClassLanguage) async throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        print("audio: \(String(format: "%.1f", duration)) s, \(file.processingFormat)")
        let transcriber = LiveTranscriber()
        let started = Date()
        try await transcriber.start(language: language, onVolatile: { _ in }) { s, e, text in
            print("[\(TimeFormat.clock(s))–\(TimeFormat.clock(e))] \(text)")
        }
        // Mismo tamaño de buffer que entrega ScreenCaptureKit (~20 ms).
        let chunk: AVAudioFrameCount = 1024
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            transcriber.append(buf)
        }
        await transcriber.finish()
        let took = Date().timeIntervalSince(started)
        print(String(format: "tardó %.1f s (%.1fx tiempo real)", took, duration / took))
    }

    // MARK: Texto → apuntes

    @MainActor private static func batch() async throws {
        let container = try Store.container() // vivo mientras dure: sin él, el contexto cae
        let ctx = container.mainContext
        let processor = LectureProcessor(context: ctx)
        processor.regenerateAll()
        while processor.batch != nil { try await Task.sleep(for: .milliseconds(500)) }
        for l in try ctx.fetch(FetchDescriptor<Lecture>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])) where !l.transcriptText.isEmpty {
            log("\(l.displayTitle.prefix(40)) · pendiente=\(l.cloudRetryAt.map { _ in "sí" } ?? "no") · resumen=\(l.summary?.count ?? 0) · \(l.processingError?.prefix(50) ?? "")")
        }
    }

    private static func ai(path: String, language: ClassLanguage) async throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        print("disponibilidad=\(AIAvailability.current) motor=\(AIEngine.usable.rawValue) caracteres=\(text.count)")
        let started = Date()
        print("vocabulario: \(Prefs.vocabulary)")
        let out = try await StudyAI.process(transcript: text, language: language, terms: Prefs.vocabulary) { f, step in print(String(format: "%3.0f%% %@", f * 100, step)) }
        print("\n## Resumen\n\(out.summary ?? "(sin resumen)")\n\n## Preguntas")
        for (i, q) in out.reviewQuestions.enumerated() { print("- \(q)\n  → \(out.reviewAnswers[safe: i] ?? "(sin respuesta)")") }
        print("\n## Apuntes\n\(out.notesMarkdown)\n\nbloques omitidos=\(out.skippedBlocks)")
        print("respaldo al modelo del Mac: \(out.fallbackReason ?? "no")")
        print(String(format: "tardó %.0f s", Date().timeIntervalSince(started)))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
