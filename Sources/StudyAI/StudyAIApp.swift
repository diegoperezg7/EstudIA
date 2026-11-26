import SwiftData
import SwiftUI

struct StudyAIApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let container: ModelContainer
    @State private var session: RecordingSession
    @State private var processor: LectureProcessor

    init() {
        let container: ModelContainer
        do { container = try Store.container() } catch { fatalError("No se pudo abrir la base de datos: \(error)") }
        self.container = container
        let session = RecordingSession(context: container.mainContext)
        let processor = LectureProcessor(context: container.mainContext)
        session.onFinished = { lecture in
            if lecture.status == .processing { processor.process(lecture) }
        }
        _session = State(initialValue: session)
        _processor = State(initialValue: processor)
        Self.recoverInterruptedRecordings(container.mainContext)
        Store.mergeShortParagraphs(container.mainContext)
        AppDelegate.session = session
        ClassDetector.shared.start(session: session)
        _ = Updates.controller
        // Con una biblioteca de prueba no se toca lo que leen ChatGPT y Claude.
        if Store.testDirectory == nil {
            LibraryMirror.start(container.mainContext)
            AssistantLink.refreshConnections()
        }
    }

    var body: some Scene {
        Window("EstudIA", id: "main") {
            LibraryView()
                .frame(minWidth: 720, minHeight: 540)
                .environment(session)
                .environment(processor)
        }
        .modelContainer(container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘, abre los Ajustes dentro de la ventana, no en una aparte.
            CommandGroup(replacing: .appSettings) { SettingsCommand() }
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        }


        // Siempre en la barra de menús: grabar sin abrir la ventana y ver la grabación en curso.
        MenuBarExtra {
            MenuBarPanel()
                .environment(session)
                .environment(processor)
                .modelContainer(container)
        } label: {
            MenuBarLabel(session: session)
        }
        .menuBarExtraStyle(.window)
    }

    /// Una clase que quedó «grabando» es de una sesión anterior que se cerró: su transcripción ya está guardada.
    @MainActor private static func recoverInterruptedRecordings(_ context: ModelContext) {
        let recording = LectureStatus.recording.rawValue
        let stale = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw == recording }))) ?? []
        for lecture in stale {
            lecture.status = .transcriptOnly
            let lastEnd = lecture.segments.map(\.end).max() ?? 0
            // Lo que aún estaba sin cerrar cuando se cortó.
            if let draft = lecture.liveDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
                let segment = TranscriptSegment(start: lastEnd, end: lastEnd, text: draft)
                segment.lecture = lecture
                context.insert(segment)
            }
            lecture.liveDraft = nil
            lecture.duration = max(lecture.duration, lastEnd)
            lecture.processingError = "La grabación se cortó al cerrarse la app. La transcripción hasta ese momento está guardada."
        }
        try? context.save()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var session: RecordingSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) } else { Prefs.applyAppearance() }
    }

    /// Al salir a mitad de grabación se cierra bien la transcripción en lugar de cortar en seco.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let session = Self.session, session.isActive else { return .terminateNow }
            Task {
                await session.finish()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// Al cerrar la ventana sigue en la barra de menús (para grabar o avisar de una clase); se sale desde su menú.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Ajustes…") { openWindow(id: "main"); ShowSettings.post() }.keyboardShortcut(",")
    }
}
