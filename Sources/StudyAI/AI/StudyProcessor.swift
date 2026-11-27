import Security
import Foundation
import FoundationModels
import StudyAICore

@Generable struct BlockNotes {
    @Guide(description: "Título breve del tema que trata este fragmento de la clase")
    var title: String
    @Guide(description: "Ideas clave explicadas por el profesor: frases completas y concretas que se entienden solas, con el dato, la definición o el ejemplo", .count(3...7))
    var keyPoints: [String]
    @Guide(description: "Conceptos o términos técnicos importantes de este fragmento, con su definición", .maximumCount(5))
    var terms: [Term]
    @Guide(description: "Avisos prácticos del profesor en este fragmento, con su fecha si la dice: entregas de actividades, fechas de examen, qué preparar para la próxima clase, qué entra o cae en el examen. Lista vacía si no da ninguno", .maximumCount(4))
    var reminders: [String]
}

/// Los mismos apuntes con más margen, para los bloques grandes que se mandan a un proveedor externo.
@Generable struct BlockNotesLarge {
    @Guide(description: "Título breve del tema que trata este fragmento de la clase")
    var title: String
    @Guide(description: "Ideas clave explicadas por el profesor: frases completas y concretas que se entienden solas, con el dato, la definición o el ejemplo", .count(4...12))
    var keyPoints: [String]
    @Guide(description: "Conceptos o términos técnicos importantes de este fragmento, con su definición", .maximumCount(8))
    var terms: [Term]
    @Guide(description: "Avisos prácticos del profesor en este fragmento, con su fecha si la dice: entregas de actividades, fechas de examen, qué preparar para la próxima clase, qué entra o cae en el examen. Lista vacía si no da ninguno", .maximumCount(5))
    var reminders: [String]

    var notes: BlockNotes { BlockNotes(title: title, keyPoints: keyPoints, terms: terms, reminders: reminders) }
}

@Generable struct ReviewCard {
    @Guide(description: "Pregunta de repaso tipo examen sobre el contenido de la clase, sin mencionar la transcripción ni los apuntes")
    var question: String
    @Guide(description: "Respuesta correcta y breve (1 o 2 frases), según lo explicado en la clase")
    var answer: String
}

@Generable struct Term {
    var term: String
    @Guide(description: "Definición breve, según lo dicho en la clase")
    var definition: String
}

@Generable struct DigestSection {
    @Guide(description: "Nombre del tema, de 2 a 6 palabras")
    var title: String
    @Guide(description: "Lo esencial del tema en frases cortas que se entienden solas: qué es, requisitos, tipos, consecuencias o ejemplos. Sin repetir el título", .count(2...5))
    var points: [String]
}

@Generable struct DigestSections {
    @Guide(description: "Temas de la clase en el orden en que se explicaron, sin repetir ninguno", .count(2...5))
    var sections: [DigestSection]
}

@Generable struct DigestOverview {
    @Guide(description: "Título corto de la clase (3 a 8 palabras) que diga de qué trata, sin la palabra «clase»")
    var title: String
    @Guide(description: "De qué trató la clase y qué hay que llevarse de ella, en 2 o 3 frases directas. Sin fórmulas como «en esta clase» o «el profesor explica»")
    var overview: String
    @Guide(description: "Preguntas de repaso con su respuesta", .count(5))
    var review: [ReviewCard]
}

@Generable enum ChatAction {
    /// Solo pregunta.
    case none
    /// Pide añadir o ampliar algo en el resumen de la clase.
    case addToSummary
    /// Pide apuntar algo en sus notas personales.
    case addToNotes
}

@Generable struct ChatTurn {
    @Guide(description: "none si solo pregunta o conversa; addToSummary si pide añadir o ampliar algo en el resumen; addToNotes si pide apuntar algo en sus notas")
    var action: ChatAction
    @Guide(description: "Respuesta a la estudiante, clara y breve")
    var answer: String
}

