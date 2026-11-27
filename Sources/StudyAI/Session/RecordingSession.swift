import AVFoundation
import Foundation
import os
import StudyAICore
import SwiftData

/// Datos que escribe la cola de audio (y el transcriptor) y lee el hilo principal.
private struct LiveStats {
    var paused = false
    var level: Float = 0
    var lastSound = Date()
    /// Segundos de audio entregados al transcriptor: la misma escala que las marcas de tiempo de los segmentos.
    var fedSeconds: Double = 0
    var pendingSegments: [(start: Double, end: Double, text: String)] = []
    var volatileText = ""
    var transcriberFailed = false
    /// Bandas del espectro (0-1) para las ondas de la píldora y de la app.
    var bands: [Float] = []
    /// El transcriptor que recibe el audio. Se cambia en caliente si se detecta otro idioma.
    var transcriber: LiveTranscriber?
    /// Cada transcriptor nuevo sube la generación: los resultados del anterior se ignoran.
    var generation = 0
    /// Detección de idioma: el audio del principio se guarda hasta decidir, para no perderlo si hay que cambiar.
    var detecting = false
    var pending: [AVAudioPCMBuffer] = []
    var pendingSeconds = 0.0
    /// Audio que el nuevo transcriptor tiene que recibir antes que el siguiente buffer en vivo.
    var replay: [AVAudioPCMBuffer] = []
}

enum StartProblem: Equatable {
    case permission
    case language
    case other(String)

    var message: String {
        switch self {
        case .permission: CaptureError.permissionDenied.localizedDescription
        case .language: "Falta descargar el modelo de transcripción en español. Hazlo desde la pantalla de bienvenida."
        case .other(let m): m
        }
    }
}

/// Orquesta una grabación: captura del audio del sistema → transcripción en vivo → segmentos en SwiftData.
@MainActor @Observable final class RecordingSession {
    enum Phase: Equatable {
        case idle, starting, recording, paused, reconnecting, finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var liveText = ""
    private(set) var silentFor: TimeInterval = 0
    private(set) var lecture: Lecture?
    var startProblem: StartProblem?
    /// La clase que se acaba de finalizar, para la animación de «guardada». Se vacía sola al rato.
    private(set) var finished: Lecture?
    @ObservationIgnored private var finishedClear: Task<Void, Never>?

    /// Se llama al terminar, con la clase ya guardada, para lanzar el procesado con IA.
    @ObservationIgnored var onFinished: ((Lecture) -> Void)?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private let stats = OSAllocatedUnfairLock(initialState: LiveStats())
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var recordedBefore: TimeInterval = 0 // tiempo acumulado antes de la última pausa
    @ObservationIgnored private var runningSince: Date?
    /// Desfase que se suma a los tiempos de un transcriptor reiniciado (empieza otra vez en 0).
    @ObservationIgnored private var timeOffset: Double = 0
    /// Quién hablaba en cada momento (tiempo de audio), deducido de la pantalla.
    @ObservationIgnored private var speakerSamples: [(time: Double, name: String)] = []
    /// Términos vistos en pantalla durante la grabación y cuántas veces.
    @ObservationIgnored private var screenTermCounts: [String: Int] = [:]
    /// Términos fiables con los que se corrige la transcripción al vuelo (ver `TermFixer`).
    @ObservationIgnored private var fixTerms: [String] = []
    @ObservationIgnored private var speakerTask: Task<Void, Never>?
    @ObservationIgnored private var watchSpeakers = false
    @ObservationIgnored private var language: ClassLanguage = .spanish
    @ObservationIgnored private var draftSavedAt = Date.distantPast
    /// El último párrafo guardado, por si el siguiente trozo es su continuación. nil tras un hueco de audio.
    @ObservationIgnored private var lastParagraph: TranscriptSegment?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    /// Segundos de audio con los que se vuelve a intentar decidir el idioma (si no hubo voz suficiente).
    @ObservationIgnored private var detectAt = 25.0
    private static let detectGiveUp = 150.0

    var isActive: Bool { lecture != nil }

    /// Las ondas en este instante. No es observable a propósito: las vistas lo leen a su ritmo (TimelineView)
    /// sin redibujar toda la app 30 veces por segundo.
    func spectrum() -> [Float] {
        guard phase == .recording else { return [] }
        return stats.withLock { $0.bands }
    }

    init(context: ModelContext) { self.context = context }

    // MARK: Inicio

