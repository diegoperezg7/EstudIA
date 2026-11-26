import AppKit
import ServiceManagement
import SwiftUI

/// Ajustes guardados (UserDefaults) que se leen fuera de las vistas.
enum Prefs {
    static let nameKey = "userName", appearanceKey = "appearance", languageKey = "classLanguage", speakersKey = "watchSpeakers"

    /// El nombre del saludo: el que Ana haya escrito o, si no, el de su cuenta del Mac.
    static var name: String {
        let saved = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? (NSFullUserName().split(separator: " ").first.map(String.init) ?? "") : saved
    }

    static let indicatorKey = "recordingIndicator"
    static let autoLanguageKey = "autoLanguage"

    /// Detectar el idioma de cada clase (por defecto). Si no, se usa siempre el elegido.
    static var autoLanguage: Bool { UserDefaults.standard.object(forKey: autoLanguageKey) as? Bool ?? true }

    /// Dónde ver que está grabando.
    enum Indicator: String, CaseIterable {
        case pill, menuBar, both
        var title: String { switch self { case .pill: "Píldora"; case .menuBar: "Barra de menús"; case .both: "Las dos" } }
        var pill: Bool { self != .menuBar }
        var menuBar: Bool { self != .pill }
    }

    static var indicator: Indicator { Indicator(rawValue: UserDefaults.standard.string(forKey: indicatorKey) ?? "") ?? .both }

    static var watchSpeakers: Bool { UserDefaults.standard.object(forKey: speakersKey) as? Bool ?? true }

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String { switch self { case .system: "Automático"; case .light: "Claro"; case .dark: "Oscuro" } }

        @MainActor func apply() {
            NSApp.appearance = switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    @MainActor static func applyAppearance() {
        (Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system).apply()
    }
}

/// Configuración (⌘,): tu nombre, apariencia, idioma de las clases y la grabación, en tarjetas visuales.
struct SettingsView: View {
    @AppStorage(Prefs.nameKey) private var name = ""
    @AppStorage(Prefs.appearanceKey) private var appearance: Prefs.Appearance = .system
    @AppStorage(Prefs.languageKey) private var language: ClassLanguage = .spanish
    @AppStorage(Prefs.speakersKey) private var watchSpeakers = true
    @AppStorage(Prefs.autoLanguageKey) private var autoLanguage = true
    @AppStorage(Prefs.indicatorKey) private var indicator: Prefs.Indicator = .both
    @State private var pillReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AppLogo(size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Configuración").font(.title2.weight(.bold))
                        Text("Se guarda sola.").foregroundStyle(.secondary)
                    }
                }

                section("Tú", icon: "person.crop.circle.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Tu nombre", text: $name, prompt: Text(Prefs.name.isEmpty ? "Tu nombre" : Prefs.name))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                        Text("Para el saludo de la portada: «\(HomeGreeting.salute(name: Prefs.name))».")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Apariencia", icon: "circle.lefthalf.filled") {
                    HStack(spacing: 12) {
                        ForEach(Prefs.Appearance.allCases, id: \.self) { a in
                            choice(selected: appearance == a, title: a.title) { appearance = a; a.apply() } preview: {
                                ThemeThumb(kind: a)
                            }
                        }
                    }
                }

                section("Idioma de las clases", icon: "globe") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            choice(selected: autoLanguage, title: "Automático") { autoLanguage = true } preview: {
                                HStack(spacing: -10) {
                                    ForEach(ClassLanguage.allCases, id: \.self) { Flag(language: $0, height: 28) }
                                }
                                .frame(maxWidth: .infinity, minHeight: 64)
                            }
                            ForEach(ClassLanguage.allCases, id: \.self) { l in
                                let on = !autoLanguage && language == l
                                choice(selected: on, title: l.name) { autoLanguage = false; language = l } preview: {
                                    Flag(language: l, height: 40)
                                        .saturation(on ? 1 : 0.35)
                                        .frame(maxWidth: .infinity, minHeight: 64)
                                }
                            }
                        }
                        Text(autoLanguage
                             ? "EstudIA escucha los primeros segundos de cada clase y elige el idioma sola. La transcripción, el resumen, los apuntes y el chat salen en ese idioma."
                             : "Todas las clases se transcriben en \(language.name.lowercased() == "english" ? "inglés" : "español"). La transcripción, el resumen, los apuntes y el chat salen en ese idioma.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Grabación", icon: "record.circle") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mientras grabas, verlo en").font(.callout.weight(.medium))
                        HStack(spacing: 12) {
                            ForEach(Prefs.Indicator.allCases, id: \.self) { i in
                                choice(selected: indicator == i, title: i.title) {
                                    indicator = i
                                    RecordingIndicators.apply()
                                } preview: { IndicatorThumb(kind: i) }
                            }
                        }
                        Divider()
                        Toggle(isOn: $watchSpeakers) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Poner el nombre de quién habla")
                                Text("Mira la pantalla cada 15 s (solo en el Mac, sin guardar imágenes). Gasta algo más de batería.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(!SpeakerVision.isAvailable)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Píldora de grabación")
                                Text("Arrástrala a cualquier punto de la pantalla; con clic derecho, a una esquina.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(pillReset ? "Hecho" : "Volver abajo al centro") { RecordingPill.resetPosition(); pillReset = true }
                                .disabled(pillReset)
                        }
                    }
                }

                section("Avisos de clase", icon: "bell.badge.fill") {
                    DetectionCard()
                }

                section("Actualizaciones", icon: "arrow.down.circle.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EstudIA \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "en desarrollo")")
                            Text(Updates.available ? "Busca versiones nuevas sola cada día. Tus clases no se tocan al actualizar."
                                                   : "Las actualizaciones funcionan en la app instalada desde el DMG.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CheckForUpdatesButton()
                    }
                }

                section("Resumen y apuntes", icon: "sparkles") {
                    AIEngineCard()
                }

                section("Conectar con tus asistentes", icon: "puzzlepiece.extension.fill") {
                    AssistantsCard()
                }

                Label("Tus clases no salen de este Mac, salvo lo que ChatGPT o Claude lean cuando les preguntes por ellas y, si lo eliges arriba, lo que se envíe a la nube para escribir el resumen.", systemImage: "lock.shield.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
        .tint(Theme.ink)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Theme.ink)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func choice<Preview: View>(selected: Bool, title: String, action: @escaping () -> Void,
                                       @ViewBuilder preview: () -> Preview) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.tertiary))
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.highlight : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.highlightEdge : Theme.cardBorder, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Miniatura de la app en claro, en oscuro o mitad y mitad.
private struct ThemeThumb: View {
    let kind: Prefs.Appearance

