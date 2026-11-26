import Foundation

/// Copia de la biblioteca que la app deja en disco para el servidor MCP (solo lectura, solo en este Mac).
public struct LibraryExport: Codable, Sendable {
    public struct Segment: Codable, Sendable {
        public var start: Double, text: String, speaker: String?
        public init(start: Double, text: String, speaker: String?) { self.start = start; self.text = text; self.speaker = speaker }
    }

    public struct Lecture: Codable, Sendable {
        public var id: String, title: String, subject: String?, date: Date, duration: Double, language: String
        public var summary: String?, notes: String?, questions: [String], userNotes: String, transcript: [Segment]
        public init(id: String, title: String, subject: String?, date: Date, duration: Double, language: String,
                    summary: String?, notes: String?, questions: [String], userNotes: String, transcript: [Segment]) {
            self.id = id; self.title = title; self.subject = subject; self.date = date; self.duration = duration
            self.language = language; self.summary = summary; self.notes = notes; self.questions = questions
            self.userNotes = userNotes; self.transcript = transcript
        }
    }

    public var lectures: [Lecture]
    public init(lectures: [Lecture]) { self.lectures = lectures }

    /// ~/Library/Application Support/StudyAI/biblioteca.json
    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyAI/biblioteca.json")
    }

    public static func load(from url: URL = url) -> LibraryExport {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(LibraryExport.self, from: $0) } ?? .init(lectures: [])
    }

    public func save(to url: URL = url) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// Servidor MCP mínimo (JSON-RPC 2.0 por stdio, una línea por mensaje): da a ChatGPT o Claude las clases de EstudIA.
/// Solo lee; no escribe nada ni abre red.
public struct MCPServer {
    public var library: () -> LibraryExport
    public init(library: @escaping () -> LibraryExport) { self.library = library }

    /// Solo lectura y sin red: así ChatGPT/Codex las puede usar sin pedir permiso en cada llamada.
    static let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]

    static let tools: [[String: Any]] = toolDefs.map { var t = $0; t["annotations"] = readOnly; return t }

    static let toolDefs: [[String: Any]] = [
        ["name": "listar_clases",
         "description": "Lista las clases grabadas en EstudIA (más recientes primero), con su id, asignatura, fecha y duración. Úsalo para encontrar la clase de la que habla el usuario.",
         "inputSchema": ["type": "object", "properties": [
            "asignatura": ["type": "string", "description": "Filtra por asignatura (opcional)."],
            "limite": ["type": "integer", "description": "Máximo de clases (por defecto 30)."]]]],
        ["name": "leer_clase",
         "description": "Lee una clase: resumen, apuntes, preguntas de repaso, notas del alumno y, si se pide, la transcripción con los minutos.",
         "inputSchema": ["type": "object", "required": ["id"], "properties": [
            "id": ["type": "string", "description": "El id de listar_clases o buscar."],
            "parte": ["type": "string", "enum": ["todo", "resumen", "apuntes", "transcripcion"],
                      "description": "Qué leer (por defecto «todo» sin la transcripción completa; «transcripcion» la da entera)."]]]],
        ["name": "buscar",
         "description": "Busca palabras en todas las clases (transcripción, resumen, apuntes y notas) y devuelve los fragmentos con su clase y minuto.",
         "inputSchema": ["type": "object", "required": ["texto"], "properties": [
            "texto": ["type": "string"],
            "asignatura": ["type": "string", "description": "Opcional."]]]],
    ]

    /// Respuesta a una línea de entrada, o nil si era una notificación.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = msg["method"] as? String else { return nil }
        guard let id = msg["id"] else { return nil } // notificación (p. ej. notifications/initialized)
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return reply(id, ["protocolVersion": version, "capabilities": ["tools": [:] as [String: Any]],
                              "serverInfo": ["name": "estudia", "version": "1.0"],
                              "instructions": "Clases de la universidad grabadas con EstudIA. Busca o lista la clase y luego léela antes de responder; cita el minuto (mm:ss) cuando uses la transcripción."])
        case "ping": return reply(id, [:] as [String: Any])
        case "tools/list": return reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, args)
            return reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Método no disponible: \(method)"]])
        }
    }

    func call(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        let lib = library().lectures.sorted { $0.date > $1.date }
        let subject = (a["asignatura"] as? String).map(Self.fold)
        let inSubject = lib.filter { l in subject.map { Self.fold(l.subject ?? "sin asignatura").contains($0) } ?? true }
        switch name {
        case "listar_clases":
            let limit = a["limite"] as? Int ?? 30
            guard !inSubject.isEmpty else { return ("No hay clases" + (subject == nil ? "." : " de esa asignatura."), false) }
            return (inSubject.prefix(limit).map { l in
                "- id: \(l.id) · «\(l.title)» · \(l.subject ?? "Sin asignatura") · \(Self.day(l.date)) · \(TimeFormat.clock(l.duration))"
                    + (l.summary == nil ? " · sin resumen" : "")
            }.joined(separator: "\n"), false)
        case "leer_clase":
            guard let id = a["id"] as? String, let l = lib.first(where: { $0.id == id }) else {
                return ("No encuentro esa clase. Usa listar_clases para ver los id.", true)
            }
            let part = a["parte"] as? String ?? "todo"
            var out = "# \(l.title)\n\(l.subject ?? "Sin asignatura") · \(Self.day(l.date)) · \(TimeFormat.clock(l.duration)) · idioma \(l.language)\n"
            if part == "todo" || part == "resumen" { out += "\n## Resumen\n\(l.summary ?? "(sin resumen todavía)")\n" }
            if part == "todo" || part == "apuntes" {
                out += "\n## Apuntes\n\(l.notes ?? "(sin apuntes todavía)")\n"
                if !l.questions.isEmpty { out += "\n## Preguntas de repaso\n" + l.questions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
                if !l.userNotes.isEmpty { out += "\n## Notas del alumno\n\(l.userNotes)\n" }
            }
            if part == "transcripcion" || (part == "todo" && l.summary == nil) {
                out += "\n## Transcripción\n" + l.transcript.map { s in
                    "[\(TimeFormat.clock(s.start))] " + (s.speaker.map { "\($0): " } ?? "") + s.text
                }.joined(separator: "\n")
            } else if part == "todo" {
                out += "\n(La transcripción completa: leer_clase con parte «transcripcion».)"
            }
            return (out, false)
        case "buscar":
            let q = Self.fold(a["texto"] as? String ?? "")
            guard !q.isEmpty else { return ("Falta el texto a buscar.", true) }
            var hits: [String] = []
            for l in inSubject {
                for s in l.transcript where Self.fold(s.text).contains(q) {
                    hits.append("- [\(l.id)] «\(l.title)» \(TimeFormat.clock(s.start)): \(s.text.prefix(300))")
                }
                for (label, text) in [("resumen", l.summary), ("apuntes", l.notes), ("notas", l.userNotes)] {
                    if let text, Self.fold(text).contains(q) { hits.append("- [\(l.id)] «\(l.title)» (en \(label))") }
                }
            }
            return (hits.isEmpty ? "Sin resultados." : hits.prefix(40).joined(separator: "\n"), false)
        default:
            return ("Herramienta desconocida: \(name)", true)
        }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Locale(identifier: "es_ES")))
    }

    private func reply(_ id: Any, _ result: Any) -> String? { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func encode(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) }
    }
}