struct ChatReply {
    var action: ChatAction
    var answer: String
    /// Lo que se añade al resumen o a las notas. Vacío si solo era una pregunta.
    var addition: String
}

enum AIAvailability: Equatable {
    case ready
    case unavailable(String)

    static var current: AIAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let spanish = model.supportedLanguages.contains { $0.languageCode?.identifier == "es" }
            return spanish ? .ready : .unavailable("El modelo de Apple Intelligence no admite español en este Mac.")
        case .unavailable(.deviceNotEligible):
            return .unavailable("Este Mac no es compatible con Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Activa Apple Intelligence en Ajustes del Sistema para generar resúmenes y apuntes.")
        case .unavailable(.modelNotReady):
            return .unavailable("Apple Intelligence se está descargando. Vuelve a intentarlo en unos minutos.")
        case .unavailable:
            return .unavailable("Apple Intelligence no está disponible ahora mismo.")
        }
    }
}

/// Qué modelo escribe los apuntes y el resumen. El chat siempre va con el del Mac.
enum AIEngine: String, CaseIterable {
    /// El modelo de Apple en el propio Mac: privado y sin conexión.
    case local
    /// El modelo grande de Apple en Private Cloud Compute (macOS 27; la app necesita el permiso de Apple).
    case appleCloud
    /// Un proveedor compatible con la API de OpenAI (Groq u otro), con la clave de la usuaria.
    case external

    static let key = "aiEngine"
    static var selected: AIEngine { AIEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .local }

    var title: String {
        switch self {
        case .local: "En este Mac"
        case .appleCloud: "Apple en la nube"
        case .external: "Otro proveedor"
        }
    }

    /// El elegido, o el del Mac si al elegido le falta algo (sistema antiguo, sin clave).
    static var usable: AIEngine {
        switch selected {
        case .local: .local
        case .appleCloud: appleCloudAvailable ? .appleCloud : .local
        case .external: CloudLLM.config == nil ? .local : .external
        }
    }

    static var appleCloudAvailable: Bool {
        guard #available(macOS 27, *), hasCloudEntitlement else { return false }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    /// Sin el permiso gestionado de Apple, FoundationModels cierra la app de golpe (fatalError) al primer uso
    /// del modelo en la nube, aunque `isAvailable` diga que sí. Se mira la firma de la propia app.
    static let hasCloudEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        return (value as? Bool) == true
    }()
}

/// Convierte una transcripción en apuntes, resumen y preguntas.
/// La ventana del modelo del Mac es pequeña (4k-8k tokens): map (apuntes por bloque) → reduce (temas → idea central).
enum StudyAI {
    /// La ventana del modelo del Mac: 4.096 tokens en macOS 26, 8.192 desde macOS 27.
    static let largeLocalContext: Bool = { if #available(macOS 27, *) { true } else { false } }()

    /// Por bloque: ~1.700 tokens de español con ventana de 8k, ~1.100 con la de 4k (más instrucciones,
    /// esquema, material y respuesta). Se mantiene también con modelos mayores: bloques cortos dan apuntes más densos.
    static let blockChars = largeLocalContext ? 6_000 : 4_000

    /// Cuánto texto de apuntes cabe al escribir el resumen.
    /// Con el modelo del Mac, tandas cortas: cada una da de 2 a 5 temas y así una clase larga sale bien desglosada.
    /// Con un proveedor externo, ~3.500 tokens: la capa gratuita de Groq no admite más de 8.000 por minuto
    /// contando instrucciones y respuesta, y una petición mayor se rechaza entera.
    static func digestChars(_ engine: AIEngine) -> Int {
        switch engine {
        case .local: blockChars
        case .external: 12_000
        case .appleCloud: 24_000
        }
    }

    /// Tope de respuesta y poca temperatura: sin tope, el modelo del Mac a veces se desboca hasta llenar su ventana.
    static let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: largeLocalContext ? 1_600 : 1_000)