    /// Si falta el modelo del idioma, se descarga aquí mismo (la píldora aún no aparece: «Empezando…» en el botón).
    /// `hint`: título de la pestaña o reunión detectada, para adivinar la asignatura si no se eligió.
    func start(subject: Subject?, language: ClassLanguage = .spanish, hint: String? = nil) async {
        guard phase == .idle else { return }
        startProblem = nil
        finished = nil
        guard ScreenAudioPermission.isGranted else {
            ScreenAudioPermission.request()
            startProblem = .permission
            return
        }
        phase = .starting
        self.language = language

        stats.withLock { $0 = LiveStats(); $0.detecting = Prefs.autoLanguage }
        // Para detectar hace falta el modelo de cada idioma: los que falten se bajan en segundo plano.
        if Prefs.autoLanguage {
            Task.detached(priority: .background) { for l in ClassLanguage.allCases { try? await LiveTranscriber.installLanguage(l) } }
        }
        detectTask = nil
        detectAt = 25
        timeOffset = 0
        speakerSamples = []
        screenTermCounts = [:]
        let subjects = (try? context.fetch(FetchDescriptor<Subject>())) ?? []
        fixTerms = Prefs.vocabulary + subjects.map(\.name)
        watchSpeakers = SpeakerVision.isAvailable && Prefs.watchSpeakers && ProcessInfo.processInfo.environment["STUDYAI_NO_VISION"] == nil
        let transcriber = LiveTranscriber()
        let capture: SystemAudioCapture
        do {
            try await startTranscriber(transcriber)
            stats.withLock { $0.transcriber = transcriber }
            capture = try await makeCapture()
        } catch {
            await transcriber.cancel()
            phase = .idle
            startProblem = .other(error.localizedDescription)
            return
        }
        // Se pudo salir de la app o cancelar mientras arrancaba.
        guard phase == .starting else {
            await capture.stop()
            await transcriber.cancel()
            return
        }

        // La clase solo se crea cuando todo funciona: nunca queda una clase vacía seleccionada y borrada.
        let lecture = Lecture(title: "", subject: subject ?? Self.guessSubject(hint: hint, subjects: subjects, context: context))
        lecture.language = language
        context.insert(lecture)
        try? context.save()
        self.lecture = lecture
        self.transcriber = transcriber
        self.capture = capture

        recordedBefore = 0
        runningSince = .now
        phase = .recording
        startTicking()
        if watchSpeakers { startWatchingSpeakers() }
        RecordingIndicators.show(session: self)
    }

    /// Por el título de la pestaña o, si no, por el horario de las clases anteriores.
    static func guessSubject(hint: String?, subjects: [Subject], context: ModelContext, at date: Date = .now) -> Subject? {
        let names = subjects.map(\.name)
        if let hint, let name = SubjectGuess.byTitle(hint, subjects: names) { return subjects.first { $0.name == name } }
        let history = ((try? context.fetch(FetchDescriptor<Lecture>())) ?? []).compactMap { l in l.subject.map { (l.createdAt, $0.name) } }
        guard let name = SubjectGuess.bySchedule(date, history: history) else { return nil }
        return subjects.first { $0.name == name }
    }

    private func startTranscriber(_ transcriber: LiveTranscriber) async throws {
        let offset = timeOffset
        // La generación nueva solo se activa cuando el transcriptor ya arrancó: mientras tanto el anterior sigue contando.
        let gen = stats.withLock { $0.generation } + 1
        try await transcriber.start(
            language: language,
            onVolatile: { [stats] text in stats.withLock { if $0.generation == gen { $0.volatileText = text } } },
            onFinal: { [stats] s, e, text in
                stats.withLock { if $0.generation == gen { $0.pendingSegments.append((s + offset, e + offset, text)) } }
            },
            onFailure: { [stats] in stats.withLock { if $0.generation == gen { $0.transcriberFailed = true } } })
        stats.withLock { $0.generation = gen }
    }

