import Foundation

/// Corrige en la transcripción términos que el reconocedor oye mal («Herpoint» → «SharePoint»), con una lista
/// de términos fiables (vocabulario de Ajustes, asignaturas, nombres en pantalla). Solo cambia cuando el parecido
/// es muy alto: más vale un error que se queda que una palabra correcta que se estropea.
public enum TermFixer {
    public static func fix(_ text: String, terms: [String]) -> String {
        let targets = terms.map { ($0, norm($0)) }.filter { $0.1.count >= 5 }
        guard !targets.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < tokens.count {
            // La ventana de 1 a 3 palabras más parecida a algún término; a igualdad, la más corta.
            var best: (n: Int, term: String, d: Int)?
            for n in 1...3 where i + n <= tokens.count {
                let w = norm(tokens[i..<(i + n)].joined(separator: " "))
                guard !w.isEmpty else { continue }
                for (term, t) in targets where matches(w, t) {
                    let d = distance(w, t)
                    if best == nil || d < best!.d { best = (n, term, d) }
                }
            }
            // «en sharepoint»: si sin la primera palabra encaja igual o mejor, el término empieza en la siguiente.
            if let b = best, b.n > 1 {
                let rest = norm(tokens[(i + 1)..<(i + b.n)].joined(separator: " "))
                if matches(rest, norm(b.term)), distance(rest, norm(b.term)) <= b.d { best = nil }
            }
            if let best {
                let window = tokens[i..<(i + best.n)].joined(separator: " ")
                // Igual salvo mayúsculas: solo se corrige si el término tiene una forma propia («SharePoint», «Digital Brains»).
                let distinctive = best.term.dropFirst().contains(where: \.isUppercase) || best.term.contains(" ")
                if best.d > 0 || (distinctive && !window.contains(best.term)) {
                    // Se respetan los signos de alrededor: «(Sherpoint),» → «(SharePoint),».
                    let lead = String(window.prefix { !$0.isLetter && !$0.isNumber })
                    let trail = String(window.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                    tokens.replaceSubrange(i..<(i + best.n), with: [lead + best.term + trail])
                }
            }
            i += 1
        }
        return tokens.joined(separator: " ")
    }

    static func matches(_ w: String, _ t: String) -> Bool {
        if w == t { return true }
        guard abs(w.count - t.count) <= 2, w != t + "s", w != t + "es" else { return false }
        let allowed = t.count >= 10 ? 2 : t.count >= 6 ? 1 : 0
        return allowed > 0 && distance(w, t) <= allowed
    }

    /// Minúsculas, sin tildes y sin espacios ni signos: «Share Point,» y «sharepoint» son lo mismo.
    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }
}

/// La asignatura de una clase nueva sin tener que elegirla: por el título (de la pestaña o el que puso la IA)
/// o por el horario (si las clases de ese día y hora suelen ser de la misma asignatura).
public enum SubjectGuess {
    static let stopwords: Set<String> = ["de", "del", "la", "las", "el", "los", "y", "e", "en", "a", "al", "para", "por", "con", "the", "of", "and"]

    public static func byTitle(_ title: String, subjects: [String]) -> String? {
        let titleWords = Set(Retriever.words(title))
        let folded = TermFixer.norm(title)
        // Nombre completo dentro del título.
        if let s = subjects.filter({ TermFixer.norm($0).count >= 4 && folded.contains(TermFixer.norm($0)) })
            .max(by: { $0.count < $1.count }) { return s }
        // Una palabra que solo tiene esa asignatura («Mercantil» y no «Derecho», que comparten varias).
        let wordsOf = subjects.map { s in (s, Set(Retriever.words(s)).subtracting(stopwords).filter { $0.count >= 5 }) }
        let hits = wordsOf.filter { s, words in
            words.contains { w in titleWords.contains(w) && wordsOf.filter { $0.1.contains(w) }.count == 1 }
        }
        return hits.count == 1 ? hits[0].0 : nil
    }