    /// Se escribe en el idioma de la clase: unos apuntes de una asignatura en inglés, en inglés.
    static func instructions(_ language: ClassLanguage) -> String {
        """
        Eres un asistente de estudio para una estudiante universitaria. Trabajas con transcripciones \
        automáticas de clases grabadas, en \(language.inPrompt), que pueden contener errores de reconocimiento. \
        Usa solo la información de la transcripción y del material de la clase, no inventes datos. \
        Ve al grano: recoge lo que hace falta para estudiar (conceptos, definiciones, clasificaciones, requisitos, \
        ejemplos, artículos o cifras que cite el profesor) y deja fuera saludos, problemas técnicos, comentarios \
        sobre la plataforma y muletillas. Escribe siempre en \(language.inPrompt).
        """
    }

    struct Output {
        var notesMarkdown: String
        /// nil si los apuntes salieron pero el resumen final falló: no se tiran los apuntes por ello.
        var summary: String?
        var reviewQuestions: [String]
        var reviewAnswers: [String]
        var title: String?
        var skippedBlocks: Int
        /// Por qué se acabó usando el modelo del Mac si se había elegido otro. nil si no hizo falta.
        var fallbackReason: String?
    }

    /// Modelo en uso durante un procesado. Si el de la nube falla una vez, el resto sigue con el del Mac.
    final class Run: @unchecked Sendable {
        var engine: AIEngine
        var fallbackReason: String?
        var terms: [String] = []
        init(_ engine: AIEngine) { self.engine = engine }
    }

    /// `material`: texto de las diapositivas o del PDF de la clase que acompaña a cada bloque (vacío si no hay).
    /// `terms`: palabras que el reconocedor suele oír mal (vocabulario, asignatura, lo que se vio en pantalla).
    /// `engine`: para forzar el modelo del Mac aunque haya otro elegido.
    static func process(transcript: String, language: ClassLanguage = .spanish, material: (String) -> String = { _ in "" },
                        terms: [String] = [], engine: AIEngine? = nil,
                        progress: @escaping @MainActor (Double, String) -> Void) async throws -> Output {
        let run = Run(engine ?? AIEngine.usable)
        run.terms = terms
        // Con un proveedor externo, bloques el doble de grandes: las instrucciones y el esquema se mandan una vez
        // por bloque, así que con menos bloques se gasta menos cupo. Si cae al modelo del Mac, se parten solos.
        let blocks = Chunker.chunk(transcript, maxChars: run.engine == .external ? 12_000 : blockChars)
        guard !blocks.isEmpty else { throw ProcessingError.emptyTranscript }

        var notes: [BlockNotes] = []
        var skipped = 0
        for (i, block) in blocks.enumerated() {
            try Task.checkCancellation()
            await progress(Double(i) / Double(blocks.count + 2), "Generando apuntes: bloque \(i + 1) de \(blocks.count)")
            if let n = try await notesWithSplit(block, material: material(block), language: language, run: run) {
                notes.append(contentsOf: n)
            } else {
                skipped += 1
            }
        }
        guard !notes.isEmpty else { throw ProcessingError.allBlocksRejected }

        await progress(Double(blocks.count) / Double(blocks.count + 2), "Escribiendo el resumen")
        // Temas: si el modelo falla en una tanda, se usan los apuntes de esa parte tal cual. El resumen nunca queda en blanco.
        let sections = try await self.sections(of: notes, language: language, run: run)
        await progress(Double(blocks.count + 1) / Double(blocks.count + 2), "Escribiendo la idea central y las preguntas")
        var overview: DigestOverview?
        for _ in 0..<2 where overview == nil {
            do {
                overview = try await self.overview(of: sections, language: language, run: run)
            } catch is CancellationError {
                throw CancellationError()
            } catch CloudError.dailyQuota(let until) {
                throw CloudError.dailyQuota(until)
            } catch {
                NSLog("StudyAI: la idea central falló: \(error)")
            }
        }
        let summary = summaryMarkdown(overview: overview?.overview ?? "", sections: sections, reminders: notes.flatMap(\.reminders))
        await progress(1, "Listo")

        return Output(notesMarkdown: markdown(notes), summary: summary.isEmpty ? nil : summary,
                      reviewQuestions: overview?.review.map(\.question) ?? [], reviewAnswers: overview?.review.map(\.answer) ?? [],
                      title: overview?.title,
                      skippedBlocks: skipped, fallbackReason: run.fallbackReason)
    }