    private func makeCapture() async throws -> SystemAudioCapture {
        let capture = SystemAudioCapture(wantsFrames: watchSpeakers)
        let spectrum = SpectrumAnalyzer() // solo se usa en la cola de audio
        capture.onBuffer = { [stats] buffer in
            guard !stats.withLock({ $0.paused }) else { return }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            // Todo lo que entra al transcriptor pasa por esta cola y en orden: primero lo pendiente de repetir.
            let (transcriber, replay) = stats.withLock { s -> (LiveTranscriber?, [AVAudioPCMBuffer]) in
                if s.detecting { s.pending.append(buffer); s.pendingSeconds += seconds }
                defer { s.replay = [] }
                return (s.transcriber, s.replay)
            }
            for b in replay { transcriber?.append(b) }
            transcriber?.append(buffer)
            spectrum.process(buffer)
            let rms = AudioLevel.rms(buffer)
            let bands = spectrum.bands
            stats.withLock {
                $0.level = rms
                $0.bands = bands
                $0.fedSeconds += seconds
                if rms > AudioLevel.silenceThreshold { $0.lastSound = .now }
            }
        }
        capture.onStop = { [weak self, weak capture] error in
            Task { @MainActor in
                guard let self, let capture, capture === self.capture else { return }
                await self.captureStopped(error)
            }
        }
        try await capture.start()
        return capture
    }

    // MARK: Pausa

    func pause() {
        guard phase == .recording else { return }
        stats.withLock { $0.paused = true }
        freezeClock()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        stats.withLock { $0.paused = false }
        resumeClock()
        phase = .recording
    }

    private func freezeClock() {
        recordedBefore = elapsed
        runningSince = nil
    }

    private func resumeClock() {
        stats.withLock { $0.lastSound = .now }
        runningSince = .now
    }

    // MARK: Fin

    /// Idempotente: si ya se está terminando, espera a que acabe (p. ej. Finalizar y luego ⌘Q).
    func finish() async {
        if let finishTask { return await finishTask.value }
        guard lecture != nil else {
            if phase == .starting { phase = .idle } // el arranque en curso se descarta solo
            return
        }
        let task = Task { await performFinish() }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func performFinish() async {
        guard let lecture else { return }
        if runningSince != nil { freezeClock() }
        phase = .finishing
        tick?.cancel()
        speakerTask?.cancel()
        detectTask?.cancel()
        await capture?.stop()
        // El audio pendiente de repetir tras un cambio de idioma solo sale con el siguiente buffer en vivo:
        // si se finaliza en pausa o justo después, se pasa aquí para no perder el principio de la clase.
        let replay = stats.withLock { s in defer { s.replay = [] }; return s.replay }
        for b in replay { transcriber?.append(b) }
        await transcriber?.finish()
        drainSegments()

        lecture.duration = elapsed
        lecture.liveDraft = nil
        let speakers = Set(lecture.segments.compactMap(\.speaker))
        lecture.screenTerms = Array(speakers) + screenTermCounts.filter { $0.value >= 2 && !speakers.contains($0.key) }
            .sorted { $0.value > $1.value }.prefix(40).map(\.key)
        let hasSpeech = lecture.segments.contains { !$0.isGap }
        lecture.status = hasSpeech ? .processing : .transcriptOnly
        if !hasSpeech {
            lecture.processingError = "No se detectó voz en el audio del sistema. ¿Estaba sonando la clase?"
        }
        try? context.save()
        reset()
        finishedClear?.cancel()
        finished = lecture
        RecordingIndicators.finished()
        finishedClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.finished = nil
        }
        onFinished?(lecture)
    }

    private func reset() {
        speakerTask = nil
        speakerSamples = []
        lastParagraph = nil
        capture = nil
        transcriber = nil
        lecture = nil
        phase = .idle
        elapsed = 0
        level = 0
        liveText = ""
        silentFor = 0
        runningSince = nil
    }

    // MARK: Fallos y reconexión

    private func captureStopped(_ error: Error) async {
        guard lecture != nil, phase != .finishing else { return }
        capture = nil
        if error.isUserStoppedCapture {
            await finish()
        } else {
            NSLog("StudyAI: captura detenida: \(error)")
            await reconnect()
        }
    }

    /// Solo para el guion de pruebas (`--script drop@N`): corta la captura como si macOS la hubiera detenido.
    func simulateCaptureLoss() async {
        guard let capture, phase == .recording || phase == .paused else { return }
        await capture.stop()
        await captureStopped(NSError(domain: "StudyAI.prueba", code: 1, userInfo: [NSLocalizedDescriptionKey: "corte simulado"]))
    }

    /// Reintento manual desde la píldora.
    func retry() async {
        guard lecture != nil, case .failed = phase else { return }
        if stats.withLock({ $0.transcriberFailed }) {
            await restartPipeline()
        } else {
            await reconnect()
        }
    }

