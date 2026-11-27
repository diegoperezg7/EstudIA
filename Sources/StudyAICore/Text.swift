import Foundation

/// Divide un texto largo en trozos de como mucho `maxChars`, cortando por frases.
/// El modelo de Apple tiene una ventana de unos 4k tokens: cada trozo va en su propia sesión.
public enum Chunker {
    public static func chunk(_ text: String, maxChars: Int) -> [String] {
        precondition(maxChars > 0)
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(text) {
            // Una frase más larga que el límite se corta a la fuerza.
            for piece in hardSplit(sentence, maxChars: maxChars) {
                if current.count + piece.count + 1 > maxChars, !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                current += current.isEmpty ? piece : " " + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out
    }

    static func hardSplit(_ s: String, maxChars: Int) -> [String] {
        guard s.count > maxChars else { return [s] }
        var parts: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            parts.append(String(rest.prefix(maxChars)))
            rest = rest.dropFirst(maxChars)
        }
        return parts
    }
}

/// Recupera los trozos más relevantes para una pregunta por coincidencia de palabras.
/// ponytail: sin embeddings; si las preguntas fallan por sinónimos, pasar a NLEmbedding.
public enum Retriever {
    public static func top(_ chunks: [String], for query: String, k: Int) -> [String] {
        let terms = Set(words(query))
        guard !terms.isEmpty else { return Array(chunks.prefix(k)) }
        let scored = chunks.enumerated().map { i, c -> (Int, Int) in
            (i, words(c).reduce(0) { $0 + (terms.contains($1) ? 1 : 0) })
        }
        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .sorted { $0.0 < $1.0 } // devolver en orden de la clase
            .map { chunks[$0.0] }
    }

    public static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
    }

    static let stopwords: Set<String> = [
        "para", "como", "pero", "esta", "este", "esto", "estos", "estas", "porque", "cuando", "donde",
        "sobre", "entre", "tambien", "desde", "hasta", "tiene", "tienen", "hace", "hacer", "puede",
        "pueden", "cual", "cuales", "segun", "todo", "todos", "todas", "otra", "otro", "otros", "muy",
        "bueno", "vale", "entonces", "pues", "cosa", "cosas", "aqui", "ahora", "explica", "dime", "clase",
    ]
}

public enum TimeFormat {
    /// 75 → "1:15", 3725 → "1:02:05"
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Exportación de una clase a Markdown, para llevarla a Notion, Obsidian o donde sea.
public enum MarkdownExport {
    public struct Segment {
        public let start: Double
        public let text: String
        public let isGap: Bool
        public let speaker: String?
        public init(start: Double, text: String, isGap: Bool, speaker: String? = nil) {
            self.start = start; self.text = text; self.isGap = isGap; self.speaker = speaker
        }
    }

    public static func render(
        title: String, subject: String?, date: Date, duration: Double,
        summary: String?, notes: String?, questions: [String], userNotes: String = "", segments: [Segment]
    ) -> String {
        var md = "# \(title)\n\n"
        let dateText = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(Locale(identifier: "es_ES")))
        md += [subject, dateText, "Duración \(TimeFormat.clock(duration))"].compactMap { $0 }.joined(separator: " · ")
        md += "\n\n"
        if let summary, !summary.isEmpty { md += "## Resumen\n\n\(summary)\n\n" }
        let mine = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { md += "## Mis notas\n\n\(mine)\n\n" }
        if let notes, !notes.isEmpty { md += "## Apuntes\n\n\(notes)\n\n" }
        if !questions.isEmpty {
            md += "## Preguntas de repaso\n\n"
            md += questions.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
            md += "\n\n"
        }
        md += "## Transcripción\n\n"
        var lastSpeaker: String?
        for s in segments {
            if s.isGap { md += "*[\(TimeFormat.clock(s.start)) · \(s.text)]*\n\n"; continue }
            // El nombre solo cuando cambia quien habla.
            let who = s.speaker.flatMap { $0 == lastSpeaker ? nil : $0 }
            if let speaker = s.speaker { lastSpeaker = speaker }
            md += "**\(TimeFormat.clock(s.start))**" + (who.map { " **\($0):**" } ?? "") + " \(s.text)\n\n"
        }
        return md
    }
}

