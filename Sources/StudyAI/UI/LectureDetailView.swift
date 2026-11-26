import AppKit
import StudyAICore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Enlace interno a un momento de la transcripción: studyai://t/<segundo de inicio del párrafo>.
enum CiteLink {
    static func url(_ segment: TranscriptSegment) -> URL { URL(string: "studyai://t/\(segment.start)")! }
    static func time(_ url: URL) -> Double? { url.scheme == "studyai" && url.host == "t" ? Double(url.lastPathComponent) : nil }
}

/// Párrafos de la transcripción que pueden citarse, con su índice de términos.
struct SourceIndex {
    let segments: [TranscriptSegment]
    let citations: Citations

    init(_ lecture: Lecture) {
        segments = lecture.orderedSegments.filter { !$0.isGap }
        citations = Citations(paragraphs: segments.map(\.text))
    }

    func source(for sentence: String) -> TranscriptSegment? {
        citations.source(for: sentence).map { segments[$0] }
    }

    /// Fuentes distintas de un texto, en orden de aparición.
    func sources(in text: String, limit: Int = 3) -> [TranscriptSegment] {
        var seen = Set<Double>()
        return Chunker.sentences(text).compactMap(source(for:)).filter { seen.insert($0.start).inserted }.prefix(limit).map { $0 }
    }
}

struct LectureDetailView: View {
    @Bindable var lecture: Lecture
    /// Tras eliminarla, volver a la portada (un modelo borrado no siempre marca isDeleted al guardar).
    var onDelete: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(LectureProcessor.self) private var processor
    @Environment(RecordingSession.self) private var session
    @Query(sort: \Subject.name) private var subjects: [Subject]

    enum Tab: String, CaseIterable {
        case summary = "Resumen", notes = "Apuntes", material = "Material", mine = "Mis notas", ask = "Chat", transcript = "Transcripción"
        var icon: String {
            switch self {
            case .transcript: "text.quote"
            case .summary: "text.badge.star"
            case .notes: "list.bullet.rectangle"
            case .material: "doc.richtext"
            case .mine: "pencil.and.list.clipboard"
            case .ask: "bubble.left.and.text.bubble.right"
            }
        }
    }
    @AppStorage("detailTab") private var tab: Tab = .summary
    /// Momento de la transcripción al que saltar desde una cita.
    @State private var target: Double?
    @FocusState private var titleFocused: Bool
    @State private var confirmDelete = false
    /// Ancho de la ventana: en pantallas o ventanas estrechas la transcripción pasa a ser una pestaña más.
    @State private var width: CGFloat = 1200
    private var wide: Bool { width >= 1000 }
    private var tabs: [Tab] { wide ? Tab.allCases.filter { $0 != .transcript } : Tab.allCases }
    /// La pestaña visible: la de transcripción no existe en ancho (ya está a la derecha).
    private var shownTab: Tab { wide && tab == .transcript ? .summary : tab }

    private var isLive: Bool { session.lecture == lecture }