    /// Reintenta la captura con espera creciente y deja una marca de hueco en la transcripción.
    private func reconnect() async {
        let lostAt = Date()
        let wasPaused = stats.withLock { $0.paused }
        if runningSince != nil { freezeClock() }
        phase = .reconnecting
        let gapAt = stats.withLock { $0.fedSeconds } + timeOffset
        for delay in [1, 2, 4, 8, 16] {
            try? await Task.sleep(for: .seconds(delay))
            guard lecture != nil, phase == .reconnecting, let transcriber else { return }
            do {
                _ = transcriber
                let capture = try await makeCapture()
                guard lecture != nil, phase == .reconnecting else { await capture.stop(); return }
                self.capture = capture
                let lost = Int(Date().timeIntervalSince(lostAt))
                addSegment(start: gapAt, end: gapAt, text: "audio interrumpido unos \(lost) s", isGap: true)
                if wasPaused { phase = .paused } else { resumeClock(); phase = .recording }
                return
            } catch {
                NSLog("StudyAI: reintento de captura fallido: \(error)")
            }
        }
        phase = .failed("Se perdió el audio del sistema. Lo transcrito hasta ahora está guardado.")
    }

    /// El transcriptor falló: se cierra lo que haya y se arranca otro, con los tiempos desplazados.
    private func restartPipeline() async {
        phase = .reconnecting
        await capture?.stop()
        capture = nil
        await transcriber?.cancel()
        drainSegments()
        // Tras un reinicio ya no se puede repetir el audio del principio: la detección se da por cerrada.
        timeOffset += stats.withLock { s in
            defer { s.fedSeconds = 0; s.transcriberFailed = false; s.detecting = false; s.pending = [] }
            return s.fedSeconds
        }
        let gapAt = timeOffset
        let transcriber = LiveTranscriber()
        do {
            try await startTranscriber(transcriber)
            stats.withLock { $0.transcriber = transcriber }
            let capture = try await makeCapture()
            guard lecture != nil, phase == .reconnecting else { await capture.stop(); await transcriber.cancel(); return }
            self.transcriber = transcriber
            self.capture = capture
            addSegment(start: gapAt, end: gapAt, text: "la transcripción se reinició", isGap: true)
            stats.withLock { $0.paused = false }
            resumeClock()
            phase = .recording
        } catch {
            await transcriber.cancel()
            phase = .failed("La transcripción no se pudo reanudar: \(error.localizedDescription)")
        }
    }

    // MARK: Refresco de la interfaz y persistencia

    /// Cada 3 s mira la pantalla, y solo la vuelve a leer si ha cambiado: si no, repite el último nombre.
    /// Leerla tarda unas décimas y nunca bloquea la grabación; un fallo solo deja el párrafo sin nombre.
    private func startWatchingSpeakers() {
        speakerTask = Task { [weak self] in
            var lastCount = -1
            var lastName: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.phase == .recording, let frame = self.capture?.latestFrame, let image = frame.image else { continue }
                let at = self.stats.withLock { $0.fedSeconds } + self.timeOffset
                if frame.count != lastCount {
                    lastCount = frame.count
                    let reading = await SpeakerVision.read(image)
                    lastName = reading.speaker
                    for t in reading.terms { self.screenTermCounts[t, default: 0] += 1 }
                    // Los que ya se han visto dos veces y tienen forma propia (SharePoint, Digital Brains) corrigen la transcripción.
                    let fresh = reading.terms.filter { t in
                        self.screenTermCounts[t] == 2 && (t.contains(" ") || t.dropFirst().contains(where: \.isUppercase))
                    }
                    if let name = reading.speaker, !self.fixTerms.contains(name) { self.fixTerms.append(name) }
                    self.fixTerms += fresh
                }
                if let lastName { self.speakerSamples.append((at, lastName)) }
            }
        }
    }

