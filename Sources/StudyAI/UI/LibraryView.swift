import AppKit
import StudyAICore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Ventana principal: portada con las clases en tarjetas y, al abrir una, la clase a pantalla completa.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(RecordingSession.self) private var session
    @Environment(LectureProcessor.self) private var processor
    @Query(sort: \Lecture.createdAt, order: .reverse) private var lectures: [Lecture]

    @State private var open: Lecture?
    @State private var folder: Folder?
    @AppStorage("classLanguage") private var language: ClassLanguage = .spanish
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView().transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let open, !open.isGone {
                LectureDetailView(lecture: open) { self.open = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                HomeView(folder: $folder, open: $open, importFiles: importWithPanel)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: open?.persistentModelID)
        .animation(.easeInOut(duration: 0.25), value: showSettings)
        .background(Theme.canvas.ignoresSafeArea())
        // macOS 26 pasa el contenido por debajo de la barra con un difuminado: con «hard» queda una barra
        // opaca con su línea, y lo que se desplaza no se ve a través de los botones de la ventana.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Barra sólida del color del fondo: sin franja negra y lo que se desplaza pasa por debajo, no a través.
        .toolbarBackground(Theme.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .navigationTitle(showSettings ? "Ajustes" : open == nil && folder == nil ? "EstudIA" : "")
        .toolbar {
            if showSettings || open != nil || folder != nil {
                ToolbarItem(placement: .navigation) {
                    Button { if showSettings { showSettings = false } else if open != nil { open = nil } else { folder = nil } } label: {
                        Label(showSettings ? (open != nil ? "Clase" : folder?.title ?? "Inicio") : open != nil ? (folder?.title ?? "Inicio") : "Inicio", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Volver (⌘[)")
                    .keyboardShortcut("[")
                }
            }
        }
        // Atajos de teclado sin botón en la barra: las acciones están a la vista en la portada.
        .background {
            Group {
                Button("Importar", action: importWithPanel).keyboardShortcut("i").disabled(session.isActive)
                Button("Grabar o finalizar") {
                    Task { session.isActive ? await session.finish() : await session.start(subject: folder?.subject, language: language) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.phase == .finishing || session.phase == .starting)
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .onAppear {
            showOnboarding = !onboardingDone || !ScreenAudioPermission.isGranted
            runLaunchArguments()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { onboardingDone = true; showOnboarding = false }
        }
        .alert("No se pudo empezar a grabar", isPresented: Binding(
            get: { session.startProblem != nil }, set: { if !$0 { session.startProblem = nil } }),
            presenting: session.startProblem
        ) { problem in
            switch problem {
            case .permission: Button("Abrir Ajustes") { ScreenAudioPermission.openSystemSettings() }
            case .language: Button("Descargar ahora") { showOnboarding = true }
            case .other: EmptyView()
            }
            Button("Aceptar", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
        // Al empezar a grabar se abre la clase para ver la transcripción en directo.
        .onChange(of: session.lecture) { _, new in if let new { open = new } }
        .onReceive(NotificationCenter.default.publisher(for: OpenLecture.notification)) { note in
            showSettings = false
            if let lecture = note.object as? Lecture { open = lecture }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShowSettings.notification)) { _ in showSettings = true }
        .tint(Theme.ink)
    }

    // MARK: Importar

    static let mediaTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .quickTimeMovie]

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return mediaTypes.contains { type.conforms(to: $0) }
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.mediaTypes
        panel.allowsMultipleSelection = true
        panel.message = "Elige la grabación de la clase (audio o vídeo)"
        guard panel.runModal() == .OK else { return }
        let imported = panel.urls.map { processor.importFile($0, subject: folder?.subject, language: language) }
        if imported.count == 1 { open = imported[0] }
    }

    /// Para probar sin pulsar nada (ver README):
    ///   `--import <fichero>`, `--open-latest`, `--size 800x600` (tamaño de ventana),
    ///   `--record-for <s>` (graba de verdad y finaliza sola) con `--script "pause@10,resume@20,drop@30"` opcional.
    private func runLaunchArguments() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args[safe: $0 + 1] } }
                if let lang = value("--lang") { language = lang == "en" ? .english : .spanish }
        if let path = value("--import") { open = processor.importFile(URL(fileURLWithPath: path), subject: folder?.subject, language: language) }
        if args.contains("--open-latest") { open = lectures.first }
        if let path = value("--add-material"), let lecture = lectures.first {
            open = lecture
            Task { _ = try? await Materials.add(URL(fileURLWithPath: path), to: lecture, context: context) }
        }
        if args.contains("--settings") { showSettings = true }
        if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.setContentSize(CGSize(width: size[0], height: size[1]))
            }
        }
        if let seconds = value("--record-for").flatMap(Double.init) {
            let steps = (value("--script") ?? "").split(separator: ",").compactMap { step -> (String, Double)? in
                let parts = step.split(separator: "@")
                guard parts.count == 2, let at = Double(parts[1]) else { return nil }
                return (String(parts[0]), at)
            }
            Task {
                try? await Task.sleep(for: .seconds(2)) // como una persona: con la ventana ya dibujada
                await session.start(subject: folder?.subject, language: language)
                let began = Date()
                for (action, at) in steps.sorted(by: { $0.1 < $1.1 }) {
                    try? await Task.sleep(for: .seconds(max(0, at - Date().timeIntervalSince(began))))
                    NSLog("StudyAI guion: \(action) a los \(Int(Date().timeIntervalSince(began))) s")
                    switch action {
                    case "pause": session.pause()
                    case "resume": session.resume()
                    case "drop": await session.simulateCaptureLoss()
                    case "crash": _exit(9) // cierre en seco, sin el guardado ordenado: como un cuelgue o quedarse sin batería
                    default: break
                    }
                }
                try? await Task.sleep(for: .seconds(max(0, seconds - Date().timeIntervalSince(began))))
                await session.finish()
            }
        }
    }
}

enum HomeGreeting {
    static func salute(name: String, now: Date = .now) -> String {
        let h = Calendar.current.component(.hour, from: now)
        let base = h < 6 ? "Buenas noches" : h < 14 ? "Buenos días" : h < 21 ? "Buenas tardes" : "Buenas noches"
        return name.isEmpty ? base : "\(base), \(name)"
    }
}

