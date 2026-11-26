import AppKit
import PDFKit
import Quartz
import StudyAICore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Material de la clase junto a la transcripción. Al pulsar un párrafo (o avanzar la clase en directo),
/// el visor salta a la diapositiva de la que se está hablando.
struct MaterialTab: View {
    let lecture: Lecture
    let isLive: Bool
    @Binding var target: Double?
    @Environment(\.modelContext) private var context
    @State private var selected: PersistentIdentifier?
    @State private var adding = false
    @State private var problem: String?
    @State private var dropping = false

    private var materials: [Material] { lecture.materials.sorted { $0.createdAt < $1.createdAt } }
    private var current: Material? { materials.first { $0.persistentModelID == selected } ?? materials.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if materials.isEmpty {
                empty
            } else {
                bar.padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                if let m = current { viewer(m) }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.highlightEdge, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Theme.highlight.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { dropping = $0 }
        .alert("No se pudo añadir el material", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("Vale") {}
        } message: { Text(problem ?? "") }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.ink)
            Text("Material de la clase").font(.title3.weight(.semibold))
            Text("Arrastra aquí las diapositivas (PDF o PowerPoint) o cualquier documento que haya usado el profesor. Se tienen en cuenta en los apuntes y, mientras lees la transcripción, se muestra la diapositiva de la que se habla.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            addButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            ForEach(materials) { m in
                let on = m.persistentModelID == current?.persistentModelID
                Button { selected = m.persistentModelID } label: {
                    Label(m.name, systemImage: icon(m)).lineLimit(1)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : .secondary)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(on ? Theme.subtle : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Theme.cardBorder : .clear))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Abrir con la app predeterminada") { NSWorkspace.shared.open(m.fileURL) }
                    Button("Mostrar en el Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.fileURL]) }
                    Divider()
                    Button("Quitar de esta clase", role: .destructive) { Materials.remove(m, context: context) }
                }
            }
            Spacer()
            addButton(prominent: false)
        }
    }

    private func addButton(prominent: Bool) -> some View {
        Button { pick() } label: {
            Label(adding ? "Añadiendo…" : "Añadir material", systemImage: "paperclip")
        }
        .buttonStyle(prominent ? AnyButtonStyle(ProminentButtonStyle()) : AnyButtonStyle(.bordered))
        .disabled(adding)
    }

    @ViewBuilder private func viewer(_ m: Material) -> some View {
        let segments = lecture.orderedSegments.filter { !$0.isGap }
        let aligned = SlideAligner.align(paragraphs: segments.map(\.text), pages: m.pageTexts)
        // La diapositiva del párrafo elegido; en directo, la del último párrafo.
        let focus = target.flatMap { t in segments.firstIndex { $0.start == t } } ?? (isLive ? segments.indices.last : nil)
        let page = focus.flatMap { aligned[$0] }
        VStack(spacing: 0) {
            if let url = m.pdfURL {
                PDFViewer(url: url, page: page).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QuickLookViewer(url: m.fileURL).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !m.pageTexts.isEmpty { footer(page: page, aligned: aligned, segments: segments, pages: m.pageTexts.count) }
        }
    }

    private func footer(page: Int?, aligned: [Int?], segments: [TranscriptSegment], pages: Int) -> some View {
        HStack(spacing: 10) {
            if let page {
                Label("Diapositiva \(page + 1) de \(pages)", systemImage: "rectangle.on.rectangle")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                let moments = segments.indices.filter { aligned[$0] == page }.prefix(4).map { segments[$0] }
                if !moments.isEmpty {
                    Text("Se habla de ella en").font(.caption).foregroundStyle(.secondary)
                    ForEach(moments, id: \.start) { s in
                        Button { target = s.start } label: {
                            Text(TimeFormat.clock(s.start)).font(.system(size: 11).monospacedDigit())
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.subtle, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Label("Pulsa un párrafo de la transcripción para ver su diapositiva", systemImage: "hand.tap")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Theme.subtle.opacity(0.6))
    }

    private func icon(_ m: Material) -> String {
        switch m.fileURL.pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "pptx", "ppt", "key", "odp": "rectangle.on.rectangle.angled"
        default: "doc"
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Elige las diapositivas o documentos de la clase"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        adding = true
        Task {
            for url in urls {
                do {
                    let m = try await Materials.add(url, to: lecture, context: context)
                    selected = m.persistentModelID
                } catch {
                    problem = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            adding = false
        }
    }
}

private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: PrimitiveButtonStyle>(_ s: S) { make = { AnyView(Button($0).buttonStyle(s)) } }
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(Button($0).buttonStyle(s)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Visor de PDF que salta a la página indicada (y solo cuando cambia: si Ana pasa páginas a mano, la respeta).
struct PDFViewer: NSViewRepresentable {
    let url: URL
    let page: Int?

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url); context.coordinator.shown = nil }
        guard let page, page != context.coordinator.shown, let p = v.document?.page(at: page) else { return }
        context.coordinator.shown = page
        v.go(to: p)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown: Int? }
}

/// Vista Rápida del sistema: presentaciones o documentos que no se pudieron pasar a PDF.
struct QuickLookViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}
