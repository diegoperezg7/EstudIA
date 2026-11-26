import Sparkle
import SwiftUI

/// Actualizaciones con Sparkle: lee appcast.xml de la última release de GitHub, comprueba la firma EdDSA
/// y sustituye la app. Las clases viven en Application Support, así que actualizar no las toca.
/// Solo en la app empaquetada con clave pública (scripts/build-app.sh); con `swift run` no hace nada.
@MainActor enum Updates {
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    static var available: Bool { controller != nil }
    static func check() { controller?.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Buscar actualizaciones…") { Updates.check() }.disabled(!Updates.available)
    }
}