/// Agrupa trozos de texto con tiempo (palabras o frases del reconocedor) en párrafos legibles.
/// Corta al final de frase en cuanto el párrafo supera `minChars`, para que cada uno tenga su minuto.
public enum Paragrapher {
    public struct Piece {
        public let text: String
        public let start: Double?
        public let end: Double?
        public init(text: String, start: Double?, end: Double?) { self.text = text; self.start = start; self.end = end }
    }

    public static func split(_ pieces: [Piece], fallbackStart: Double, fallbackEnd: Double,
                             minChars: Int = 280) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, String)] = []
        var text = "", start: Double?, end: Double?
        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((start ?? out.last?.1 ?? fallbackStart, end ?? start ?? fallbackEnd, t)) }
            text = ""; start = nil; end = nil
        }
        for p in pieces {
            text += p.text
            if start == nil { start = p.start }
            if let e = p.end { end = e }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= minChars, let last = trimmed.last, ".?!…".contains(last) { flush() }
        }
        flush()
        return out
    }

    /// ¿El trozo `next` continúa el párrafo `previous`? El reconocedor cierra un resultado en cada pausa del
    /// profesor, a veces con dos palabras: se unen al párrafo anterior mientras este siga corto o a media frase.
    /// No se une tras una pausa larga, si cambia quien habla, ni si el párrafo pasaría de `maxChars`.
    public static func continues(previous: String, previousEnd: Double, next: String, nextStart: Double,
                                 sameSpeaker: Bool = true, targetChars: Int = 450, maxChars: Int = 1_200,
                                 maxPause: Double = 20) -> Bool {
        guard sameSpeaker, nextStart - previousEnd <= maxPause, previous.count + next.count + 1 <= maxChars else { return false }
        let closed = previous.last.map { ".?!…".contains($0) } ?? true
        return previous.count < targetChars || !closed || next.count < 80
    }

    /// Une los párrafos cortos de una lista ya ordenada (importación de un fichero).
    public static func mergeShort(_ paragraphs: [(start: Double, end: Double, text: String)]) -> [(start: Double, end: Double, text: String)] {
        var out: [(start: Double, end: Double, text: String)] = []
        for p in paragraphs {
            if let last = out.last, continues(previous: last.text, previousEnd: last.end, next: p.text, nextStart: p.start) {
                out[out.count - 1] = (last.start, max(last.end, p.end), last.text + " " + p.text)
            } else {
                out.append(p)
            }
        }
        return out
    }
}

/// Enlaza cada frase generada (resumen, apuntes, respuestas) con el párrafo de la transcripción del que sale.
/// Puntúa por términos compartidos ponderados por rareza (idf): «mitocondria» pesa más que «proceso».
public struct Citations {
    private let docs: [Set<String>]
    private let idf: [String: Double]

    public init(paragraphs: [String]) {
        docs = paragraphs.map { Set(Retriever.words($0)) }
        var df: [String: Int] = [:]
        for d in docs { for w in d { df[w, default: 0] += 1 } }
        let n = Double(max(docs.count, 1))
        idf = df.mapValues { log(1 + n / Double($0)) }
    }

    /// Índice del párrafo que mejor respalda la frase, o nil si ninguno comparte lo suficiente.
    public func source(for sentence: String, minScore: Double = 2.5) -> Int? {
        let terms = Set(Retriever.words(sentence))
        guard !terms.isEmpty else { return nil }
        var best: (Int, Double)?
        for (i, d) in docs.enumerated() {
            let score = terms.intersection(d).reduce(0) { $0 + (idf[$1] ?? 0) }
            if score > (best?.1 ?? 0) { best = (i, score) }
        }
        guard let best, best.1 >= minScore else { return nil }
        return best.0
    }