    var body: some View {
        // Estudio a la izquierda, transcripción siempre visible a la derecha: una cita lleva al minuto sin cambiar de vista.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, wide ? 26 : 16).padding(.top, 14).padding(.bottom, 10)
                banners.padding(.horizontal, wide ? 26 : 16).padding(.bottom, 8)
                tabBar.padding(.horizontal, wide ? 22 : 12).padding(.bottom, 8)
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if wide {
                Divider()
                TranscriptTab(lecture: lecture, isLive: isLive, target: $target)
                    .frame(width: min(440, max(300, width * 0.3)))
                    .background(Theme.subtle.opacity(0.5))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.canvas)
        .environment(\.openURL, OpenURLAction { url in
            guard let t = CiteLink.time(url) else { return .systemAction }
            if !wide { tab = .transcript }
            target = t
            return .handled
        })
        .onChange(of: lecture.status) { _, s in if s == .ready { tab = .summary } }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: session.finished == lecture)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isLive)
        // Al terminar de grabar, si no tiene nombre, el cursor queda en el título.
        .onChange(of: isLive) { was, now in if was, !now, lecture.title.isEmpty { titleFocused = true } }
        .confirmationDialog("¿Eliminar «\(lecture.displayTitle)»?", isPresented: $confirmDelete) {
            Button("Eliminar clase", role: .destructive) {
                processor.cancel(lecture)
                Materials.removeFiles(of: lecture)
                context.delete(lecture)
                try? context.save()
                onDelete()
            }
        } message: {
            Text("Se borran la transcripción, los apuntes y tus notas. No se puede deshacer.")
        }
        .id(lecture.persistentModelID)
    }

    // MARK: Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                subjectMenu
                Spacer()
                ChatGPTButton(lecture: lecture, compact: width < 760)
                exportMenu
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(ChipStyle(kind: .danger, iconOnly: true))
                .help(isLive ? "No se puede eliminar mientras se graba" : "Eliminar esta clase")
                .disabled(isLive)
            }
            TextField("Título", text: $lecture.title, prompt: Text("Ponle nombre a esta clase"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 23, weight: .bold))
                .lineLimit(1...3)
                .focused($titleFocused)
                .onSubmit { titleFocused = false; try? context.save() }
            FlowLayout(spacing: 14) {
                Label(lecture.dateTimeText.prefix(1).uppercased() + lecture.dateTimeText.dropFirst(), systemImage: "calendar")
                if lecture.duration > 0 { Label(TimeFormat.clock(lecture.duration), systemImage: "clock") }
                Label("\(lecture.wordCount.formatted()) palabras", systemImage: "text.word.spacing")
                Label { Text(lecture.language.name) } icon: { Flag(language: lecture.language, height: 11) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var subjectMenu: some View {
        Menu {
            Button("Sin asignatura") { lecture.subject = nil }
            if !subjects.isEmpty { Divider() }
            ForEach(subjects) { s in Button(s.name) { lecture.subject = s } }
        } label: {
            Label(lecture.subject?.name ?? "Sin asignatura", systemImage: "book.closed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(lecture.subject == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.ink))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((lecture.subject == nil ? Color.secondary : Theme.ink).opacity(0.12), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var exportMenu: some View {
        Menu {
            Button("Guardar como Markdown…") { saveMarkdown() }
            Button("Copiar todo") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lecture.markdown(), forType: .string)
            }
        } label: {
            Label("Exportar", systemImage: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Theme.subtle, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardBorder))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("Guardar la clase en Markdown o copiarla entera")
        .disabled(lecture.segments.isEmpty)
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let date = lecture.createdAt.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "\(date) \(lecture.displayTitle)".replacingOccurrences(of: "/", with: "-") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? lecture.markdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Pestañas

    private var tabBar: some View {
        // Con poco sitio, solo los iconos (el nombre queda en la ayuda).
        ViewThatFits(in: .horizontal) {
            tabButtons(iconsOnly: false)
            tabButtons(iconsOnly: true)
        }
        .animation(.easeOut(duration: 0.15), value: shownTab)
    }

    private func tabButtons(iconsOnly: Bool) -> some View {
        let tab = shownTab
        return HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { t in
                Button { self.tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .labelStyle(iconsOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                        .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Theme.ink : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(tab == t ? Theme.subtle : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(tab == t ? Theme.cardBorder : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t.rawValue)
            }
        }
        .fixedSize()
    }

    // MARK: Avisos

    @ViewBuilder private var banners: some View {
        if isLive {
            LiveHero()
        } else if session.finished == lecture {
            FinishedCard(lecture: lecture).transition(.move(edge: .top).combined(with: .opacity))
        } else if let p = processor.progress[lecture.persistentModelID] {
            Banner(icon: "sparkles", text: p.step + "…") {
                ProgressView(value: p.fraction).frame(width: 120)
                Button("Cancelar") { processor.cancel(lecture) }
            }
        } else if lecture.status == .processing {
            // Procesado interrumpido (la app se cerró a mitad).
            Banner(icon: "sparkles", text: "Los apuntes de esta clase no llegaron a generarse.") {
                Button("Generar") { processor.process(lecture) }
            }
        } else if let error = lecture.processingError {
            Banner(icon: "exclamationmark.triangle", text: error, tint: .orange) {
                if !lecture.segments.isEmpty {
                    Button(lecture.summary == nil ? "Generar apuntes" : "Reintentar") { processor.process(lecture) }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch shownTab {
        case .transcript: TranscriptTab(lecture: lecture, isLive: isLive, target: $target)
        case .summary: SummaryTab(lecture: lecture)
        case .notes: NotesTab(lecture: lecture)
        case .material: MaterialTab(lecture: lecture, isLive: isLive, target: $target)
        case .mine: MyNotesTab(lecture: lecture)
        case .ask: ChatTab(lecture: lecture)
        }
    }
}

// MARK: - Piezas comunes

/// Ancho cómodo de lectura para el texto largo; el fondo sigue ocupando toda la columna.
private let readingWidth: CGFloat = 720

/// Botón pequeño con el minuto de la transcripción del que sale un dato.
private struct TimeChip: View {
    let segment: TranscriptSegment
    var number: Int?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(CiteLink.url(segment)) } label: {
            HStack(spacing: 3) {
                if let number { Text("\(number)").fontWeight(.bold) }
                Image(systemName: "play.fill").font(.system(size: 7))
                Text(TimeFormat.clock(segment.start))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.subtle, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardBorder))
        }
        .buttonStyle(.plain)
        .help("Ir a este momento de la transcripción")
    }
}

// MARK: - Resumen

private struct SummaryTab: View {
    let lecture: Lecture

    var body: some View {
        if let summary = lecture.summary {
            let cited = Cited(summary, index: SourceIndex(lecture))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GeneratedHeader(lecture: lecture)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(cited.blocks.enumerated()), id: \.offset) { i, block in
                            switch block {
                            case .paragraph(let text):
                                // La idea central abre el resumen destacada; el resto de párrafos, texto normal.
                                if i == 0, cited.hasSections {
                                    Text(text).font(.system(size: 14, weight: .medium)).lineSpacing(6)
                                        .padding(16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .leading) {
                                            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(Theme.highlightEdge).frame(width: 4)
                                        }
                                } else {
                                    Text(text).font(.system(size: 14)).lineSpacing(6)
                                }
                            case .heading(let title):
                                Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).padding(.top, 10)
                            case .bullet(let text):
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(Theme.gradient).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                    Text(text).font(.system(size: 14)).lineSpacing(5)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)

                    if !cited.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Fuentes en la transcripción").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(cited.sources, id: \.number) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    TimeChip(segment: s.segment, number: s.number)
                                    Text(s.segment.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }

                    if !lecture.reviewQuestions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Preguntas de repaso", systemImage: "graduationcap.fill")
                                .font(.headline).foregroundStyle(Theme.ink)
                            ForEach(Array(lecture.reviewQuestions.enumerated()), id: \.offset) { i, q in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        .frame(width: 22, height: 22).background(Theme.gradient, in: Circle())
                                    Text(q).font(.system(size: 13)).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                }
                .frame(maxWidth: readingWidth, alignment: .leading)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            PendingView(lecture: lecture, title: "Aún no hay resumen", icon: "text.badge.star")
        }
    }

    /// El resumen con un numerito volado tras cada idea, enlazado al párrafo de la transcripción del que sale.
    /// Lee el formato de `StudyAI.summaryMarkdown` («### tema», «- punto»); un resumen antiguo son solo párrafos.
    struct Cited {
        enum Block { case paragraph(AttributedString), heading(String), bullet(AttributedString) }
        var blocks: [Block] = []
        var sources: [(number: Int, segment: TranscriptSegment)] = []
        var hasSections = false

        init(_ summary: String, index: SourceIndex) {
            var numbers: [Double: Int] = [:]
            let lines = summary.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for line in lines {
                if line.hasPrefix("### ") {
                    blocks.append(.heading(String(line.dropFirst(4))))
                    hasSections = true
                    continue
                }
                let bullet = line.hasPrefix("- ")
                let sentences = Chunker.sentences(bullet ? String(line.dropFirst(2)) : line).map { ($0, index.source(for: $0)) }
                var text = AttributedString()
                for (i, (sentence, segment)) in sentences.enumerated() {
                    text += AttributedString((i > 0 ? " " : "") + sentence)
                    // Varias frases seguidas de la misma fuente llevan un solo número, al final.
                    guard let segment, sentences[safe: i + 1]?.1?.start != segment.start else { continue }
                    let n = numbers[segment.start] ?? (numbers.count + 1)
                    if numbers[segment.start] == nil { numbers[segment.start] = n; sources.append((n, segment)) }
                    var mark = AttributedString("\u{2009}\(n)")
                    mark.font = .system(size: 10, weight: .bold)
                    mark.baselineOffset = 6
                    mark.foregroundColor = Theme.ink
                    mark.link = CiteLink.url(segment)
                    text += mark
                }
                blocks.append(bullet ? .bullet(text) : .paragraph(text))
            }
        }
    }
}

/// Cabecera de lo que escribe la IA: de dónde sale y el botón para rehacerlo desde la transcripción guardada.
private struct GeneratedHeader: View {
    let lecture: Lecture
    @Environment(LectureProcessor.self) private var processor
    @Environment(RecordingSession.self) private var session
    @State private var confirm = false

    var body: some View {
        let busy = processor.progress[lecture.persistentModelID] != nil
        HStack(spacing: 10) {
            Label("Escrito por la IA a partir de la transcripción", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                if lecture.summaryEdited { confirm = true } else { processor.process(lecture) }
            } label: {
                Label(busy ? "Generando…" : "Volver a generar", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Theme.subtle, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || session.lecture == lecture || lecture.segments.isEmpty)
            .help("Rehace el resumen, los apuntes y las preguntas a partir de la transcripción. Lo actual se mantiene hasta que lo nuevo esté listo.")
        }
        .confirmationDialog("¿Volver a generar el resumen?", isPresented: $confirm) {
            Button("Volver a generar") { processor.process(lecture) }
        } message: {
            Text("Este resumen tiene texto añadido desde el chat. Al generarlo de nuevo se sustituye entero. Tus notas no se tocan.")
        }
    }
}

/// Vista de espera común: procesando, o explica por qué no hay contenido.
private struct PendingView: View {
    let lecture: Lecture
    let title: String
    let icon: String
    @Environment(LectureProcessor.self) private var processor
    @Environment(RecordingSession.self) private var session

    var body: some View {
        if session.lecture == lecture {
            LiveStudio(lecture: lecture)
        } else if let p = processor.progress[lecture.persistentModelID] {
            VStack(spacing: 16) {
                ThinkingSphere(size: 170)
                Text(p.step + "…").font(.headline)
                ProgressView(value: p.fraction).frame(width: 220).tint(Theme.ink)
                Text("Puedes seguir usando el Mac: se hace en segundo plano.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 14) {
                ThinkingSphere(size: 120, dots: 300).opacity(0.8)
                Text(title).font(.title3.weight(.semibold))
                if session.lecture == lecture {
                    EmptyView()
                } else if lecture.segments.isEmpty {
                    Text("No hay nada que resumir: no llegó voz a la grabación.").foregroundStyle(.secondary)
                } else {
                    Text("La IA del Mac prepara el resumen, los apuntes y preguntas de repaso en unos minutos.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button { processor.process(lecture) } label: { Label("Generar con IA", systemImage: "sparkles") }
                        .buttonStyle(ProminentButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Apuntes

private struct NotesTab: View {
    let lecture: Lecture

    struct Section: Identifiable {
        let id: Int
        var title: String
        var points: [String] = []
        var terms: [(String, String)] = []
    }

    var body: some View {
        if let markdown = lecture.notesMarkdown, !markdown.isEmpty {
            let index = SourceIndex(lecture)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    GeneratedHeader(lecture: lecture)
                    ForEach(Self.parse(markdown)) { section in
                        card(section, index: index)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: readingWidth, alignment: .leading)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            PendingView(lecture: lecture, title: "Aún no hay apuntes", icon: "list.bullet.rectangle")
        }
    }

    private func card(_ section: Section, index: SourceIndex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(section.id + 1)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Theme.gradient, in: RoundedRectangle(cornerRadius: 6))
                Text(section.title).font(.title3.weight(.semibold))
            }
            ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(Theme.gradient).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(point).font(.system(size: 13)).lineSpacing(3)
                    Spacer(minLength: 8)
                    if let segment = index.source(for: point) { TimeChip(segment: segment) }
                }
            }
            if !section.terms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(section.terms.enumerated()), id: \.offset) { _, t in
                        Text("\(Text(t.0).bold().foregroundStyle(Theme.ink))  \(Text(t.1).foregroundStyle(.secondary))")
                            .font(.system(size: 13))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(Theme.highlightEdge).frame(width: 4)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Lee el formato que escribe `StudyAI.markdown`: «### título», «- punto», «- **término**: definición».
    static func parse(_ markdown: String) -> [Section] {
        var sections: [Section] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                sections.append(Section(id: sections.count, title: String(line.dropFirst(4))))
            } else if line.hasPrefix("- "), !sections.isEmpty {
                let body = String(line.dropFirst(2))
                if body.hasPrefix("**"), let close = body.range(of: "**:", range: body.index(body.startIndex, offsetBy: 2)..<body.endIndex) {
                    let term = String(body[body.index(body.startIndex, offsetBy: 2)..<close.lowerBound])
                    let def = body[close.upperBound...].trimmingCharacters(in: .whitespaces)
                    sections[sections.count - 1].terms.append((term, def))
                } else {
                    sections[sections.count - 1].points.append(body)
                }
            }
        }
        return sections
    }
}

// MARK: - Mis notas

/// Notas libres de Ana. Se guardan solas, salen en la exportación y en lo que se pasa a ChatGPT.
private struct MyNotesTab: View {
    @Bindable var lecture: Lecture
    @Environment(\.modelContext) private var context
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lo que quieras apuntar de esta clase: dudas, lo que entra en el examen, ideas propias…")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $lecture.userNotes)
                .font(.system(size: 14))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(14)
                .card()
        }
        .frame(maxWidth: readingWidth, alignment: .leading)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if lecture.userNotes.isEmpty { focused = true } }
        .onDisappear { try? context.save() }
    }
}

// MARK: - Transcripción

private struct TranscriptTab: View {
    let lecture: Lecture
    let isLive: Bool
    @Binding var target: Double?
    @Environment(LectureProcessor.self) private var processor
    @State private var following = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Transcripción", systemImage: "text.quote").font(.headline)
                Spacer()
                if isLive {
                    Label("en directo", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.recording)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            list.frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var list: some View {
        let segments = lecture.orderedSegments
        if segments.isEmpty && !isLive {
            if processor.progress[lecture.persistentModelID] != nil {
                PendingView(lecture: lecture, title: "", icon: "")
            } else {
                ContentUnavailableView("Sin transcripción", systemImage: "waveform.slash")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { i, segment in
                            row(segment, previous: segments[..<i].last { !$0.isGap }).id(segment.start)
                        }
                        if isLive { LiveLine(onGrow: { if following { proxy.scrollTo("live", anchor: .bottom) } }).id("live") }
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(isLive ? .bottom : .top)
                // En directo sigue al final mientras Ana no suba a releer; al volver abajo, sigue otra vez.
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 60
                } action: { _, atBottom in following = atBottom }
                .onChange(of: segments.count) { if isLive && following { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("live", anchor: .bottom) } } }
                .overlay(alignment: .bottom) {
                    if isLive && !following {
                        Button {
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("live", anchor: .bottom) }
                            following = true
                        } label: {
                            Label("Ir al directo", systemImage: "arrow.down")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Theme.gradient, in: Capsule())
                                .shadow(color: Theme.violet.opacity(0.4), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: following)
                .onAppear { scroll(proxy) }
                .onChange(of: target) { scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target else { return }
        // La lista es perezosa: se espera un ciclo para que exista la fila de destino.
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) } }
    }

    @ViewBuilder private func row(_ segment: TranscriptSegment, previous: TranscriptSegment?) -> some View {
        let highlighted = !segment.isGap && segment.start == target
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(TimeFormat.clock(segment.start)).font(.caption2.monospacedDigit())
                .foregroundStyle(highlighted ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.quaternary))
                .frame(width: 40, alignment: .trailing)
            if segment.isGap {
                Label(segment.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // El nombre solo cuando cambia quien habla.
                    if let speaker = segment.speaker, speaker != previous?.speaker {
                        Label(speaker, systemImage: "person.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.speakerColor(speaker))
                    }
                    Text(segment.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, highlighted ? 10 : 0)
        .padding(.trailing, highlighted ? 12 : 0)
        .contentShape(Rectangle())
        .onTapGesture { if !segment.isGap { target = segment.start } }
        .background(highlighted ? Theme.highlight : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if highlighted {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(Theme.highlightEdge).frame(width: 4)
            }
        }
        .animation(.easeOut(duration: 0.3), value: highlighted)
    }
}

/// Única vista que observa el texto provisional: así la lista de segmentos no se redibuja con cada palabra.
private struct LiveLine: View {
    var onGrow: () -> Void = {}
    @Environment(RecordingSession.self) private var session

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            HStack(spacing: 4) {
                Circle().fill(Theme.recording).frame(width: 6, height: 6)
                Text("ahora").font(.caption2.weight(.semibold)).foregroundStyle(Theme.recording)
            }
            .frame(width: 40, alignment: .trailing)
            Text(session.liveText.isEmpty ? "Escuchando…" : session.liveText)
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(10)
        .background(Theme.recording.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: session.liveText) { onGrow() }
    }
}

/// Cabecera mientras se graba: tiempo, ondas reales y los controles, en grande.
private struct LiveHero: View {
    @Environment(RecordingSession.self) private var session

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Theme.recording.opacity(0.15)).frame(width: 40, height: 40)
                Circle().fill(Theme.recording).frame(width: 12, height: 12)
                    .shadow(color: Theme.recording.opacity(0.8), radius: 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.caption.weight(.semibold)).foregroundStyle(session.phase == .recording ? Theme.recording : .orange)
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            SpectrumBars(session: session, height: 34, barWidth: 5, spacing: 4, colors: [Theme.indigo, Theme.glow])
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if session.phase == .recording {
                    Button { session.pause() } label: { Label("Pausar", systemImage: "pause.fill") }
                } else if session.phase == .paused {
                    Button { session.resume() } label: { Label("Seguir", systemImage: "play.fill") }
                }
                Button { Task { await session.finish() } } label: { Label("Finalizar", systemImage: "stop.fill") }
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(session.phase == .finishing)
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Theme.recording.opacity(0.08), Theme.violet.opacity(0.08)], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.recording.opacity(0.18)))
    }

    private var status: String {
        switch session.phase {
        case .recording: session.silentFor > 60 ? "NO LLEGA SONIDO" : "GRABANDO"
        case .paused: "EN PAUSA"
        case .reconnecting: "RECUPERANDO EL AUDIO"
        case .finishing: "GUARDANDO"
        case .failed: "SE DETUVO"
        default: "EMPEZANDO"
        }
    }
}

