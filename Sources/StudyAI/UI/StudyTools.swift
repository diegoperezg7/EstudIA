import AppKit
import StudyAICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tarjetas de repaso

struct Flashcard: Identifiable {
    let id = UUID()
    var question: String
    /// nil en clases procesadas antes de que se generaran respuestas.
    var answer: String?
    var lecture: String

    static func cards(of lectures: [Lecture]) -> [Flashcard] {
        lectures.flatMap { l in
            l.reviewQuestions.enumerated().map { i, q in
                Flashcard(question: q, answer: l.reviewAnswers[safe: i], lecture: l.displayTitle)
            }
        }
    }
}

/// Autoexamen: pregunta, «Mostrar respuesta» y «Lo sabía» / «Otra vez». Las falladas vuelven al final de la tanda.
struct FlashcardsView: View {
    let title: String
    let cards: [Flashcard]
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [Flashcard] = []
    @State private var revealed = false
    @State private var firstTry = 0
    @State private var missed = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repaso").font(.title2.weight(.bold))
                    Text(title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Exportar a Anki…") { exportAnki() }.disabled(cards.isEmpty)
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if cards.isEmpty {
                Text("Aún no hay preguntas de repaso: se crean al generar el resumen.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let card = queue.first {
                Text("Quedan \(queue.count) de \(cards.count)").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Text(card.lecture).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(card.question).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if revealed {
                        Divider()
                        Text(card.answer ?? "Esta clase se resumió antes de que EstudIA guardara las respuestas: vuelve a generar su resumen para tenerlas.")
                            .font(.system(size: 15)).foregroundStyle(card.answer == nil ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                .card()
                HStack {
                    Spacer()
                    if revealed {
                        Button("Otra vez") { next(knew: false) }.keyboardShortcut("2", modifiers: [])
                        Button("Lo sabía") { next(knew: true) }.buttonStyle(ProminentButtonStyle()).keyboardShortcut("1", modifiers: [])
                    } else {
                        Button("Mostrar respuesta") { withAnimation { revealed = true } }
                            .buttonStyle(ProminentButtonStyle()).keyboardShortcut(.space, modifiers: [])
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.ink)
                    Text("Repaso terminado").font(.title3.weight(.semibold))
                    Text("\(firstTry) de \(cards.count) a la primera.").foregroundStyle(.secondary)
                    Button("Empezar otra vez") { restart() }
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .padding(26)
        .frame(width: 560)
        .onAppear(perform: restart)
    }

    private func restart() {
        queue = cards.shuffled()
        revealed = false
        firstTry = 0
        missed = []
    }

    private func next(knew: Bool) {
        let card = queue.removeFirst()
        if knew, !missed.contains(card.id) { firstTry += 1 }
        if !knew { missed.insert(card.id); queue.append(card) }
        revealed = false
    }

    private func exportAnki() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title) - tarjetas.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = AnkiExport.tsv(cards.map { ($0.question, $0.answer ?? "") })
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Fechas al calendario

/// Los avisos de «Para recordar» que llevan fecha, con un botón para pasarlos a Calendario.
/// Calendario pregunta en qué calendario añadirlo: nada se apunta sin confirmar.
struct ReminderDatesCard: View {
    let summary: String
    let lectureTitle: String
    /// Los avisos sin año se leen desde el día de la clase, no desde hoy.
    let lectureDate: Date

    private var dated: [(text: String, date: Date)] {
        var inside = false
        return summary.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") { inside = line == "### Para recordar"; return nil }
            guard inside, line.hasPrefix("- ") else { return nil }
            let text = String(line.dropFirst(2))
            return ReminderDate.find(in: text, after: lectureDate).map { (text, $0) }
        }
    }

    var body: some View {
        let items = dated
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Fechas de esta clase", systemImage: "calendar").font(.headline).foregroundStyle(Theme.ink)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 12) {
                        Text(item.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES"))))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 60, height: 26).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 6))
                        Text(item.text).font(.system(size: 13)).lineLimit(2)
                        Spacer()
                        Button("Añadir al calendario") { CalendarExport.add(title: item.text, date: item.date, notes: "De la clase «\(lectureTitle)» (EstudIA).") }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

enum CalendarExport {
    /// Abre un evento de día completo en Calendario, que pide confirmación antes de guardarlo. Sin permisos de calendario.
    static func add(title: String, date: Date, notes: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "EstudIA-\(UUID().uuidString.prefix(8)).ics")
        guard (try? CalendarFile.ics(title: title, date: date, notes: notes).write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Preguntar a toda la asignatura

/// Chat sobre todas las clases de una asignatura: busca los fragmentos más parecidos a la pregunta
/// y responde con el modelo del Mac, citando de qué clase y minuto sale cada dato.
struct SubjectAskView: View {
    let subject: Subject
    let open: (Lecture) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer: String?
    @State private var sources: [(lecture: Lecture, start: Double)] = []
    @State private var thinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preguntar a \(subject.name)").font(.title2.weight(.bold))
                    Text("Busca en las \(subject.lectures.count) clases de la asignatura.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Por ejemplo: ¿qué dijo del dolo en todas las clases?", text: $question)
                    .textFieldStyle(.roundedBorder).onSubmit(ask)
                Button(thinking ? "Buscando…" : "Preguntar", action: ask)
                    .buttonStyle(ProminentButtonStyle()).disabled(thinking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                            .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        if !sources.isEmpty {
                            Text("De dónde sale").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(Array(sources.enumerated()), id: \.offset) { i, s in
                                Button { dismiss(); open(s.lecture) } label: {
                                    HStack(spacing: 8) {
                                        Text("[\(i + 1)]").font(.caption.weight(.bold)).foregroundStyle(Theme.ink)
                                        Text(s.lecture.displayTitle).font(.caption)
                                        Text(TimeFormat.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(26)
        .frame(width: 620, height: answer == nil ? 170 : 520)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !thinking else { return }
        thinking = true
        // Fragmentos de unos 900 caracteres con su clase y su minuto, para poder citarlos.
        var pieces: [(text: String, lecture: Lecture, start: Double)] = []
        for l in subject.lectures {
            var text = "", start = 0.0
            for s in l.orderedSegments where !s.isGap {
                if text.isEmpty { start = s.start }
                text += (text.isEmpty ? "" : " ") + s.text
                if text.count >= 900 { pieces.append((text, l, start)); text = "" }
            }
            if !text.isEmpty { pieces.append((text, l, start)) }
        }
        let top = Retriever.top(pieces.map(\.text), for: q, k: 4)
        let chosen = top.compactMap { t in pieces.first { $0.text == t } }
        let fragments = chosen.map { "Clase «\($0.lecture.displayTitle)», minuto \(TimeFormat.clock($0.start)): \($0.text)" }
        let terms = subject.lectures.flatMap { LectureProcessor.terms(for: $0, onDevice: true) } // la respuesta la da el modelo del Mac
        let language = subject.lectures.first?.language ?? .spanish
        Task {
            do {
                answer = fragments.isEmpty
                    ? "No encuentro nada sobre eso en las clases de esta asignatura."
                    : try await StudyAI.answer(q, fragments: fragments, language: language, terms: Array(Set(terms)))
                sources = chosen.map { ($0.lecture, $0.start) }
            } catch {
                answer = "No pude responder: \(error.localizedDescription)"
                sources = []
            }
            thinking = false
        }
    }
}

// MARK: - Guía de examen

/// Un documento con todo lo de una asignatura para estudiar: el resumen de cada clase en orden,
/// todas las fechas juntas y las preguntas con su respuesta. Se guarda en PDF.
enum ExamGuide {
    static func markdown(_ subject: Subject) -> String {
        let lectures = subject.lectures.filter { $0.summary != nil }.sorted { $0.createdAt < $1.createdAt }
        var out = "# Guía de examen: \(subject.name)\n\n\(lectures.count) clases resumidas por EstudIA.\n"
        var reminders: [(text: String, date: Date)] = []
        for l in lectures {
            out += "\n## \(l.displayTitle)\n\(l.createdAt.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "es_ES"))))\n\n"
            var inReminders = false
            for line in (l.summary ?? "").components(separatedBy: "\n") {
                if line.hasPrefix("### ") { inReminders = line == "### Para recordar" }
                if inReminders { if line.hasPrefix("- ") { reminders.append((String(line.dropFirst(2)), l.createdAt)) }; continue }
                out += line + "\n"
            }
        }
        if !reminders.isEmpty {
            let dated = reminders.map { ($0.text, ReminderDate.find(in: $0.text, after: $0.date)) }.sorted { ($0.1 ?? .distantFuture) < ($1.1 ?? .distantFuture) }
            out += "\n## Fechas y avisos\n" + dated.map { "- \($0.0)" }.joined(separator: "\n") + "\n"
        }
        let cards = Flashcard.cards(of: lectures)
        if !cards.isEmpty {
            out += "\n## Preguntas de repaso\n"
            for c in cards { out += "- **\(c.question)**" + (c.answer.map { " \($0)" } ?? "") + "\n" }
        }
        return out
    }

    @MainActor static func exportPDF(_ subject: Subject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Guía de examen - \(subject.name).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDF(markdown(subject), to: url)
        NSWorkspace.shared.open(url)
    }

    @MainActor static func writePDF(_ markdown: String, to url: URL) {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842) // A4
        for m in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: m] = 50 }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 495, height: 700))
        view.textStorage?.setAttributedString(attributed(markdown))
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }

    /// Lo justo de Markdown para el PDF: títulos, viñetas y negrita.
    static func attributed(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        for line in md.components(separatedBy: "\n") {
            var font = body, text = line, spacing: CGFloat = 3
            if line.hasPrefix("# ") { font = .boldSystemFont(ofSize: 20); text = String(line.dropFirst(2)); spacing = 10 }
            else if line.hasPrefix("## ") { font = .boldSystemFont(ofSize: 15); text = String(line.dropFirst(3)); spacing = 8 }
            else if line.hasPrefix("### ") { font = .boldSystemFont(ofSize: 12); text = String(line.dropFirst(4)); spacing = 5 }
            else if line.hasPrefix("- ") { text = "•  " + line.dropFirst(2) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacing
            style.headIndent = line.hasPrefix("- ") ? 14 : 0
            let piece = NSMutableAttributedString(string: text.replacingOccurrences(of: "**", with: "") + "\n",
                                                  attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black])
            // **pregunta**: en negrita.
            if let r = text.range(of: #"\*\*(.+?)\*\*"#, options: .regularExpression) {
                let bold = String(text[r]).replacingOccurrences(of: "**", with: "")
                let ns = piece.string as NSString
                piece.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: ns.range(of: bold))
            }
            out.append(piece)
        }
        return out
    }
}

// MARK: - Conectar Groq

/// Paso guiado para usar Groq (gratis) en vez del modelo del Mac: clave, prueba real y listo.
struct GroqSetup: View {
    @State private var key = ""
    @State private var status: String?
    @State private var checking = false
    @State private var connected = GroqSetup.isConnected
    var onConnected: () -> Void = {}

    static var isConnected: Bool { AIEngine.selected == .external && CloudLLM.config != nil }

    var body: some View {
        if connected {
            Label("Conectado a Groq. Los resúmenes y apuntes saldrán de su modelo.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Link("1. Conseguir una clave gratis", destination: URL(string: "https://console.groq.com/keys")!)
                    Text("(entra con Google y pulsa «Create API Key»)").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    SecureField("2. Pega aquí la clave", text: $key).textFieldStyle(.roundedBorder)
                    Button(checking ? "Comprobando…" : "Conectar", action: connect)
                        .disabled(checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func connect() {
        checking = true
        status = nil
        let preset = CloudLLM.presets[0]
        let defaults = UserDefaults.standard
        let previous = (key: Keychain.read(), url: defaults.string(forKey: CloudLLM.urlKey), model: defaults.string(forKey: CloudLLM.modelKey))
        Keychain.save(key)
        UserDefaults.standard.set(preset.url, forKey: CloudLLM.urlKey)
        UserDefaults.standard.set(preset.model, forKey: CloudLLM.modelKey)
        Task {
            do {
                _ = try await StudyAI.cloudRespond("Escribe un tema de prueba sobre el agua.", as: DigestSection.self, language: .spanish, engine: .external)
                UserDefaults.standard.set(AIEngine.external.rawValue, forKey: AIEngine.key)
                connected = true
                onConnected()
            } catch {
                // Lo que hubiera configurado antes sigue valiendo.
                Keychain.save(previous.key ?? "")
                defaults.set(previous.url, forKey: CloudLLM.urlKey)
                defaults.set(previous.model, forKey: CloudLLM.modelKey)
                status = "No funcionó: \(error.localizedDescription) Revisa que la clave esté completa."
            }
            checking = false
        }
    }
}