    /// Parte un texto en frases y numera sus fuentes por orden de aparición (la misma fuente reutiliza número).
    public func annotate(_ text: String) -> [(sentence: String, source: Int?, number: Int?)] {
        var numbers: [Int: Int] = [:]
        return Chunker.sentences(text).map { s in
            guard let src = source(for: s) else { return (s, nil, nil) }
            let n = numbers[src] ?? (numbers.count + 1)
            numbers[src] = n
            return (s, src, n)
        }
    }
}

/// Texto visible de una diapositiva de PowerPoint a partir de su XML (los <a:t>, un párrafo por <a:p>).
public enum SlideText {
    public static func fromXML(_ xml: String) -> String {
        xml.components(separatedBy: "</a:p>").compactMap { paragraph -> String? in
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            let runs = run.matches(in: paragraph, range: range).compactMap { Range($0.range(at: 1), in: paragraph).map { paragraph[$0] } }
            let line = unescape(runs.joined()).trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }.joined(separator: "\n")
    }

    private static let run = try! NSRegularExpression(pattern: "<a:t(?:\\s[^>]*)?>(.*?)</a:t>", options: [.dotMatchesLineSeparators])

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Empareja cada párrafo de la transcripción con la página o diapositiva de la que se está hablando.
/// Por términos compartidos ponderados por rareza (como `Citations`). Si un párrafo no se parece lo bastante
/// a ninguna, se queda en la anterior: el profesor no cambia de diapositiva a cada frase.
/// ponytail: heurística por palabras; con diapositivas casi sin texto (solo imágenes) no acierta.
public enum SlideAligner {
    public static func align(paragraphs: [String], pages: [String], minScore: Double = 2.5) -> [Int?] {
        guard !pages.isEmpty else { return paragraphs.map { _ in nil } }
        let index = Citations(paragraphs: pages)
        var current: Int?
        return paragraphs.map { p in
            if let page = index.source(for: p, minScore: minScore) { current = page }
            return current
        }
    }
}

/// Un título de ventana de navegador presentable: sin el nombre del navegador, el perfil, «Reproduciendo audio»,
/// enlaces ni identificadores o fechas largas («8273645_1», «2026-11-26»). nil si no queda nada legible.
public enum WindowTitle {
    static let separators = [" - ", " – ", " — ", " | ", " · ", " :: "]
    static let noise: Set<String> = ["google chrome", "safari", "microsoft edge", "firefox", "mozilla firefox", "brave", "arc",
                                     "audio playing", "reproduciendo audio", "playing audio", "reproduciendo",
                                     "camera or microphone recording", "youtube", "meet", "google meet", "zoom",
                                     "microsoft teams", "webex", "classroom", "google classroom", "moodle"]

    public static func clean(_ title: String, prefer keywords: [String] = []) -> String? {
        var parts = [title]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        let segments = parts.compactMap { part -> String? in
            let p = part.trimmingCharacters(in: .whitespaces)
            // Ni la plataforma ni el código de la reunión de Meet («abc-defg-hij») dicen de qué va la clase.
            guard !noise.contains(p.lowercased()),
                  p.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) == nil else { return nil }
            let words = p.split(separator: " ").filter { word in
                let w = String(word)
                let digits = w.filter(\.isNumber).count
                let link = w.contains("://") || w.hasPrefix("www.")
                return !(link || digits >= 4 || (digits > 0 && digits * 2 >= w.count && w.count > 2))
            }
            let text = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -_·|#()[]"))
            return text.filter(\.isLetter).count >= 3 ? text : nil
        }
        // El perfil de Chrome va al final y entre paréntesis: «Ana (Personal)».
        let meaningful = segments.filter { !($0.hasSuffix(")") && $0 == segments.last && segments.count > 1) }
        guard !meaningful.isEmpty else { return nil }
        let lowerKeywords = keywords.map { $0.lowercased() }
        let best = meaningful.first { s in lowerKeywords.contains { s.lowercased().contains($0) } } ?? meaningful[0]
        return best.count > 60 ? String(best.prefix(59)) + "…" : best
    }
}