    /// Clases anteriores del mismo día de la semana que empezaron a menos de 45 min de esta hora:
    /// si al menos dos y dos de cada tres son de la misma asignatura, esa.
    public static func bySchedule(_ start: Date, history: [(date: Date, subject: String)], calendar: Calendar = .current) -> String? {
        let weekday = calendar.component(.weekday, from: start)
        let minute = { (d: Date) in calendar.component(.hour, from: d) * 60 + calendar.component(.minute, from: d) }
        let same = history.filter { calendar.component(.weekday, from: $0.date) == weekday && abs(minute($0.date) - minute(start)) <= 45 }
        guard same.count >= 2 else { return nil }
        let counts = Dictionary(same.map { ($0.subject, 1) }, uniquingKeysWith: +)
        guard let best = counts.max(by: { $0.value < $1.value }), best.value * 3 >= same.count * 2 else { return nil }
        return best.key
    }
}

/// Fecha dentro de un aviso de clase: «entrega el 14 de diciembre», «examen 22/01». nil si no hay.
/// Sin año, la siguiente vez que llegue ese día (un aviso de diciembre para enero es del año que viene).
public enum ReminderDate {
    static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]

    public static func find(in text: String, after reference: Date = .now, calendar: Calendar = .current) -> Date? {
        let lower = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
        var day: Int?, month: Int?, year: Int?
        if let m = lower.firstMatch(of: #/(\d{1,2})\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)(\s+de\s+(\d{4}))?/#) {
            day = Int(m.1)
            month = m.2 == "setiembre" ? 9 : (months.firstIndex(of: String(m.2)) ?? 0) + 1
            year = m.4.flatMap { Int($0) }
        } else if let m = lower.firstMatch(of: #/\b(\d{1,2})\/(\d{1,2})(\/(\d{2,4}))?\b(?!\s+del?\s+[a-z])/#) { // «1/2 de la nota» es una fracción
            day = Int(m.1); month = Int(m.2)
            year = m.4.flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
        }
        guard let day, let month, (1...31).contains(day), (1...12).contains(month) else { return nil }
        let refYear = calendar.component(.year, from: reference)
        // Calendar convierte el 31 de febrero en marzo sin avisar: solo vale si el día y el mes no cambian.
        func make(_ y: Int) -> Date? {
            guard let d = calendar.date(from: DateComponents(year: y, month: month, day: day, hour: 9)),
                  calendar.component(.day, from: d) == day, calendar.component(.month, from: d) == month else { return nil }
            return d
        }
        if let year { return make(year) }
        guard let thisYear = make(refYear) else { return nil }
        // Hasta una semana atrás se da por este año (un aviso de algo que acaba de pasar); antes, el siguiente.
        return thisYear < calendar.date(byAdding: .day, value: -7, to: reference)! ? make(refYear + 1) : thisYear
    }
}

/// Un evento de día completo en formato iCalendar, para abrirlo con Calendario (que pregunta antes de añadirlo).
public enum CalendarFile {
    public static func ics(title: String, date: Date, notes: String, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let start = f.string(from: date)
        let end = f.string(from: calendar.date(byAdding: .day, value: 1, to: date)!)
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n") }
        return """
            BEGIN:VCALENDAR\r
            VERSION:2.0\r
            PRODID:-//EstudIA//ES\r
            BEGIN:VEVENT\r
            UID:\(UUID().uuidString)@estudia\r
            DTSTAMP:\(f.string(from: .now))T000000Z\r
            DTSTART;VALUE=DATE:\(start)\r
            DTEND;VALUE=DATE:\(end)\r
            SUMMARY:\(esc(title))\r
            DESCRIPTION:\(esc(notes))\r
            BEGIN:VALARM\r
            TRIGGER:-P1D\r
            ACTION:DISPLAY\r
            DESCRIPTION:\(esc(title))\r
            END:VALARM\r
            END:VEVENT\r
            END:VCALENDAR\r

            """
    }
}

/// Tarjetas de repaso exportadas para Anki: una por línea, pregunta y respuesta separadas por tabulador.
public enum AnkiExport {
    public static func tsv(_ cards: [(question: String, answer: String)]) -> String {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>") }
        return cards.map { clean($0.question) + "\t" + clean($0.answer) }.joined(separator: "\n") + "\n"
    }
}