    /// Si un bloque no cabe en la ventana, se parte en dos. Cualquier otro rechazo del modelo omite solo ese bloque.
    private static func notesWithSplit(_ block: String, material: String, language: ClassLanguage, run: Run, depth: Int = 0) async throws -> [BlockNotes]? {
        do {
            var prompt = "Toma apuntes de este fragmento de la clase:\n\n\(block)"
            if !material.isEmpty { prompt += "\n\nMaterial de la clase que acompaña a este fragmento (diapositivas o documento), para afinar nombres y datos:\n\n\(material)" }
            if !run.terms.isEmpty {
                prompt += "\n\nLa transcripción automática oye mal nombres propios y términos técnicos. Si aparece algo parecido a uno de estos, escríbelo así: \(run.terms.prefix(60).joined(separator: ", "))."
            }
            if run.engine == .external { return [try await respond(prompt, as: BlockNotesLarge.self, language: language, run: run).notes] }
            return [try await respond(prompt, as: BlockNotes.self, language: language, run: run)]
        } catch let error as LanguageModelSession.GenerationError {
            // No cabe en la ventana, o los filtros del modelo lo rechazan: se parte en dos y se reintenta.
            // Así un rechazo se queda en el trozo pequeño que lo provoca y no se pierde el bloque entero.
            var splittable = isSafetyRefusal(error)
            if case .exceededContextWindowSize = error { splittable = true }
            guard splittable, depth < 2, block.count > 600 else {
                NSLog("StudyAI: bloque omitido: \(error)")
                return nil
            }
            let halves = Chunker.chunk(block, maxChars: block.count / 2 + 1)
            var out: [BlockNotes] = []
            // El material se deja fuera al partir: lo que no cabía era la suma.
            for h in halves { out += try await notesWithSplit(h, material: "", language: language, run: run, depth: depth + 1) ?? [] }
            return out.isEmpty ? nil : out
        }
    }

    typealias Section = (title: String, points: [String])