    var body: some View {
        GeometryReader { g in
            ZStack {
                switch kind {
                case .light: mock(dark: false)
                case .dark: mock(dark: true)
                case .system:
                    mock(dark: false)
                    mock(dark: true).mask(Rectangle().frame(width: g.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing))
                }
            }
        }
        .frame(height: 64)
    }

    private func mock(dark: Bool) -> some View {
        let bg = dark ? Color(hex: 0x0F1130) : Color(hex: 0xFBFAFF)
        let card = dark ? Color(hex: 0x1D2050) : Color.white
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Theme.gradient).frame(width: 34, height: 7)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(card).frame(width: 30, height: 22)
                    RoundedRectangle(cornerRadius: 3).fill(card).frame(width: 30, height: 22)
                }
            }
            .padding(9)
        }
    }
}

/// Miniatura de dónde aparece el aviso de grabación: la píldora en la pantalla y/o el reloj en la barra de menús.
private struct IndicatorThumb: View {
    let kind: Prefs.Indicator

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2B3A7A), Color(hex: 0x5B3FA8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Spacer()
                    if kind.menuBar {
                        Image(systemName: "record.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                        Text("12:04").monospacedDigit()
                    }
                    Image(systemName: "wifi")
                }
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).frame(height: 13)
                .background(.black.opacity(0.35))
                Spacer()
                if kind.pill {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Text("12:04").font(.system(size: 8, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 14)
                    .background(Theme.night, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.lavender.opacity(0.5), lineWidth: 0.5))
                    .padding(.bottom, 7)
                }
            }
        }
        .frame(height: 64)
    }
}

/// ChatGPT y Claude leen las clases a través de EstudIA (MCP en este Mac): conectar o desconectar con un botón.
private struct AssistantsCard: View {
    @State private var refresh = 0
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Así ChatGPT o Claude pueden buscar y leer tus clases cuando les preguntes, sin copiar ni pegar nada.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(AssistantLink.allCases) { a in
                let installed = a.isInstalled, connected = a.isConnected
                HStack(spacing: 12) {
                    Image(a.logo).resizable().scaledToFit().frame(width: 26, height: 26)
                        .padding(7).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.system(size: 13, weight: .semibold))
                        Label(!installed ? "No está instalado en este Mac" : connected ? "Conectado: ya puede leer tus clases" : "Sin conectar",
                              systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption).foregroundStyle(connected ? AnyShapeStyle(Theme.successColor) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    if installed {
                        if connected {
                            Button("Desconectar") { run { try a.disconnect() } }
                        } else {
                            Button("Conectar") { run { try a.connect(); message = "Listo. Si \(a.name) estaba abierto, ciérralo y ábrelo una vez." } }
                                .buttonStyle(ProminentButtonStyle())
                        }
                    }
                }
                .id("\(a.id)\(refresh)")
            }
            if let message { Text(message).font(.caption).foregroundStyle(Theme.ink) }
            Text("Pregúntale, por ejemplo: «¿Qué se explicó en la última clase de Almacenes?» o «Hazme un test del tema 4».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func run(_ action: () throws -> Void) {
        do { message = nil; try action() } catch { message = "No se pudo: \(error.localizedDescription)" }
        refresh += 1
    }
}

