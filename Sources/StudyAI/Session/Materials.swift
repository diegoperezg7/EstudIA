import AppKit
import Foundation
import PDFKit
import StudyAICore
import SwiftData

/// Material de una clase (diapositivas, PDF, apuntes del profesor). El fichero se copia a la carpeta de la app:
/// si Ana borra o mueve el original, la clase lo sigue teniendo.
@Model final class Material {
    var name: String
    var createdAt: Date
    /// Carpeta propia dentro de Materiales/, con el original y, si es una presentación, su copia en PDF.
    var folder: String
    var fileName: String
    /// PDF generado a partir de la presentación para poder saltar de diapositiva. nil si es un PDF o no se pudo.
    var pdfName: String?
    /// Texto de cada página o diapositiva, para emparejarlas con lo que se dice y para los apuntes.
    var pageTexts: [String] = []
    var lecture: Lecture?

    init(name: String, folder: String, fileName: String) {
        self.name = name
        self.createdAt = .now
        self.folder = folder
        self.fileName = fileName
    }

    var directory: URL { Materials.root.appending(path: folder, directoryHint: .isDirectory) }
    var fileURL: URL { directory.appending(path: fileName) }
    /// Lo que se enseña con salto de página: el propio PDF o la copia en PDF de la presentación.
    var pdfURL: URL? {
        if let pdfName { return directory.appending(path: pdfName) }
        return fileURL.pathExtension.lowercased() == "pdf" ? fileURL : nil
    }
}

enum Materials {
    static var root: URL { Store.directory.appending(path: "Materiales", directoryHint: .isDirectory) }
    static let presentationTypes = ["pptx", "ppt", "key", "odp"]

    /// Copia el fichero, saca el texto de cada página y, si es una presentación, intenta pasarla a PDF.
    /// Lo lento (conversión y lectura) va fuera del hilo principal.
    @MainActor static func add(_ url: URL, to lecture: Lecture, context: ModelContext) async throws -> Material {
        let folder = UUID().uuidString
        let dir = root.appending(path: folder, directoryHint: .isDirectory)
        let fileName = url.lastPathComponent
        let (pdfName, pages) = try await Task.detached(priority: .userInitiated) { () throws -> (String?, [String]) in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appending(path: fileName)
            try FileManager.default.copyItem(at: url, to: dest)
            let ext = dest.pathExtension.lowercased()
            var pdf: URL? = ext == "pdf" ? dest : nil
            if presentationTypes.contains(ext) { pdf = convertToPDF(dest) }
            var pages = pdf.map(pdfTexts) ?? []
            if pages.allSatisfy({ $0.isEmpty }), ext == "pptx" { pages = PPTXText.slides(of: dest) }
            return (pdf == dest ? nil : pdf?.lastPathComponent, pages)
        }.value
        let material = Material(name: url.deletingPathExtension().lastPathComponent, folder: folder, fileName: fileName)
        material.pdfName = pdfName
        material.pageTexts = pages
        material.lecture = lecture
        context.insert(material)
        try context.save()
        return material
    }

    @MainActor static func remove(_ material: Material, context: ModelContext) {
        try? FileManager.default.removeItem(at: material.directory)
        context.delete(material)
        try? context.save()
    }

    /// Antes de borrar una clase: sus ficheros de material también se van.
    @MainActor static func removeFiles(of lecture: Lecture) {
        for m in lecture.materials { try? FileManager.default.removeItem(at: m.directory) }
    }

    static func pdfTexts(_ url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    /// Pasa una presentación a PDF con lo que haya en el Mac: LibreOffice (sin pedir permisos), Keynote o PowerPoint.
    /// nil si no hay ninguno: la presentación se ve igual con Vista Rápida, sin salto automático de diapositiva.
    static func convertToPDF(_ file: URL) -> URL? {
        let out = file.deletingPathExtension().appendingPathExtension("pdf")
        let dir = file.deletingLastPathComponent()
        let ws = NSWorkspace.shared

        if let office = ws.urlForApplication(withBundleIdentifier: "org.libreoffice.script") {
            let soffice = office.appending(path: "Contents/MacOS/soffice").path
            run(soffice, ["--headless", "--convert-to", "pdf", "--outdir", dir.path, file.path], timeout: 120)
            if FileManager.default.fileExists(atPath: out.path) { return out }
        }
        if ws.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil {
            run("/usr/bin/osascript", ["-e", """
                tell application "Keynote"
                    set d to open POSIX file "\(escaped(file.path))"
                    export d to POSIX file "\(escaped(out.path))" as PDF
                    close d saving no
                end tell
                """], timeout: 120)
            if FileManager.default.fileExists(atPath: out.path) { return out }
        }
        if ws.urlForApplication(withBundleIdentifier: "com.microsoft.Powerpoint") != nil {
            run("/usr/bin/osascript", ["-e", """
                tell application "Microsoft PowerPoint"
                    open POSIX file "\(escaped(file.path))"
                    set p to active presentation
                    save p in POSIX file "\(escaped(out.path))" as save as PDF
                    close p saving no
                end tell
                """], timeout: 120)
            if FileManager.default.fileExists(atPath: out.path) { return out }
        }
        return nil
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return -1 }
        return p.terminationStatus
    }

    /// Para los apuntes de un bloque de la clase: el texto de las dos páginas que más se le parecen.
    static func context(for block: String, pages: [String], limit: Int = 1_000) -> String {
        guard !pages.isEmpty else { return "" }
        return String(Retriever.top(pages, for: block, k: 2).joined(separator: "\n---\n").prefix(limit))
    }
}

/// Texto de cada diapositiva de un .pptx, sin abrir PowerPoint: es un zip con un XML por diapositiva.
enum PPTXText {
    static func slides(of url: URL) -> [String] {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return [] }
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        // ppt/slides/slide12.xml → 12, en orden numérico (no alfabético).
        let slides = names.split(separator: "\n").map(String.init)
            .compactMap { n -> (Int, String)? in
                guard n.hasPrefix("ppt/slides/slide"), n.hasSuffix(".xml") else { return nil }
                return Int(n.dropFirst("ppt/slides/slide".count).dropLast(4)).map { ($0, n) }
            }
            .sorted { $0.0 < $1.0 }
        return slides.map { text(of: url, entry: $0.1) }
    }

    private static func text(of url: URL, entry: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return SlideText.fromXML(xml)
    }
}