    /// Agrupa los apuntes en los temas de la clase, por tandas en orden.
    private static func sections(of notes: [BlockNotes], language: ClassLanguage, run: Run) async throws -> [Section] {
        // Tandas de apuntes enteros (no se parte un bloque por la mitad) que caben en una petición.
        var groups: [[BlockNotes]] = []
        var size = 0
        for n in notes {
            let chars = line(n).count
            if groups.isEmpty || size + chars > digestChars(run.engine) { groups.append([]); size = 0 }
            groups[groups.count - 1].append(n)
            size += chars
        }
        var out: [Section] = []
        for (i, group) in groups.enumerated() {
            let part = groups.count == 1 ? "una clase" : "la parte \(i + 1) de \(groups.count) de una clase"
            let prompt = """
                Estos son los apuntes de \(part), en orden:

                \(group.map(line).joined(separator: "\n"))

                Agrúpalos en temas y, de cada uno, escribe lo esencial en puntos concretos. \
                No dejes fuera definiciones, requisitos, clasificaciones, plazos ni ejemplos importantes. \
                Cada punto dice una cosa distinta: no repitas ideas ni escribas lo que la clase no trata. \
                Deja fuera los avisos de entregas, fechas y la organización de la clase: van en otro apartado.
                """
            var made: [Section]?
            for _ in 0..<2 where made == nil {
                try Task.checkCancellation()
                do {
                    made = try await respond(prompt, as: DigestSections.self, language: language, run: run).sections.map { ($0.title, $0.points) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch CloudError.dailyQuota(let until) {
                    throw CloudError.dailyQuota(until)
                } catch {
                    NSLog("StudyAI: los temas de la parte \(i + 1) fallaron: \(error)")
                }
            }
            out += made ?? group.map { ($0.title, Array($0.keyPoints.prefix(4))) }
        }
        return out
    }

    private static func line(_ n: BlockNotes) -> String {
        "\(n.title): " + n.keyPoints.joined(separator: " | ")
    }

    private static func overview(of sections: [Section], language: ClassLanguage, run: Run) async throws -> DigestOverview {
        let text = sections.map { "\($0.title): " + $0.points.joined(separator: "; ") }.joined(separator: "\n")
        func ask(_ limit: Int) async throws -> DigestOverview {
            try await respond("""
                Estos son los temas de una clase, en orden:

                \(text.prefix(limit))

                Escribe el título, la idea central y preguntas de repaso con su respuesta.
                """, as: DigestOverview.self, language: language, run: run)
        }
        do {
            return try await ask(digestChars(run.engine))
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await ask(digestChars(run.engine) / 2) // no cabía: con la mitad de los temas
        }
    }

    /// El resumen en Markdown: idea central, un apartado por tema y, si los hubo, los avisos del profesor.
    /// Mismo formato que los apuntes («### título», «- punto») para pintarlo y exportarlo igual.
    static func summaryMarkdown(overview: String, sections: [Section], reminders: [String]) -> String {
        var parts: [String] = [overview.trimmingCharacters(in: .whitespacesAndNewlines)]
        var kept: [Set<String>] = []
        for s in sections {
            // Fuera los puntos de relleno y los que repiten otro ya dicho (el modelo pequeño se repite).
            let points = s.points.filter { point in
                let words = Set(Retriever.words(point))
                guard words.count >= 2, !point.lowercased().contains("no se menciona"), point.components(separatedBy: " = ").count < 3 else { return false }
                guard !kept.contains(where: { Double($0.intersection(words).count) >= 0.75 * Double(min($0.count, words.count)) }) else { return false }
                kept.append(words)
                return true
            }
            if !points.isEmpty { parts.append("### \(s.title)\n" + points.map { "- \($0)" }.joined(separator: "\n")) }
        }
        var seen = Set<String>()
        let unique = reminders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(8)
        if !unique.isEmpty { parts.append("### Para recordar\n" + unique.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Una petición con el modelo del procesado. Si el de la nube falla, se anota el motivo y se sigue con el del Mac.
    private static func respond<T: Generable>(_ prompt: String, as type: T.Type, language: ClassLanguage, run: Run) async throws -> T {
        if run.engine != .local {
            do {
                return try await cloudRespond(prompt, as: type, language: language, engine: run.engine)
            } catch is CancellationError {
                throw CancellationError()
            } catch CloudError.dailyQuota(let until) {
                throw CloudError.dailyQuota(until) // se deja pendiente: mejor esperar al proveedor que un resumen peor
            } catch {
                NSLog("StudyAI: el modelo en la nube falló, sigo con el del Mac: \(error)")
                run.fallbackReason = error.localizedDescription
                run.engine = .local
            }
        }
        return try await respond(prompt, as: type, language: language)
    }

    static func cloudRespond<T: Generable>(_ prompt: String, as type: T.Type, language: ClassLanguage, engine: AIEngine) async throws -> T {
        if engine == .appleCloud {
            // Nunca sin el permiso: sin él, el sistema cierra la app en vez de devolver un error.
            guard AIEngine.appleCloudAvailable else { throw CloudError.notConfigured }
        }
        if engine == .appleCloud, #available(macOS 27, *) {
            let text = instructions(language)
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel()) { text }
            return try await session.respond(to: prompt, generating: type, options: options).content
        }
        guard let config = CloudLLM.config else { throw CloudError.notConfigured }
        // El mismo esquema que usa el modelo de Apple, como JSON Schema, y la respuesta se lee con el mismo tipo.
        let schema = String(data: try JSONEncoder().encode(T.generationSchema), encoding: .utf8) ?? "{}"
        let system = instructions(language) + "\n\nResponde solo con un objeto JSON que cumpla este esquema:\n" + schema
        // De vez en cuando el modelo devuelve el objeto dentro de ```json, en una lista o sin un campo: se pide otra vez.
        var lastError: Error = CloudError.emptyAnswer
        for _ in 0..<3 {
            let shape = (try? JSONSerialization.jsonObject(with: try JSONEncoder().encode(T.generationSchema))) as? [String: Any]
            let text: String
            do {
                text = try await CloudLLM.chat(system: system, user: prompt, config: config, schema: shape)
            } catch CloudError.badGeneration {
                lastError = CloudError.badGeneration
                continue
            }
            do {
                return try T(GeneratedContent(json: CloudLLM.jsonObject(in: text)))
            } catch {
                NSLog("StudyAI: respuesta del proveedor sin el formato pedido (\(Swift.type(of: error)), \(text.count) caracteres)")
                lastError = error
            }
        }
        throw lastError
    }

    /// El modelo del Mac con los filtros pensados para transformar texto ajeno (resumir, tomar apuntes):
    /// con los de por defecto se negaba a resumir clases de Derecho que hablan de violencia, dolo o intimidación.
    static let localModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// Una sesión nueva por petición. Si el sistema limita (app en segundo plano, otra app usando el modelo), espera y reintenta.
    private static func respond<T: Generable>(_ prompt: String, as type: T.Type, language: ClassLanguage) async throws -> T {
        var delay = 5
        while true {
            try Task.checkCancellation()
            do {
                let session = LanguageModelSession(model: localModel, instructions: instructions(language))
                return try await session.respond(to: prompt, generating: type, options: options).content
            } catch LanguageModelSession.GenerationError.rateLimited where delay <= 40 {
            } catch LanguageModelSession.GenerationError.concurrentRequests where delay <= 40 {
            } catch let error as LanguageModelSession.GenerationError {
                // Los filtros permisivos solo se aplican del todo a respuestas de texto: si la respuesta guiada
                // se rechaza, se pide lo mismo como JSON en texto y se lee con el mismo tipo.
                guard isSafetyRefusal(error), let value = try? await respondAsText(prompt, as: type, language: language) else { throw error }
                return value
            }
            try await Task.sleep(for: .seconds(delay))
            delay *= 2
        }
    }

    private static func isSafetyRefusal(_ error: LanguageModelSession.GenerationError) -> Bool {
        switch error {
        case .guardrailViolation, .refusal: true
        default: false
        }
    }

    private static func respondAsText<T: Generable>(_ prompt: String, as type: T.Type, language: ClassLanguage) async throws -> T {
        let schema = String(data: try JSONEncoder().encode(T.generationSchema), encoding: .utf8) ?? "{}"
        let system = instructions(language) + "\n\nResponde solo con un objeto JSON, sin texto alrededor, que cumpla este esquema:\n" + schema
        let text = try await LanguageModelSession(model: localModel, instructions: system).respond(to: prompt, options: options).content
        // El modelo a veces envuelve el JSON en un bloque de código.
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { throw ProcessingError.allBlocksRejected }
        return try T(GeneratedContent(json: String(text[open...close])))
    }

    static func markdown(_ notes: [BlockNotes]) -> String {
        notes.map { n in
            var s = "### \(n.title)\n\n" + n.keyPoints.map { "- \($0)" }.joined(separator: "\n")
            if !n.terms.isEmpty {
                s += "\n\n" + n.terms.map { "- **\($0.term)**: \($0.definition)" }.joined(separator: "\n")
            }
            return s
        }.joined(separator: "\n\n")
    }

    /// Chat sobre la clase: responde usando los fragmentos más relevantes de la transcripción y, si Ana lo pide,
    /// propone un texto para añadir al resumen o a sus notas (la app lo aplica y deja deshacerlo).
    /// `history`: los últimos turnos, para entender «explícamelo mejor» o «añade eso».
    static func chat(_ message: String, history: [(fromUser: Bool, text: String)], transcript: String, summary: String?,
                     language: ClassLanguage, terms: [String] = []) async throws -> ChatReply {
        let chunks = Chunker.chunk(transcript, maxChars: 1_200)
        let recent = history.suffix(4)
        let context = Retriever.top(chunks, for: message + " " + recent.map(\.text).joined(separator: " "), k: 3)
        var prompt = ""
        if let summary, !summary.isEmpty { prompt += "Resumen actual de la clase:\n\(summary.prefix(1_500))\n\n" }
        if !context.isEmpty { prompt += "Fragmentos de la transcripción:\n" + context.joined(separator: "\n---\n") + "\n\n" }
        if !recent.isEmpty {
            prompt += "Conversación hasta ahora:\n" + recent.map { "\($0.fromUser ? "Estudiante" : "Asistente"): \($0.text.prefix(400))" }
                .joined(separator: "\n") + "\n\n"
        }
        if !terms.isEmpty { prompt += "Así se escriben los nombres y términos de esta clase (la transcripción puede traerlos mal): \(terms.prefix(40).joined(separator: ", ")).\n\n" }
        prompt += "Mensaje de la estudiante: \(message)\n\nResponde de forma clara y breve. Si la clase no trata el tema, dilo."
        let turn = try await respond(prompt, as: ChatTurn.self, language: language)
        guard turn.action != .none else { return ChatReply(action: .none, answer: turn.answer, addition: "") }
        // Segundo paso: el modelo pequeño mezcla «respuesta» y «texto a añadir» si se piden a la vez.
        let target = turn.action == .addToSummary ? "el resumen de la clase" : "las notas personales de la estudiante"
        let addition = try await respond("""
            \(prompt.components(separatedBy: "Mensaje de la estudiante:").first ?? "")\
            La estudiante pide: \(message)

            Escribe solo el párrafo que se añadirá a \(target), basado en la clase. Sin introducciones ni comentarios.
            """, as: String.self, language: language)
        return ChatReply(action: turn.action, answer: turn.answer, addition: addition)
    }
}

extension StudyAI {
    /// Pregunta sobre varias clases a la vez (toda una asignatura), con el modelo del Mac.
    /// `fragments` ya vienen con su clase y minuto; la respuesta los cita como [1], [2]…
    static func answer(_ question: String, fragments: [String], language: ClassLanguage, terms: [String]) async throws -> String {
        var prompt = "Fragmentos de las clases de la asignatura:\n\n"
            + fragments.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n---\n")
        if !terms.isEmpty { prompt += "\n\nAsí se escriben los nombres y términos (la transcripción puede traerlos mal): \(terms.prefix(40).joined(separator: ", "))." }
        prompt += "\n\nPregunta de la estudiante: \(question)\n\nResponde de forma clara y breve usando solo esos fragmentos. "
            + "Indica entre corchetes de qué fragmento sale cada dato, como [2]. Si no lo tratan, dilo."
        return try await respond(prompt, as: String.self, language: language)
    }
}

enum ProcessingError: LocalizedError {
    case emptyTranscript
    case allBlocksRejected

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "La transcripción está vacía: no llegó audio con voz."
        case .allBlocksRejected: "El modelo no pudo procesar ningún bloque de la transcripción."
        }
    }
}
