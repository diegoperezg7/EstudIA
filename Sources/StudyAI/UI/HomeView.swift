import StudyAICore
import SwiftData
import SwiftUI

/// Dónde está Ana en la portada: dentro de una asignatura o en las clases sueltas (nil: la portada).
enum Folder: Hashable {
    case unfiled
    case subject(Subject)

    var subject: Subject? { if case .subject(let s) = self { s } else { nil } }
    var title: String { subject?.name ?? "Sin asignatura" }
}

/// Portada: saludo, la tarjeta para grabar, las asignaturas como carpetas y las últimas clases.
/// Dentro de una asignatura, sus clases por fecha.
struct HomeView: View {
    @Binding var folder: Folder?
    @Binding var open: Lecture?
    let importFiles: () -> Void

    @AppStorage(Prefs.languageKey) private var language: ClassLanguage = .spanish
    @AppStorage(Prefs.nameKey) private var userName = ""
    @Environment(\.modelContext) private var context
    @Environment(RecordingSession.self) private var session
    @Environment(LectureProcessor.self) private var processor
    @Query(sort: \Subject.name) private var subjects: [Subject]
    @Query(sort: \Lecture.createdAt, order: .reverse) private var lectures: [Lecture]

    @State private var search = ""
    @State private var renaming: Lecture?
    /// Hoja de asignatura: nueva (.some(nil)) o editar una (.some(s)).
    @State private var editingSubject: Subject??
    @State private var nameText = ""
    @State private var deletingLecture: Lecture?
    @State private var deletingSubject: Subject?
    @State private var dropTargeted = false
    @State private var width: CGFloat = 1200

    private var unfiled: [Lecture] { lectures.filter { $0.subject == nil } }

    private func inFolder(_ f: Folder) -> [Lecture] {
        switch f {
        case .unfiled: unfiled
        case .subject(let s): lectures.filter { $0.subject == s }
        }
    }