/// Lo que se ve en Resumen y Apuntes mientras se graba: lo que se está diciendo, en grande, y cómo va la clase.
private struct LiveStudio: View {
    let lecture: Lecture
    @Environment(RecordingSession.self) private var session

    var body: some View {
        let last = lecture.orderedSegments.last { !$0.isGap }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    stat("\(lecture.wordCount.formatted())", "palabras")
                    stat("\(lecture.segments.filter { !$0.isGap }.count)", "párrafos")
                    stat(TimeFormat.clock(session.elapsed), "grabado")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Ahora mismo", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(Theme.recording)
                    Text(Self.tail(session.liveText.isEmpty ? (last?.text ?? "Escuchando la clase…") : session.liveText))
                        .font(.system(size: 20, weight: .medium)).lineSpacing(8)
                        .foregroundStyle(session.liveText.isEmpty ? .secondary : .primary)
                        .animation(.easeOut(duration: 0.2), value: session.liveText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(22)
                .card()
                HStack(spacing: 12) {
                    ThinkingSphere(size: 56, dots: 220)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("El resumen se escribe solo al finalizar").font(.headline)
                        Text("Sigue viendo la clase con normalidad. Al pulsar Finalizar, EstudIA prepara el resumen, los apuntes y las preguntas de repaso.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: readingWidth, alignment: .leading)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Lo último que se ha dicho: si el profesor no hace pausas, el texto provisional crece sin fin.
    static func tail(_ text: String, max: Int = 320) -> String {
        guard text.count > max else { return text }
        let cut = text.suffix(max)
        return "…" + (cut.firstIndex(of: " ").map { String(cut[cut.index(after: $0)...]) } ?? String(cut))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.ink).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Chat

/// Chat sobre la clase. Responde con los minutos de los que saca la respuesta y, si se le pide,
/// añade texto al resumen o a «Mis notas», siempre con «Deshacer».
private struct ChatTab: View {
    @Bindable var lecture: Lecture
    @Environment(\.modelContext) private var context

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var sources: [TranscriptSegment] = []
        var change: Change?
    }
    /// Un cambio aplicado: guarda el valor anterior para deshacerlo.
    struct Change {
        let toSummary: Bool
        let previous: String?
        var undone = false
    }
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var thinking = false
    @FocusState private var focused: Bool

    private let suggestions = ["Explícame la idea principal como si tuviera 15 años", "¿Qué es lo más probable que caiga en el examen?",
                               "Añade al resumen un ejemplo práctico", "Apúntame en mis notas las fechas y artículos citados"]

    var body: some View {
        VStack(spacing: 0) {
            if case .unavailable(let reason) = AIAvailability.current {
                Banner(icon: "exclamationmark.triangle", text: reason, tint: .orange).padding(24)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty { intro }
                        ForEach($messages) { $m in bubble($m) }
                        if thinking {
                            HStack(spacing: 6) {
                                ThinkingSphere(size: 30, dots: 140)
                                Text("Pensando…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: readingWidth, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                composer
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pregunta lo que quieras sobre esta clase, o pídeme que añada algo al resumen o a tus notas.", systemImage: "sparkles")
                .foregroundStyle(.secondary)
            FlowChips(items: suggestions) { send($0) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Escribe un mensaje…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Theme.gradient, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .card()
        .padding(16)
    }

    @ViewBuilder private func bubble(_ m: Binding<Message>) -> some View {
        let msg = m.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            Text(msg.text).textSelection(.enabled)
            if let change = msg.change {
                HStack(spacing: 8) {
                    Image(systemName: change.undone ? "arrow.uturn.backward" : "checkmark.circle.fill")
                        .foregroundStyle(change.undone ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.ink))
                    Text(change.undone ? "Deshecho" : change.toSummary ? "Añadido al resumen" : "Añadido a «Mis notas»")
                        .font(.caption.weight(.semibold))
                    if !change.undone {
                        Button("Deshacer") { undo(m) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if !msg.sources.isEmpty {
                HStack(spacing: 6) {
                    Text("En la clase:").font(.caption).foregroundStyle(.secondary)
                    ForEach(msg.sources, id: \.start) { TimeChip(segment: $0) }
                }
            }
        }
        .padding(12)
        .background(msg.fromUser ? AnyShapeStyle(Theme.ink.opacity(0.14)) : AnyShapeStyle(Theme.card), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(msg.fromUser ? .clear : Theme.cardBorder))
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: msg.fromUser ? .trailing : .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        let history = messages.map { (fromUser: $0.fromUser, text: $0.text) }
        withAnimation(.easeOut(duration: 0.2)) { messages.append(Message(fromUser: true, text: q)) }
        draft = ""
        thinking = true
        let transcript = lecture.transcriptText
        let summary = lecture.summary
        let language = lecture.language
        Task {
            var reply: Message
            do {
                let r = try await StudyAI.chat(q, history: history, transcript: transcript, summary: summary, language: language)
                // Si añade algo, se enseña lo añadido: lo que se ve es lo que queda guardado.
                let shown = r.action == .none || r.addition.isEmpty ? r.answer : r.addition
                reply = Message(fromUser: false, text: shown, sources: SourceIndex(lecture).sources(in: shown))
                reply.change = apply(r)
            } catch {
                reply = Message(fromUser: false, text: "No pude responder: \(error.localizedDescription)")
            }
            withAnimation(.easeOut(duration: 0.2)) { messages.append(reply) }
            thinking = false
            focused = true
        }
    }

    private func apply(_ r: ChatReply) -> Change? {
        let addition = r.addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lecture.isGone, !addition.isEmpty else { return nil }
        switch r.action {
        case .none:
            return nil
        case .addToSummary:
            let previous = lecture.summary
            lecture.summary = [previous, addition].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            lecture.summaryEdited = true
            try? context.save()
            return Change(toSummary: true, previous: previous)
        case .addToNotes:
            let previous = lecture.userNotes
            lecture.userNotes = [previous, addition].filter { !$0.isEmpty }.joined(separator: "\n\n")
            try? context.save()
            return Change(toSummary: false, previous: previous)
        }
    }

    private func undo(_ m: Binding<Message>) {
        guard var change = m.wrappedValue.change, !change.undone, !lecture.isGone else { return }
        if change.toSummary { lecture.summary = change.previous } else { lecture.userNotes = change.previous ?? "" }
        try? context.save()
        change.undone = true
        m.wrappedValue.change = change
    }
}

/// Sugerencias como chips que saltan de línea.
private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item).font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.cardBorder))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).last.map { CGSize(width: proposal.width ?? $0.maxX, height: $0.maxY) } ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in rows(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return frames
    }
}

// MARK: - ChatGPT

/// Preguntar a ChatGPT (o Claude) sobre la clase sin pegar nada: con EstudIA conectado como MCP, se abre su app
/// con la pregunta escrita y el asistente lee la clase por su cuenta (herramientas leer_clase, buscar…).
/// Sin la app de ChatGPT instalada, se abre chatgpt.com con la clase en la dirección (?q=, hasta ~55 000 caracteres).
private struct ChatGPTButton: View {
    let lecture: Lecture
    var compact = false
    @State private var asking = false
    @State private var question = ""
    @State private var connected = AssistantLink.chatgpt.isConnected
    @State private var justConnected = false
    @State private var problem: String?

    static let suggestions = ["Hazme un test de 10 preguntas", "Explícamelo como si empezara de cero",
                              "Hazme un esquema para estudiar", "¿Qué es lo más probable que caiga en el examen?"]

    var body: some View {
        Button { connected = AssistantLink.chatgpt.isConnected; asking = true } label: {
            Label {
                Text(compact ? "ChatGPT" : "Preguntar a ChatGPT")
            } icon: {
                // Logo oficial de OpenAI (Resources/Assets.xcassets), en el color del texto.
                Image("OpenAI").resizable().scaledToFit().frame(width: 18, height: 18)
            }
        }
        .buttonStyle(ChipStyle(kind: .chatgpt))
        .disabled(lecture.segments.isEmpty)
        .help(lecture.segments.isEmpty ? "Esta clase no tiene transcripción: no hay nada que preguntar" : "Pregunta a ChatGPT por esta clase")
        .popover(isPresented: $asking, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image("OpenAI").resizable().scaledToFit().frame(width: 20, height: 20)
                Text("Preguntar a ChatGPT").font(.headline)
            }
            if AssistantLink.chatgpt.isInstalled && !connected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Conecta EstudIA con ChatGPT y podrá leer tus clases por sí mismo, sin copiar ni pegar nada.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Conectar con ChatGPT") { connect() }.buttonStyle(ProminentButtonStyle())
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
                .padding(12)
                .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 10))
            } else {
                if justConnected {
                    Label("Conectado. Si ChatGPT ya estaba abierto, ciérralo y ábrelo una vez. La primera vez te pedirá confiar en la carpeta «Asistente»: acéptalo, solo tiene instrucciones.", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.successColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("¿Qué quieres saber de esta clase?", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .onSubmit { send(question) }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button { send(s) } label: {
                            Label(s, systemImage: "arrow.up.right").font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text(connected ? "Se abre ChatGPT (modo Work) con la pregunta: pulsa Enter." : "Se abre chatgpt.com con la clase: pulsa Enter.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Abrir") { send(question) }.buttonStyle(ProminentButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func connect() {
        do {
            try AssistantLink.chatgpt.connect()
            connected = true; justConnected = true; problem = nil
        } catch {
            problem = "No se pudo conectar: \(error.localizedDescription)"
        }
    }

    private func send(_ ask: String) {
        let q = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = q.isEmpty ? "dime en pocas frases de qué trata" : q
        if connected {
            // Corto: ChatGPT lee la clase con la herramienta de EstudIA.
            AssistantLink.chatgpt.ask("En EstudIA, la clase «\(lecture.displayTitle)» (id \(LibraryMirror.id(lecture))): \(wanted)")
        } else {
            openWeb(wanted)
        }
        asking = false
        question = ""
    }

    /// Sin la app de ChatGPT: la clase va en la dirección de chatgpt.com (sin transcripción si no cabe).
    private func openWeb(_ q: String) {
        let intro = "Te paso una clase de mi carrera (resumen, apuntes, mis notas y la transcripción con los minutos; puede tener errores de reconocimiento). Responde usando la clase y dime el minuto cuando cites algo."
        let full = "\(intro)\n\nMi pregunta: \(q)\n\n\(lecture.markdown())"
        let text = Self.url(full) != nil ? full : (full.components(separatedBy: "\n## Transcripción").first ?? full)
        if let url = Self.url(text) ?? Self.url(String(text.prefix(15_000))) { NSWorkspace.shared.open(url) }
    }

    /// chatgpt.com/?q= ; nil si pasa del límite que acepta el servidor (medido: 60 000 sí, 120 000 no).
    static func url(_ text: String) -> URL? {
        var c = URLComponents(string: "https://chatgpt.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let u = c.url, u.absoluteString.count <= 55_000 else { return nil }
        return u
    }
}

/// Botones de la cabecera con forma y color propios: ChatGPT en blanco y negro como su marca, eliminar en rojo.
private struct ChipStyle: ButtonStyle {
    enum Kind { case chatgpt, danger }
    let kind: Kind
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration, kind: kind, iconOnly: iconOnly) }

    private struct Chip: View {
        let configuration: Configuration
        let kind: Kind
        let iconOnly: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let (fg, bg): (Color, Color) = switch kind {
            case .chatgpt: (Color(nsColor: .windowBackgroundColor), .primary)
            case .danger: (hover ? .white : Theme.recording, hover ? Theme.recording : Theme.recording.opacity(0.12))
            }
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, iconOnly ? 0 : 14)
                .frame(width: iconOnly ? 30 : nil, height: 30)
                .background(bg, in: Capsule())
                .shadow(color: .black.opacity(hover && enabled ? 0.2 : 0), radius: 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.96 : hover && enabled ? 1.03 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 && enabled }
                .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}

/// Para cambiar el estilo de la etiqueta según el sitio disponible.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