    private func startTicking() {
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Solo asigna lo que cambia: cada asignación redibuja las vistas que lo observan.
    private func refresh() {
        if let runningSince {
            let e = (recordedBefore + Date().timeIntervalSince(runningSince)).rounded(.down)
            if e != elapsed { elapsed = e }
        }
        let s = stats.withLock { $0 }
        let newLevel = phase == .recording ? s.level : 0
        if abs(newLevel - level) > 0.0005 { level = newLevel }
        if s.volatileText != liveText { liveText = s.volatileText }
        let silent = phase == .recording ? Date().timeIntervalSince(s.lastSound).rounded(.down) : 0
        if silent != silentFor { silentFor = silent }
        drainSegments()
        saveDraft(s.volatileText)
        if s.detecting, s.pendingSeconds >= detectAt, detectTask == nil { detectLanguage() }

        if s.transcriberFailed, phase == .recording || phase == .paused {
            freezeClock()
            phase = .failed("La transcripción se detuvo. Pulsa reintentar para seguir.")
            Task { await capture?.stop(); capture = nil }
        }
    }

    // MARK: Idioma

    /// Con 25 s de clase decide el idioma. Si no es el que se supuso, arranca un transcriptor en el bueno,
    /// le pasa el audio guardado desde el principio y tira lo transcrito en el idioma equivocado.
    private func detectLanguage() {
        let audio = stats.withLock { $0.pending }
        detectTask = Task { [weak self] in
            let detected = await LanguageDetector.detect(audio)
            guard let self, !Task.isCancelled else { return }
            await self.switchLanguage(to: detected)
        }
    }

    private func switchLanguage(to detected: ClassLanguage?) async {
        guard let lecture, phase == .recording || phase == .paused, stats.withLock({ $0.detecting }) else { return }
        guard let detected else {
            // Sin voz suficiente (sala de espera, música de entrada) o sin el modelo del otro idioma todavía:
            // se vuelve a probar con 25 s más de audio, hasta un tope.
            let heard = stats.withLock { $0.pendingSeconds }
            if heard < Self.detectGiveUp {
                detectAt = heard + 25
                detectTask = nil
            } else {
                stats.withLock { $0.detecting = false; $0.pending = [] }
            }
            return
        }
        guard detected != language else {
            stats.withLock { $0.detecting = false; $0.pending = [] }
            return
        }
        NSLog("StudyAI: la clase es en \(detected.name), cambio de idioma")
        let previous = language
        language = detected
        let fresh = LiveTranscriber()
        let oldGeneration = stats.withLock { $0.generation }
        // Si el cambio falla o mientras tanto se finalizó la clase, el transcriptor de antes sigue siendo el bueno.
        func keepOld() async {
            language = previous
            stats.withLock { $0.generation = oldGeneration; $0.detecting = false; $0.pending = [] }
            await fresh.cancel()
        }
        do {
            try await startTranscriber(fresh)
        } catch {
            NSLog("StudyAI: no se pudo cambiar de idioma: \(error)")
            await keepOld()
            return
        }
        guard !Task.isCancelled, self.lecture === lecture, phase == .recording || phase == .paused else {
            await keepOld()
            return
        }
        lecture.language = detected
        for s in lecture.segments { context.delete(s) }
        lastParagraph = nil
        lecture.liveDraft = nil
        let old = stats.withLock { s -> LiveTranscriber? in
            defer {
                s.transcriber = fresh
                s.replay = s.pending
                s.pending = []
                s.detecting = false
                s.pendingSegments = []
                s.volatileText = ""
            }
            return s.transcriber
        }
        transcriber = fresh
        try? context.save()
        await old?.cancel()
    }

    private func drainSegments() {
        guard lecture != nil else { return }
        let pending = stats.withLock { s in defer { s.pendingSegments = [] }; return s.pendingSegments }
        guard !pending.isEmpty else { return }
        // El borrador era justo este texto: se quita en el mismo guardado para que no quede duplicado.
        lecture?.liveDraft = nil
        for p in pending { addSegment(start: p.start, end: p.end, text: p.text) }
    }

    private func saveDraft(_ text: String) {
        guard let lecture, Date().timeIntervalSince(draftSavedAt) >= 5 else { return }
        let draft = text.isEmpty ? nil : text
        guard draft != lecture.liveDraft else { return }
        lecture.liveDraft = draft
        lecture.duration = elapsed // para que, tras un cuelgue, la duración sea la real y no la del último párrafo
        draftSavedAt = .now
        try? context.save()
    }

    /// Cada segmento se guarda al momento: si la app se cierra, lo transcrito no se pierde.
    private func addSegment(start: Double, end: Double, text: String, isGap: Bool = false) {
        guard let lecture else { return }
        let speaker = isGap ? nil : SpeakerVision.speaker(from: speakerSamples, start: start, end: end)
        let text = isGap ? text : TermFixer.fix(text, terms: fixTerms)
        // Un resultado corto del reconocedor continúa el párrafo anterior en lugar de abrir otro.
        if !isGap, let last = lastParagraph, last.absorb(start: start, end: end, text: text, speaker: speaker) {
            try? context.save()
            return
        }
        let segment = TranscriptSegment(start: start, end: end, text: text, isGap: isGap)
        segment.speaker = speaker
        segment.lecture = lecture
        context.insert(segment)
        lastParagraph = isGap ? nil : segment
        try? context.save()
    }
}