    private var results: [Lecture] {
        let base = folder.map(inFolder) ?? lectures
        guard !search.isEmpty else { return base }
        return base.filter { l in
            [l.title, l.summary ?? "", l.subject?.name ?? "", l.userNotes, l.transcriptPreview].contains { $0.localizedStandardContains(search) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                topBar
                if let folder {
                    folderHeader(folder)
                    RecordHero(fixedSubject: folder.subject, pickSubject: { _ in }, importFiles: importFiles, compact: true)
                    lectureGroups(results, empty: search.isEmpty ? "Aún no hay clases aquí. Graba la siguiente desde arriba." : nil)
                } else if !search.isEmpty {
                    lectureGroups(results, empty: nil)
                } else {
                    RecordHero(fixedSubject: nil, pickSubject: { if $0 { editingSubject = .some(nil) } }, importFiles: importFiles, compact: false)
                    if lectures.isEmpty && subjects.isEmpty { EmptyHome() }
                    subjectsSection
                    if !lectures.isEmpty {
                        section("Últimas clases") {
                            grid(Array(lectures.prefix(6)))
                        }
                    }
                }
            }
            .padding(.horizontal, width < 820 ? 20 : 36)
            .padding(.top, 18)
            .padding(.bottom, 36)
            .animation(.easeOut(duration: 0.2), value: folder)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(Label("Suelta para transcribir", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink))
                    .padding(16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter(LibraryView.isMedia)
            let imported = media.map { processor.importFile($0, subject: folder?.subject, language: language) }
            if imported.count == 1 { open = imported[0] }
            return !media.isEmpty
        } isTargeted: { dropTargeted = $0 && !session.isActive }
        .sheet(isPresented: Binding(get: { editingSubject != nil }, set: { if !$0 { editingSubject = nil } })) {
            SubjectEditor(subject: editingSubject ?? nil) { saved in
                if editingSubject == .some(nil), let saved { folder = .subject(saved) }
                editingSubject = nil
            }
        }
        .alert("Nombre de la clase", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Por ejemplo, Tema 4: teoría del contrato", text: $nameText)
            Button("Guardar") { commitLectureName() }
            Button("Cancelar", role: .cancel) { nameText = "" }
        }
        .confirmationDialog("¿Eliminar «\(deletingLecture?.displayTitle ?? "")»?",
                            isPresented: Binding(get: { deletingLecture != nil }, set: { if !$0 { deletingLecture = nil } }),
                            presenting: deletingLecture) { l in
            Button("Eliminar clase", role: .destructive) {
                processor.cancel(l)
                Materials.removeFiles(of: l)
                context.delete(l)
                try? context.save()
            }
        } message: { _ in
            Text("Se borran la transcripción, los apuntes y tus notas. No se puede deshacer.")
        }
        .confirmationDialog("¿Eliminar la asignatura «\(deletingSubject?.name ?? "")»?",
                            isPresented: Binding(get: { deletingSubject != nil }, set: { if !$0 { deletingSubject = nil } }),
                            presenting: deletingSubject) { s in
            Button("Eliminar asignatura", role: .destructive) {
                if folder?.subject == s { folder = nil }
                context.delete(s)
                try? context.save()
            }
        } message: { s in
            Text(s.lectures.isEmpty ? "No tiene clases." : "Sus \(s.lectures.count) clases no se borran: pasan a «Sin asignatura».")
        }
    }

    // MARK: Cabecera

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            if folder == nil {
                AppLogo(size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HomeGreeting.salute(name: userName.isEmpty ? Prefs.name : userName)).font(.system(size: 23, weight: .bold))
                    Text(lectures.isEmpty ? "Graba tu primera clase y la tendrás resumida al terminar."
                         : "\(lectures.count) \(lectures.count == 1 ? "clase" : "clases") · \(Self.duration(lectures)) grabados")
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .layoutPriority(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(folder == nil ? "Buscar en todas tus clases" : "Buscar en \(folder!.title)", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(minWidth: 140, maxWidth: 280).frame(height: 34)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardBorder))
            Button { ShowSettings.post() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.cardBorder))
            }
            .buttonStyle(.plain)
            .help("Configuración: tu nombre, apariencia, idioma (⌘,)")
        }
    }

    private func folderHeader(_ f: Folder) -> some View {
        let items = inFolder(f)
        return HStack(spacing: 16) {
            SubjectIcon(folder: f, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.system(size: 25, weight: .bold))
                Text("\(items.count) \(items.count == 1 ? "clase" : "clases") · \(Self.duration(items))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let s = f.subject {
                Menu {
                    Button("Editar nombre e icono…") { editingSubject = .some(s) }
                    Button("Eliminar asignatura…", role: .destructive) { deletingSubject = s }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    // MARK: Asignaturas

    private var subjectsSection: some View {
        section("Asignaturas", action: ("Nueva asignatura", { editingSubject = .some(nil) })) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)], spacing: 16) {
                ForEach(subjects) { s in
                    SubjectCard(folder: .subject(s), lectures: s.lectures) { folder = .subject(s) }
                        .contextMenu {
                            Button("Abrir") { folder = .subject(s) }
                            Button("Editar nombre e icono…") { editingSubject = .some(s) }
                            Divider()
                            Button("Eliminar asignatura…", role: .destructive) { deletingSubject = s }
                        }
                }
                if !unfiled.isEmpty {
                    SubjectCard(folder: .unfiled, lectures: unfiled) { folder = .unfiled }
                }
                NewSubjectCard { editingSubject = .some(nil) }
            }
        }
    }

    // MARK: Clases

    @ViewBuilder private func lectureGroups(_ items: [Lecture], empty: String?) -> some View {
        if items.isEmpty {
            if let empty {
                Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                ContentUnavailableView.search(text: search).frame(maxWidth: .infinity).padding(.top, 30)
            }
        }
        ForEach(Self.groups(items), id: \.title) { group in
            section(group.title) { grid(group.lectures) }
        }
    }

    private func grid(_ items: [Lecture]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 16)], spacing: 16) {
            ForEach(items) { lecture in
                LectureCard(lecture: lecture, isLive: session.lecture == lecture, showSubject: folder == nil) {
                    open = lecture
                } actions: {
                    lectureActions(lecture)
                }
                .contextMenu { lectureActions(lecture) }
            }
        }
    }

    @ViewBuilder private func lectureActions(_ lecture: Lecture) -> some View {
        Button("Abrir") { open = lecture }
        Button("Renombrar…") { nameText = lecture.title; renaming = lecture }
        Menu("Mover a") {
            Button("Sin asignatura") { lecture.subject = nil; try? context.save() }
            ForEach(subjects) { s in Button(s.name) { lecture.subject = s; try? context.save() } }
        }
        Divider()
        Button("Eliminar clase…", role: .destructive) { deletingLecture = lecture }
            .disabled(session.lecture == lecture)
    }

    private func section<Content: View>(_ title: String, action: (String, () -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title3.weight(.bold))
                Spacer()
                if let action {
                    Button(action: action.1) { Label(action.0, systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.ink)
                }
            }
            content()
        }
    }

    private func commitLectureName() {
        renaming?.title = nameText.trimmingCharacters(in: .whitespaces)
        nameText = ""
        try? context.save()
    }

    // MARK: Utilidades

    static func duration(_ lectures: [Lecture]) -> String {
        let minutes = Int(lectures.reduce(0) { $0 + $1.duration } / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Hoy, Ayer, Esta semana, y después por mes.
    static func groups(_ lectures: [Lecture]) -> [(title: String, lectures: [Lecture])] {
        let cal = Calendar.current
        var out: [(title: String, lectures: [Lecture])] = []
        for l in lectures {
            let title: String
            if cal.isDateInToday(l.createdAt) { title = "Hoy" }
            else if cal.isDateInYesterday(l.createdAt) { title = "Ayer" }
            else if let days = cal.dateComponents([.day], from: l.createdAt, to: .now).day, days < 7 { title = "Esta semana" }
            else {
                let m = l.createdAt.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "es_ES")))
                title = m.prefix(1).uppercased() + m.dropFirst()
            }
            if out.last?.title == title { out[out.count - 1].lectures.append(l) } else { out.append((title, [l])) }
        }
        return out
    }
}

