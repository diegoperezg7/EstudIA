import Foundation
import Security

enum CloudError: LocalizedError {
    case notConfigured
    case status(Int, String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Falta la dirección, el modelo o la clave del proveedor."
        case .status(401, _), .status(403, _): "El proveedor rechazó la clave."
        case .status(429, _): "El proveedor ha alcanzado su límite de uso por ahora."
        case .status(let code, let body): "El proveedor respondió con un error \(code). \(body.prefix(160))"
        case .emptyAnswer: "El proveedor devolvió una respuesta vacía."
        }
    }
}

/// Modelo de un proveedor compatible con la API de OpenAI (Groq u otro), con la clave de la usuaria.
/// Opcional: si no está configurado o falla, los apuntes se generan con el modelo del Mac.
enum CloudLLM {
    static let urlKey = "cloudBaseURL", modelKey = "cloudModel"
    static let defaultURL = "https://api.groq.com/openai/v1"

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

    /// Una respuesta en JSON. Ante un 429 espera lo que pida el proveedor (hasta 60 s) y reintenta.
    static func chat(system: String, user: String, config: Config) async throws -> String {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ] as [String: Any])

        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 429, attempt < 3 {
                let wait = Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 20
                try await Task.sleep(for: .seconds(min(max(wait, 2), 60)))
                continue
            }
            guard code == 200 else { throw CloudError.status(code, String(data: data, encoding: .utf8) ?? "") }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (body?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            guard let text = message?["content"] as? String, !text.isEmpty else { throw CloudError.emptyAnswer }
            return text
        }
        throw CloudError.status(429, "")
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
