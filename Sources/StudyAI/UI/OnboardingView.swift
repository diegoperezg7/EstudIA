import SwiftUI

/// Primer arranque: permiso de audio del sistema, modelo de español y estado de Apple Intelligence.
struct OnboardingView: View {
    let onDone: () -> Void

    @State private var permission = ScreenAudioPermission.isGranted
    @State private var requested = false
    @State private var languageReady = false
    @State private var downloading: Double?
    @State private var languageError: String?
    private let ai = AIAvailability.current
    private let assistants = AssistantLink.allCases.filter(\.isInstalled)
    @State private var assistantsLinked = AssistantLink.allCases.filter(\.isInstalled).allSatisfy(\.isConnected)
    @State private var linking = false
    @State private var groqConnected = GroqSetup.isConnected

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                AppLogo(size: 56)
                VStack(alignment: .leading) {
                    Text("Bienvenida a EstudIA").font(.title2.weight(.bold))
                    Text("Unas comprobaciones y listo.").foregroundStyle(.secondary)
                }
            }

            step(done: permission, title: "Audio del sistema",
                 detail: "EstudIA escucha el sonido que reproduce el Mac (la clase en el navegador). No usa el micrófono: el ruido de la habitación no entra.") {
                if !permission {
                    if requested {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Activa EstudIA en «Grabación de pantalla y audio del sistema» y reinicia la app.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Abrir Ajustes") { ScreenAudioPermission.openSystemSettings() }
                                Button("Reiniciar EstudIA") { ScreenAudioPermission.relaunch() }
                            }
                        }
                    } else {
                        Button("Dar permiso") {
                            permission = ScreenAudioPermission.request()
                            requested = true
                        }
                        .buttonStyle(ProminentButtonStyle())
                    }
                }
            }

            step(done: languageReady, title: "Transcripción en español",
                 detail: "El reconocimiento de voz funciona en este Mac, sin enviar audio a internet.") {
                if let languageError {
                    Text(languageError).font(.caption).foregroundStyle(.orange)
                } else if let downloading {
                    ProgressView(value: downloading) { Text("Descargando modelo de español…").font(.caption) }
                } else if !languageReady {
                    Button("Descargar") { download() }.buttonStyle(ProminentButtonStyle())
                }
            }

            step(done: ai == .ready, warning: ai != .ready, title: "Resúmenes con Apple Intelligence",
                 detail: aiDetail) { EmptyView() }

            step(done: groqConnected, title: "Mejores resúmenes con Groq (opcional, gratis)",
                 detail: "Un modelo más grande escribe resúmenes y apuntes más completos. Da para unas 4 clases largas al día; si se agota, se espera al día siguiente o se hace con el del Mac.") {
                GroqSetup { groqConnected = true }
            }

            if !assistants.isEmpty {
                step(done: assistantsLinked, title: "Preguntar a " + assistants.map(\.name).joined(separator: " y "),
                     detail: "Para que puedan leer tus clases y responderte sobre ellas. Todo se queda en este Mac: solo las leen cuando preguntas.") {
                    if !assistantsLinked {
                        Button(linking ? "Conectando…" : "Conectar") { link() }
                            .buttonStyle(ProminentButtonStyle()).disabled(linking)
                    } else {
                        Text("Si estaba abierto, ciérralo y ábrelo una vez.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button(permission ? "Empezar" : "Más tarde", action: onDone)
                    .buttonStyle(ProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .task { languageReady = await LiveTranscriber.isLanguageInstalled() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            permission = ScreenAudioPermission.isGranted
        }
    }

    private func link() {
        linking = true
        Task.detached {
            for a in AssistantLink.allCases where a.isInstalled { try? a.connect() }
            let ok = AssistantLink.allCases.filter(\.isInstalled).allSatisfy(\.isConnected)
            await MainActor.run { assistantsLinked = ok; linking = false }
        }
    }

    private var aiDetail: String {
        switch ai {
        case .ready: "Los apuntes, el resumen y las respuestas se generan en este Mac."
        case .unavailable(let reason): reason + " Mientras tanto tendrás la transcripción completa."
        }
    }

    private func download() {
        downloading = 0
        Task {
            do {
                try await LiveTranscriber.installLanguage { p in Task { @MainActor in downloading = p } }
                languageReady = await LiveTranscriber.isLanguageInstalled()
            } catch {
                languageError = error.localizedDescription
            }
            downloading = nil
        }
    }

    private func step<Action: View>(done: Bool, warning: Bool = false, title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : warning ? "exclamationmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(done ? Color.green : warning ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