// MARK: - Tarjeta de grabar

/// La acción principal, a la vista: grabar (con asignatura e idioma) o importar. Mientras graba, el tiempo y Finalizar.
private struct RecordHero: View {
    let fixedSubject: Subject?
    /// Pide crear asignatura (true) desde el menú.
    let pickSubject: (Bool) -> Void
    let importFiles: () -> Void
    let compact: Bool

    @Environment(RecordingSession.self) private var session
    @AppStorage(Prefs.languageKey) private var language: ClassLanguage = .spanish
    @Query(sort: \Subject.name) private var subjects: [Subject]
    @State private var picked: Subject?
    @State private var heroWidth: CGFloat = 1000

    private var subject: Subject? { fixedSubject ?? picked }

    var body: some View {
        let active = session.isActive
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                if active {
                    Label("Grabando · \(session.lecture?.subject?.name ?? "Sin asignatura")", systemImage: "waveform")
                        .font(.headline).foregroundStyle(.white.opacity(0.85))
                    LiveClock().font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(compact ? "Grabar una clase de \(fixedSubject?.name ?? "esta carpeta")" : "Graba una clase")
                            .font(.system(size: compact ? 20 : 26, weight: .bold)).foregroundStyle(.white)
                        if !compact {
                            Text("Ábrela en el navegador o en Zoom y pulsa Grabar; si se te olvida, EstudIA te lo propone. Solo se graba el sonido del Mac, nunca el micrófono.")
                                .foregroundStyle(.white.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if fixedSubject == nil { subjectMenu }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actionButtons(active) }
                    VStack(alignment: .leading, spacing: 10) { actionButtons(active) }
                }
            }
            Spacer(minLength: 0)
            if (!compact || active) && heroWidth > 640 {
                ThinkingSphere(size: compact ? 120 : 190)
                    .environment(\.colorScheme, .dark)
            }
        }
        .padding(compact ? 22 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heroWidth = $0 }
        .background(Theme.night, in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            // Brillo violeta, como el logo.
            Circle().fill(Theme.glow.opacity(0.35)).frame(width: 260).blur(radius: 70).offset(x: 40, y: -90)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.lavender.opacity(0.25)))
        .shadow(color: Theme.violet.opacity(0.18), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: active)
    }

    @ViewBuilder private func actionButtons(_ active: Bool) -> some View {
        Button {
            Task { active ? await session.finish() : await session.start(subject: subject, language: language) }
        } label: {
            Label(active ? "Finalizar" : "Grabar clase", systemImage: active ? "stop.fill" : "record.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? .white : Theme.midnight)
                .padding(.horizontal, 20).frame(height: 40)
                .background(active ? AnyShapeStyle(Theme.recording) : AnyShapeStyle(.white), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.phase == .finishing || session.phase == .starting)
        .help(active ? "Terminar y generar los apuntes (⇧⌘R)" : "Graba el audio del Mac, nunca el micrófono (⇧⌘R)")
        if !active {
            Button(action: importFiles) {
                Label("Importar grabación", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Transcribir un audio o vídeo ya descargado (⌘I). También puedes arrastrarlo aquí.")
        }
    }

    private var subjectMenu: some View {
        Menu {
            Button("Sin asignatura") { picked = nil }
            if !subjects.isEmpty { Divider() }
            ForEach(subjects) { s in Button(s.name) { picked = s } }
            Divider()
            Button("Nueva asignatura…") { pickSubject(true) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                Text(picked?.name ?? "Sin asignatura").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 32)
            .background(.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Asignatura de la clase que vas a grabar")
    }
}

/// Aislado: cambia cuatro veces por segundo y así no redibuja la portada entera.
private struct LiveClock: View {
    @Environment(RecordingSession.self) private var session
    var body: some View { Text(TimeFormat.clock(session.elapsed)).contentTransition(.numericText()) }
}

// MARK: - Asignaturas

/// Icono de la asignatura (o de «Sin asignatura»).
private struct SubjectIcon: View {
    let folder: Folder
    var size: CGFloat = 44

    var body: some View {
        SubjectBadge(symbol: folder.subject.map(SubjectIcons.symbol) ?? "tray.full.fill", name: folder.subject?.name, size: size)
    }
}

private struct SubjectCard: View {
    let folder: Folder
    let lectures: [Lecture]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    SubjectIcon(folder: folder)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(lectures.isEmpty ? "Sin clases todavía"
                         : "\(lectures.count) \(lectures.count == 1 ? "clase" : "clases") · \(HomeView.duration(lectures))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(lectures.sorted { $0.createdAt > $1.createdAt }.prefix(3)) { l in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.speakerColor(folder.title).opacity(0.7)).frame(width: 5, height: 5)
                            Text(l.displayTitle).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(l.createdAt.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES"))))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if lectures.isEmpty {
                        Text("Graba o importa la primera clase.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 50, alignment: .topLeading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(hover ? Theme.highlightEdge.opacity(0.6) : Theme.cardBorder))
            .shadow(color: Theme.midnight.opacity(hover ? 0.14 : 0.05), radius: hover ? 14 : 6, y: hover ? 6 : 2)
            .offset(y: hover ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

private struct NewSubjectCard: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                Text("Nueva asignatura").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(hover ? Theme.ink : .secondary)
            .frame(maxWidth: .infinity, minHeight: 210)
            .background(hover ? Theme.highlight.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(hover ? Theme.highlightEdge : Theme.cardBorder,
                                                                     style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Clases

/// Tarjeta de una clase. Al pasar el ratón aparece «…» con renombrar, mover y eliminar.
private struct LectureCard<Actions: View>: View {
    let lecture: Lecture
    let isLive: Bool
    let showSubject: Bool
    let action: () -> Void
    @ViewBuilder let actions: Actions
    @Environment(LectureProcessor.self) private var processor
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    status
                    if showSubject, let s = lecture.subject {
                        Text(s.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.speakerColor(s.name))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.speakerColor(s.name).opacity(0.12), in: Capsule())
                            .lineLimit(1)
                    }
                    Flag(language: lecture.language, height: 11)
                    Spacer()
                    if lecture.duration > 0 {
                        Text(TimeFormat.clock(lecture.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .opacity(hover ? 0 : 1)
                    }
                }
                Text(lecture.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(lecture.title.isEmpty ? .secondary : .primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(lecture.createdAt.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()
                    .locale(Locale(identifier: "es_ES"))))
                    .font(.caption).foregroundStyle(.secondary)
                Group {
                    if let p = processor.progress[lecture.persistentModelID] {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: p.fraction).controlSize(.small).tint(Theme.ink)
                            Text(p.step + "…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else if isLive {
                        Label("Grabando ahora", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(Theme.recording)
                    } else {
                        Text(lecture.summary ?? lecture.transcriptPreview)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 62, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isLive ? Theme.recording.opacity(0.6) : hover ? Theme.highlightEdge.opacity(0.6) : Theme.cardBorder))
            .shadow(color: Theme.midnight.opacity(hover ? 0.14 : 0.05), radius: hover ? 14 : 6, y: hover ? 6 : 2)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 22)
                    .background(Theme.subtle, in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(12)
            .opacity(hover ? 1 : 0)
            .help("Renombrar, mover o eliminar")
        }
        .offset(y: hover ? -2 : 0)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    @ViewBuilder private var status: some View {
        if isLive {
            Circle().fill(Theme.recording).frame(width: 8, height: 8)
        } else {
            switch lecture.status {
            case .recording, .processing: Image(systemName: "sparkles").foregroundStyle(Theme.ink)
            case .ready: Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ink)
            case .transcriptOnly: Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            }
        }
    }
}

/// Portada sin nada todavía: los tres pasos.
private struct EmptyHome: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            step(1, "books.vertical", "Crea tus asignaturas", "Una carpeta por asignatura; dentro irán sus clases.")
            step(2, "play.rectangle", "Abre la clase", "En Safari o Chrome. Pulsa «Grabar clase» y dale al play.")
            step(3, "sparkles", "Finaliza", "Desde la píldora. En unos minutos tienes resumen, apuntes y preguntas.")
        }
    }

    private func step(_ n: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.ink)
                .frame(width: 42, height: 42).background(Theme.highlight, in: RoundedRectangle(cornerRadius: 12))
            Text("\(n). \(title)").font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
