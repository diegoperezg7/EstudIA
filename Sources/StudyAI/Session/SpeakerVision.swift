import CoreGraphics
import Foundation
import Vision

/// Mira un fotograma de la pantalla y dice quién está hablando en la videollamada o la clase.
/// Teams, Zoom y Meet rodean con un borde de color el recuadro de quien habla: se leen los rótulos de nombre
/// con el reconocimiento de texto del sistema y se da el que tiene ese borde al lado. Sin borde no adivina.
/// ponytail: con la vista de orador (una sola persona, sin borde) no da nombre; añadirla si hace falta.
enum SpeakerVision {
    /// Reconocimiento de texto de Vision: está en cualquier Mac con macOS 26.
    static let isAvailable = true

    struct Reading {
        /// nil si no hay ningún recuadro resaltado con un nombre.
        var speaker: String?
        /// Términos escritos en pantalla con forma de nombre propio o de producto («SharePoint», «Digital Brains»).
        var terms: [String]
    }

    /// Una sola lectura de la pantalla para las dos cosas. Un fallo aquí nunca afecta a la grabación.
    static func read(_ image: CGImage) async -> Reading {
        await Task.detached(priority: .utility) {
            let lines = textLines(in: image)
            return Reading(speaker: highlightedName(lines, image: image), terms: lines.flatMap { terms(in: $0.text) })
        }.value
    }

    static func guess(_ image: CGImage) async -> String? { await read(image).speaker }

    static func highlightedName(_ lines: [(text: String, rect: CGRect)], image: CGImage) -> String? {
        let labels = lines.compactMap { l in personName(l.text).map { (name: $0, rect: l.rect) } }
        guard !labels.isEmpty, let pixels = Pixels(image) else { return nil }
        let speaking = labels.filter { pixels.hasBorder(near: $0.rect) }.map(\.name)
        return Set(speaking).count == 1 ? speaking[0] : nil
    }

    static func nameLabels(in image: CGImage) -> [(name: String, rect: CGRect)] {
        textLines(in: image).compactMap { l in personName(l.text).map { (name: $0, rect: l.rect) } }
    }

    /// «Conectar Outlook» → Outlook; «SharePoint», «Digital Brains». La primera palabra de una línea no cuenta
    /// sola (suele ser un botón o el inicio de una frase); sí las palabras con mayúscula dentro («SharePoint»).
    static func terms(in line: String) -> [String] {
        let words = line.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        var out: [String] = []
        var run: [String] = []
        func flush() { if run.count >= 2 { out.append(run.joined(separator: " ")) }; run = [] }
        for (i, w) in words.enumerated() {
            let letters = w.filter(\.isLetter)
            guard letters.count >= 3, letters.count == w.count || w.contains("-") else { flush(); continue }
            if w.dropFirst().contains(where: \.isUppercase), w.contains(where: \.isLowercase) { out.append(w) } // SharePoint, iCloud
            if w.first?.isUppercase == true, w != w.uppercased() {
                run.append(w)
                if i > 0 { out.append(w) }
            } else { flush() }
        }
        flush()
        return Array(Set(out))
    }

    /// Cada línea de texto de la pantalla y dónde está (en píxeles, origen arriba a la izquierda).
    static func textLines(in image: CGImage) -> [(text: String, rect: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // los nombres no están en el diccionario
        request.recognitionLanguages = ["es-ES", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox
            return (text, CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    /// «Joaquín Galant», «Saul Leyva (Invitado)» → nombre. «SL», «Gente 3», textos largos → nil.
    static func personName(_ raw: String) -> String? {
        var text = raw
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) } // (Invitado), (Organizador), (tú)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count), text.count <= 40 else { return nil }
        let wordsOK = words.allSatisfy { w in
            guard let first = w.first, first.isUppercase, first.isLetter else { return false }
            return w.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }
        }
        // Una sola palabra en mayúsculas («SL», «UNIR») son iniciales o siglas, no un nombre.
        let isInitials = words.count == 1 && text == text.uppercased()
        guard wordsOK, !isInitials, words.contains(where: { $0.count >= 3 }) else { return nil }
        return text
    }

    /// El nombre más repetido entre las muestras que caen dentro del párrafo (hay una cada 3 s, con 2 s de margen).
    static func speaker(from samples: [(time: Double, name: String)], start: Double, end: Double) -> String? {
        let inside = samples.filter { $0.time >= start - 2 && $0.time <= end + 2 }.map(\.name)
        let counts = Dictionary(inside.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Los píxeles del fotograma en RGBA, para buscar el borde de color del recuadro de quien habla.
struct Pixels {
    let width: Int, height: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        width = w; height = h
        guard ok else { return nil }
        data = buffer
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// Color vivo: el morado de Teams, el verde o amarillo de Zoom, el azul de Meet. No el gris, el negro ni los pasteles.
    static func isAccent(_ c: (Int, Int, Int)) -> Bool {
        let hi = max(c.0, c.1, c.2), lo = min(c.0, c.1, c.2)
        return hi >= 115 && hi - lo >= 80
    }

    /// ¿Hay, a la izquierda y por debajo del rótulo, una línea recta de un mismo color vivo? Es el borde del recuadro.
    func hasBorder(near label: CGRect) -> Bool {
        let h = max(Int(label.height), 8)
        // Vision puede dar cajas un poco fuera de la imagen: sin recortar, los rangos se invierten y la app cae.
        func clamp(_ v: CGFloat, _ hi: Int) -> Int { min(max(Int(v), 0), hi) }
        let left = clamp(label.minX, width - 1), right = clamp(label.maxX, width - 1)
        let top = clamp(label.minY, height - 1), bottom = clamp(label.maxY, height - 1)
        let vertical = (max(0, left - 4 * h)..<left).reversed().contains { x in
            line((max(0, top - 3 * h)...min(height - 1, bottom)).map { (x, $0) })
        }
        let horizontal = (min(height - 1, bottom + 1)...min(height - 1, bottom + 4 * h)).contains { y in
            line((max(0, left - h)...right).map { ($0, y) })
        }
        return vertical && horizontal
    }

    /// Casi todos los puntos del tramo son del mismo color vivo.
    private func line(_ points: [(Int, Int)]) -> Bool {
        guard points.count >= 12 else { return false }
        let colors = points.map { rgb($0.0, $0.1) }
        let accents = colors.filter(Self.isAccent)
        guard Double(accents.count) >= Double(colors.count) * 0.85 else { return false }
        let n = accents.count
        let mean = (accents.map(\.0).reduce(0, +) / n, accents.map(\.1).reduce(0, +) / n, accents.map(\.2).reduce(0, +) / n)
        let similar = accents.filter { abs($0.0 - mean.0) + abs($0.1 - mean.1) + abs($0.2 - mean.2) <= 90 }
        return Double(similar.count) >= Double(colors.count) * 0.85
    }
}
