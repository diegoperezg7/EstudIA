import Foundation
import StudyAICore
import SwiftData

/// Deja en disco una copia de las clases (biblioteca.json) para el servidor MCP que leen ChatGPT o Claude.
/// Se rehace unos segundos después de cada guardado: durante una grabación (guarda cada 5 s) espera a que acabe.
@MainActor enum LibraryMirror {
    private static var pending: Task<Void, Never>?
    private static var observer: NSObjectProtocol?

    static func start(_ context: ModelContext) {
        export(context)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    export(context)
                }
            }
        }
    }

    /// Id corto y estable para que ChatGPT la nombre: el instante en que se creó.
    static func id(_ l: Lecture) -> String { String(Int(l.createdAt.timeIntervalSince1970)) }

    static func export(_ context: ModelContext) {
        let lectures = (try? context.fetch(FetchDescriptor<Lecture>())) ?? []
        let lib = LibraryExport(lectures: lectures.map { l in
            .init(id: id(l), title: l.displayTitle, subject: l.subject?.name, date: l.createdAt, duration: l.duration,
                  language: l.language.name, summary: l.summary, notes: l.notesMarkdown, questions: l.reviewQuestions,
                  userNotes: l.userNotes,
                  transcript: l.orderedSegments.filter { !$0.isGap }.map { .init(start: $0.start, text: $0.text, speaker: $0.speaker) })
        })
        try? lib.save()
    }
}