/// Qué modelo escribe el resumen y los apuntes, y la tanda para rehacer los de las clases ya grabadas.
private struct AIEngineCard: View {
    @AppStorage(AIEngine.key) private var engine: AIEngine = .local
    @AppStorage(CloudLLM.urlKey) private var url = CloudLLM.defaultURL
    @AppStorage(CloudLLM.modelKey) private var model = ""
    @State private var key = Keychain.read() ?? ""
    @State private var models: [String] = []
    @State private var status: String?
    @State private var checking = false
    @State private var confirmAll = false
    @Environment(LectureProcessor.self) private var processor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quién escribe el resumen, los apuntes y las preguntas. La transcripción y el chat se hacen siempre en este Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Modelo", selection: $engine) {
                ForEach(AIEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: engine) { status = nil }

            switch engine {
            case .local:
                Text("Privado y sin conexión. Es también el que se usa si la nube falla o se queda sin cupo.")
                    .font(.caption).foregroundStyle(.secondary)
            case .appleCloud:
                Text(AIEngine.appleCloudAvailable
                     ? "El modelo grande de Apple, en sus servidores privados (Private Cloud Compute). Sin clave y sin coste, con un cupo de uso. La transcripción se envía cifrada a Apple para escribir el resumen."
                     : !AIEngine.hasCloudEntitlement
                        ? "Todavía no disponible: Apple tiene que conceder a EstudIA el permiso para usar su nube. Mientras tanto se usa el modelo del Mac."
                        : "No está disponible en este Mac: necesita macOS 27 y Apple Intelligence activado. Mientras tanto se usa el modelo del Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if AIEngine.appleCloudAvailable { checkRow("Probar") }
            case .external:
                TextField("Dirección", text: $url, prompt: Text(CloudLLM.defaultURL)).textFieldStyle(.roundedBorder)
                SecureField("Clave de API", text: $key, prompt: Text("Clave de API"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { Keychain.save(key) }
                if models.isEmpty {
                    TextField("Modelo", text: $model, prompt: Text("Modelo (pulsa Comprobar para elegirlo de la lista)")).textFieldStyle(.roundedBorder)
                } else {
                    Picker("Modelo", selection: $model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                }
                checkRow("Comprobar")
                Text("Cualquier servicio compatible con la API de OpenAI. Groq tiene una capa gratuita con límites por minuto y por día. La clave se guarda en el Llavero. Con esta opción, la transcripción de la clase se envía a ese proveedor. Para un modelo en este Mac con Ollama: http://localhost:11434/v1, sin clave.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clases ya grabadas")
                    Text(processor.batch.map { "Generando: \($0.done) de \($0.total)" }
                         ?? "Rehace el resumen y los apuntes de todas con el modelo elegido. Lo actual se mantiene hasta que lo nuevo esté listo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if processor.batch != nil {
                    Button("Cancelar") { processor.cancelBatch() }
                } else {
                    Button("Volver a generar todas") { confirmAll = true }
                }
            }
        }
        .confirmationDialog("¿Volver a generar el resumen de todas las clases?", isPresented: $confirmAll) {
            Button("Volver a generar todas") { processor.regenerateAll() }
        } message: {
            Text("Va de una en una y puede tardar. Tus notas y los títulos que hayas puesto no se tocan; las clases con texto añadido desde el chat se saltan.")
        }
    }

    private func checkRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button(checking ? "Comprobando…" : title) { check() }.disabled(checking)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func check() {
        checking = true
        status = nil
        Task {
            defer { checking = false }
            do {
                if engine == .external {
                    guard let base = CloudLLM.baseURL(url) else { status = "La dirección tiene que empezar por https:// (o http://localhost para un modelo en este Mac)."; return }
                    models = try await CloudLLM.models(baseURL: base, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !models.contains(model) { model = models.first ?? "" }
                    status = models.isEmpty ? "La clave vale, pero el proveedor no lista modelos: escribe el nombre a mano." : "Clave correcta. Elige el modelo."
                } else {
                    _ = try await StudyAI.cloudRespond("Escribe un tema de prueba sobre el agua.", as: DigestSection.self, language: .spanish, engine: .appleCloud)
                    status = "Funciona."
                }
            } catch {
                status = engine == .appleCloud
                    ? "No respondió: a esta versión de la app le falta el permiso de Apple para este modelo. Se usará el del Mac."
                    : error.localizedDescription
            }
        }
    }
}

/// Aviso al empezar una clase (Zoom o vídeo en el navegador) y abrir EstudIA al iniciar sesión para no perderse ninguna.
private struct DetectionCard: View {
    @AppStorage(ClassDetector.enabledKey) private var enabled = true
    @AppStorage(ClassDetector.keywordsKey) private var keywords = ClassDetector.defaultKeywords
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proponer grabar cuando empiece una clase")
                    Text("Al entrar en una reunión de Zoom o al poner un vídeo cuyo título tenga alguna de estas palabras, la píldora pregunta si quieres grabarla. Nunca graba sola.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            TextField("Palabras", text: $keywords, prompt: Text(ClassDetector.defaultKeywords))
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Divider()
            Toggle(isOn: Binding(get: { atLogin }, set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginProblem = nil
                } catch {
                    loginProblem = error.localizedDescription
                }
                atLogin = SMAppService.mainApp.status == .enabled
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Abrir EstudIA al iniciar sesión")
                    Text("Se queda en la barra de menús, lista para avisar de la próxima clase.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.orange) }
        }
    }
}
