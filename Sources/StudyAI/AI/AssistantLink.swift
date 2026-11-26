import AppKit
import Foundation

/// Conecta EstudIA como servidor MCP (estudia-mcp, por stdio y solo en este Mac) con la app de ChatGPT o Claude Desktop.
/// Solo añade o quita la entrada «estudia» en su configuración, con copia de seguridad la primera vez.
enum AssistantLink: String, CaseIterable, Identifiable {
    case chatgpt, claude
    var id: String { rawValue }

    var name: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    var logo: String { self == .chatgpt ? "OpenAI" : "Claude" }
    var bundleID: String { self == .chatgpt ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// La app de ChatGPT para Mac comparte la configuración de Codex; Claude Desktop tiene la suya.
    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return self == .chatgpt
            ? home.appendingPathComponent(".codex/config.toml")
            : home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// El servidor que va dentro de la app (sigue a la app si se mueve: se vuelve a escribir al conectar).
    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/estudia-mcp").path
    }

    var isConnected: Bool {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return self == .chatgpt ? text.contains("[mcp_servers.estudia]") : text.contains("\"estudia\"")
    }

    /// ChatGPT: además de la entrada en config.toml (modo Work), instala el complemento «EstudIA» con la CLI
    /// que trae la propia app, para que salga en Complementos. Si la CLI falla, queda la entrada de config.toml.
    func connect() throws {
        try write(connected: true)
        if self == .chatgpt { Self.installPlugin() }
    }

    func disconnect() throws {
        try write(connected: false)
        if self == .chatgpt { Self.codex(["plugin", "remove", "estudia@estudia"]); Self.codex(["plugin", "marketplace", "remove", "estudia"]) }
    }

    /// Al arrancar: si ya estaba conectada, vuelve a apuntar al servidor de esta copia de la app
    /// (pasa al moverla del DMG a Aplicaciones o al actualizarla). Sin red y en segundo plano.
    static func refreshConnections() {
        Task.detached(priority: .utility) {
            for a in allCases where a.isInstalled && a.isConnected && !a.pointsHere { try? a.connect() }
        }
    }

    private var pointsHere: Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.contains(Self.serverPath) ?? false
    }

    /// Copia el complemento que va dentro de la app a Application Support (ChatGPT lo lee de ahí) y lo instala.
    private static func installPlugin() {
        let fm = FileManager.default
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("ChatGPTPlugin"), fm.fileExists(atPath: bundled.path) else { return }
        let dest = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudyAI/ChatGPTPlugin")
        try? fm.removeItem(at: dest)
        guard (try? fm.copyItem(at: bundled, to: dest)) != nil else { return }
        codex(["plugin", "marketplace", "add", dest.path])
        codex(["plugin", "add", "estudia@estudia"])
    }

    /// La CLI de Codex que va dentro de la app de ChatGPT. Devuelve si terminó bien; sin ella no hace nada.
    @discardableResult
    private static func codex(_ args: [String]) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AssistantLink.chatgpt.bundleID) else { return false }
        let cli = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return false }
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func write(connected: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let backup = configURL.appendingPathExtension("antes-de-estudia")
        if !old.isEmpty, !fm.fileExists(atPath: backup.path) { try old.write(to: backup, atomically: true, encoding: .utf8) }
        let new = self == .chatgpt ? Self.toml(old, connected: connected) : try Self.json(old, connected: connected)
        try new.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Quita el bloque [mcp_servers.estudia] (hasta la siguiente tabla) y, si toca, lo vuelve a poner al final.
    static func toml(_ text: String, connected: Bool) -> String {
        var out: [Substring] = [], skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { skipping = t == "[mcp_servers.estudia]" || t.hasPrefix("[mcp_servers.estudia.") }
            if !skipping { out.append(line) }
        }
        var result = out.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        if connected {
            if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
            result += "\n[mcp_servers.estudia]\ncommand = \"\(serverPath)\"\n"
        }
        return result
    }

    static func json(_ text: String, connected: Bool) throws -> String {
        var root = (text.isEmpty ? [:] : try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["estudia"] = connected ? ["command": serverPath, "args": [String]()] : nil
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Carpeta de trabajo para ChatGPT: los servidores MCP locales solo los usa su modo Work, que pide una carpeta.
    /// Va aparte de la base de datos y solo lleva AGENTS.md (cómo usar EstudIA); la primera vez ChatGPT pide confiar en ella.
    static var workFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyAI/Asistente")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agents = """
            # EstudIA

            Eres el ayudante de estudio de una alumna universitaria. Sus clases están en el servidor MCP «estudia»:
            - `listar_clases` para encontrar la clase (por asignatura o fecha),
            - `buscar` para localizar un tema en todas las clases,
            - `leer_clase` para leerla (resumen, apuntes, notas; con parte «transcripcion», la transcripción con minutos).

            Lee siempre la clase antes de responder y cita el minuto (mm:ss) cuando uses la transcripción.
            Responde en el idioma de la pregunta, claro y pensado para estudiar. No crees ni modifiques archivos.
            """
        try? agents.write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Abre la app con la pregunta escrita (sin enviar).
    /// ChatGPT: codex://new?path=<carpeta>&prompt=… (modo Work, el que usa MCP) ; Claude: claude://claude.ai/new?q=…
    func ask(_ prompt: String) {
        var c = URLComponents(string: self == .chatgpt ? "codex://new" : "claude://claude.ai/new")!
        c.queryItems = self == .chatgpt
            ? [URLQueryItem(name: "path", value: Self.workFolder.path), URLQueryItem(name: "prompt", value: prompt)]
            : [URLQueryItem(name: "q", value: prompt)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }
}
