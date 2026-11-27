import Foundation
import Synchronization
import Security

enum CloudError: LocalizedError {
    case notConfigured
    case status(Int, String)
    case emptyAnswer
    /// El proveedor comprobó la respuesta contra el esquema y no lo cumplía: se puede volver a pedir.
    case badGeneration
    /// Cupo del día agotado: se puede volver a intentar a partir de esa hora.
    case dailyQuota(Date)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Falta la dirección, el modelo o la clave del proveedor."
        case .status(401, _), .status(403, _): "El proveedor rechazó la clave."
        case .status(429, _): "El proveedor ha alcanzado su límite de uso por ahora."
        case .status(413, _): "El texto enviado supera el límite por minuto del proveedor."
        case .status(let code, let body): "El proveedor respondió con un error \(code). \(body.prefix(160))"
        case .emptyAnswer: "El proveedor devolvió una respuesta vacía."
        case .badGeneration: "El proveedor devolvió una respuesta sin el formato pedido."
        case .dailyQuota(let until): "El proveedor ha agotado el cupo gratuito de hoy; se renueva hacia las \(until.formatted(date: .omitted, time: .shortened))."
        }
    }
}

/// Modelo de un proveedor compatible con la API de OpenAI (Groq u otro), con la clave de la usuaria.
/// Opcional: si no está configurado o falla, los apuntes se generan con el modelo del Mac.
enum CloudLLM {
    static let urlKey = "cloudBaseURL", modelKey = "cloudModel"
    static let defaultURL = "https://api.groq.com/openai/v1"

    /// Proveedores con capa gratuita y el modelo recomendado en cada uno (comprobado en noviembre de 2026).
    struct Preset: Identifiable {
        var name: String, url: String, model: String, keyPage: String?
        var id: String { name }
    }
    static let presets = [
        Preset(name: "Groq (recomendado)", url: defaultURL, model: "openai/gpt-oss-120b", keyPage: "https://console.groq.com/keys"),
        Preset(name: "Cerebras", url: "https://api.cerebras.ai/v1", model: "gpt-oss-120b", keyPage: "https://cloud.cerebras.ai"),
        Preset(name: "OpenRouter", url: "https://openrouter.ai/api/v1", model: "openai/gpt-oss-120b:free", keyPage: "https://openrouter.ai/keys"),
        Preset(name: "Ollama en este Mac", url: "http://localhost:11434/v1", model: "", keyPage: nil),
    ]

    struct Config {
        var baseURL: URL
        var model: String
        var key: String
    }

    /// nil si falta algún dato. Un servidor en este mismo Mac (Ollama) no pide clave.
    static var config: Config? {
        let d = UserDefaults.standard
        let model = (d.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = baseURL(d.string(forKey: urlKey) ?? defaultURL), !model.isEmpty else { return nil }
        let key = Keychain.read() ?? ""
        guard !key.isEmpty || isLocal(url) else { return nil }
        return Config(baseURL: url, model: model, key: key)
    }

    /// Solo https, para que la clave y la transcripción no viajen en claro; http se admite hacia este mismo Mac.
    static func baseURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host != nil,
              url.scheme == "https" || (url.scheme == "http" && isLocal(url)) else { return nil }
        return url
    }

    static func isLocal(_ url: URL) -> Bool { ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") }

    /// Proveedores que han rechazado el esquema estricto: con ellos se pide JSON sin esquema.
    private static let noStrictSchema = Mutex<Set<String>>([]) // varias clases y el chat lo tocan a la vez

    /// Una respuesta en JSON. Con `schema`, el proveedor queda obligado a cumplirlo (structured outputs): sin él,
    /// gpt-oss a veces rompe la estructura. Ante un 429 espera lo que pida el proveedor y reintenta.
    static func chat(system: String, user: String, config: Config, schema: [String: Any]? = nil) async throws -> String {
        let strictSchema = schema.flatMap { s in noStrictSchema.withLock { $0.contains(config.baseURL.absoluteString) } ? nil : s }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "response_format": strictSchema.map {
                ["type": "json_schema", "json_schema": ["name": "respuesta", "strict": true, "schema": strict($0)]] as [String: Any]
            } ?? ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        // gpt-oss razona antes de responder y ese razonamiento gasta cupo: para apuntes basta con poco.
        if config.model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<6 {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            // Límite por minuto: se espera y se sigue. El cupo del día (o una espera de más de 10 minutos) no se espera:
            // la clase queda pendiente.
            if code == 429 {
                let body = String(data: data, encoding: .utf8) ?? ""
                let wait = Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? waitTime(in: body) ?? 20
                if wait > 600 || body.contains("per day") { throw CloudError.dailyQuota(.now + max(wait, 60)) }
                if attempt < 5 {
                    try await Task.sleep(for: .seconds(max(wait, 2)))
                    continue
                }
            }
            let errorText = code == 200 ? "" : String(data: data, encoding: .utf8) ?? ""
            if code == 400, errorText.contains("failed_generation") || errorText.contains("does not match") { throw CloudError.badGeneration }
            // Solo un rechazo del esquema; un 400 por contexto largo o modelo erróneo no debe quitarlo para siempre.
            if code == 400, strictSchema != nil, errorText.contains("response_format") || errorText.contains("schema") {
                NSLog("StudyAI: el proveedor no admite el esquema estricto, sigo sin él: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                _ = noStrictSchema.withLock { $0.insert(config.baseURL.absoluteString) }
                return try await chat(system: system, user: user, config: config, schema: nil)
            }
            guard code == 200 else { throw CloudError.status(code, String(data: data, encoding: .utf8) ?? "") }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (body?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            if let used = (body?["usage"] as? [String: Any])?["total_tokens"] as? Int { NSLog("StudyAI: proveedor: \(used) tokens") }
            guard let text = message?["content"] as? String, !text.isEmpty else { throw CloudError.emptyAnswer }
            return text
        }
        throw CloudError.status(429, "")
    }

    /// «Please try again in 7m12.5s» → segundos.
    static func waitTime(in body: String) -> Double? {
        guard let m = body.firstMatch(of: #/try again in (?:(\d+)h)?(?:(\d+)m)?(?:([\d.]+)s)?/#),
              m.1 != nil || m.2 != nil || m.3 != nil else { return nil }
        return Double(m.1 ?? "0")! * 3600 + Double(m.2 ?? "0")! * 60 + (Double(m.3 ?? "0") ?? 0)
    }

    /// El modo estricto pide que cada objeto liste todos sus campos como obligatorios y no admita otros,
    /// y no conoce las extensiones «x-» que añade el esquema de Apple.
    static func strict(_ node: Any) -> Any {
        if let list = node as? [Any] { return list.map(strict) }
        guard var dict = node as? [String: Any] else { return node }
        dict = dict.filter { !$0.key.hasPrefix("x-") }.mapValues(strict)
        if let props = dict["properties"] as? [String: Any] {
            dict["required"] = Array(props.keys)
            dict["additionalProperties"] = false
        }
        return dict
    }

    /// El primer objeto JSON del texto: quita ```json, texto alrededor o la lista que a veces lo envuelve.
    static func jsonObject(in text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }

    /// Modelos que ofrece el proveedor con esa clave: sirve para comprobarla y para elegir modelo.
    static func models(baseURL: URL, key: String) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 20)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.status(code, String(data: data, encoding: .utf8) ?? "") }
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}

/// La clave del proveedor vive en el Llavero del Mac, nunca en las preferencias ni en disco.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "es.personal.studyai.cloud",
        kSecAttrAccount as String: "apiKey",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Cadena vacía = borrar la clave.
    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
