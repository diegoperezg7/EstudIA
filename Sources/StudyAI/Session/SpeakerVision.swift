import CoreGraphics
import FoundationModels

@Generable struct PeopleOnScreen {
    @Guide(description: "Nombres de las personas que aparecen en vídeo o con un rótulo de nombre, tal como están escritos. Lista vacía si no se ve a nadie.")
    var people: [String]
}

/// Mira un fotograma de la pantalla y dice quién está hablando en la clase.
/// Solo da nombre cuando se ve a una única persona identificada (vista de orador de Teams/Zoom, profesor con rótulo).
/// Con varias a la vez no adivina: medido, el modelo acierta el recuadro resaltado apenas la mitad de las veces.
/// Necesita la visión del modelo de Apple (macOS 27). Sin ella, la transcripción sale sin nombres.
enum SpeakerVision {
    static var isAvailable: Bool {
        guard #available(macOS 27, *) else { return false }
        let model = SystemLanguageModel.default
        return model.isAvailable && model.capabilities.contains(.vision)
    }

    static let instructions = """
        Miras capturas de pantalla de una clase online que se está reproduciendo. Enumeras las personas que se ven \
        en vídeo o identificadas con un rótulo de nombre. No cuentes nombres que solo aparecen dentro del texto \
        de diapositivas o documentos (autores, citas). No inventes nombres.
        """

    /// nil si no se ve quién habla o el modelo falla: un fallo aquí nunca afecta a la grabación.
    static func guess(_ image: CGImage) async -> String? {
        guard #available(macOS 27, *) else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let r = try await session.respond(to: Prompt {
                "¿Qué personas aparecen en esta captura?"
                Attachment(image)
            }, generating: PeopleOnScreen.self)
            let names = r.content.people
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
                .filter { (2...40).contains($0.count) }
            return names.count == 1 ? names[0] : nil
        } catch {
            return nil
        }
    }

    /// El nombre más repetido entre las muestras que caen dentro del párrafo (con 8 s de margen: hay una cada 15 s).
    /// ponytail: un párrafo = una persona; si dos hablan dentro del mismo párrafo, gana la mayoría.
    static func speaker(from samples: [(time: Double, name: String)], start: Double, end: Double) -> String? {
        let inside = samples.filter { $0.time >= start - 8 && $0.time <= end + 8 }.map(\.name)
        let counts = Dictionary(inside.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }
}
