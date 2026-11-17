import Foundation
import Security
import SwiftUI

enum OpenRouterKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FadedAI OpenRouter", kSecAttrAccount as String: "phone"
    ]
    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let value = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

@MainActor final class OpenRouterCloudAccount: ObservableObject {
    static let shared = OpenRouterCloudAccount()
    @Published private(set) var enabled = OpenRouterKey.load() != nil
    @Published private(set) var models = UserDefaults.standard.stringArray(forKey: "fadedai.openrouter.models.v1") ?? []

    func install(_ key: String) async throws {
        guard key.hasPrefix("sk-or-v1-"), key.count > 20, key.count < 1024,
              !key.contains(where: { $0.isWhitespace }) else { throw APIError.input }
        _ = try await OpenRouterCloud.request(path: "key", key: key)
        let result = try await OpenRouterCloud.request(path: "models", key: key)
        let choices = OpenRouterCloud.freeChoices(in: result)
        guard !choices.isEmpty else {
            throw ComposioCloudError.unavailable("OpenRouter viser ingen af de tre valgte modeller med gratis pris lige nu.")
        }
        try OpenRouterKey.save(key)
        UserDefaults.standard.set(choices, forKey: "fadedai.openrouter.models.v1")
        models = choices
        enabled = true
    }

    func remove() {
        OpenRouterKey.remove()
        enabled = OpenRouterKey.load() != nil
        if !enabled {
            models = []
            UserDefaults.standard.removeObject(forKey: "fadedai.openrouter.models.v1")
        }
    }
}

enum OpenRouterCloud {
    static let preferredModels = ["google/gemma-4-31b-it:free", "cohere/north-mini-code:free", "openrouter/free"]

    struct Reply {
        let text: String
        let modelID: String?
    }

    static func title(_ id: String) -> String {
        switch id {
        case "google/gemma-4-31b-it:free": "Gemma 4 31B · OpenRouter"
        case "cohere/north-mini-code:free": "North Mini Code · OpenRouter"
        case "openrouter/free": "Automatisk gratisvalg · OpenRouter"
        default: id
        }
    }

    static func freeChoices(in result: [String: Any]) -> [String] {
        let rows = result["data"] as? [[String: Any]] ?? []
        let available = rows.compactMap { row -> String? in
            guard let id = row["id"] as? String, preferredModels.contains(id),
                  let pricing = row["pricing"] as? [String: Any] else { return nil }
            for field in ["prompt", "completion", "request"] {
                let price = pricing[field] as? String ?? (field == "request" ? "0" : "")
                guard let amount = Double(price), amount == 0 else { return nil }
            }
            return id
        }
        return preferredModels.filter { available.contains($0) }
    }

    static func body(model: String, messages: [[String: String]]) throws -> [String: Any] {
        guard preferredModels.contains(model) else { throw APIError.input }
        return ["model": model, "messages": messages, "stream": false, "max_tokens": 2048,
                "reasoning": ["effort": "none"],
                "provider": ["max_price": ["prompt": 0, "completion": 0, "request": 0]]]
    }

    static func request(path: String, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard ["key", "models", "chat/completions"].contains(path) else { throw APIError.input }
        let url = URL(string: "https://openrouter.ai/api/v1/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url?.host == url.host else { throw APIError.input }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ComposioCloudError.unavailable("OpenRouter afviste nøglen. Tjek adgangen på din OpenRouter-konto.")
        case 402: throw ComposioCloudError.unavailable("OpenRouters gratis adgang er brugt op eller kræver en anden konto.")
        case 429: throw ComposioCloudError.unavailable("OpenRouters gratis brugsgrænse er nået. Prøv senere, eller vælg en anden kilde.")
        case 404, 503: throw ComposioCloudError.unavailable("Den gratis model er midlertidigt utilgængelig. Vælg automatisk gratisvalg eller en anden kilde.")
        default: throw ComposioCloudError.unavailable("OpenRouter kunne ikke svare. Prøv igen senere.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw ComposioCloudError.invalidResponse }
            data.append(byte)
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComposioCloudError.invalidResponse
        }
        return result
    }

    static func reply(model: String, messages: [[String: String]]) async throws -> Reply {
        guard preferredModels.contains(model), let key = OpenRouterKey.load() else {
            throw ComposioCloudError.unavailable("Forbind OpenRouter under chatindstillinger først.")
        }
        let result = try await request(path: "chat/completions", key: key, body: body(model: model, messages: messages))
        guard let choices = result["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposioCloudError.invalidResponse
        }
        let reported = result["model"] as? String
        return Reply(text: text, modelID: reported.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 })
    }
}

@MainActor struct OpenRouterCloudSetup: View {
    let api: LiveAPI?
    @ObservedObject private var account = OpenRouterCloudAccount.shared
    @State private var key = ""
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        FadedCard(accent: .green) {
            VStack(alignment: .leading, spacing: 12) {
                Label("OpenRouter · Gratis modeller", systemImage: "cloud").font(.headline)
                FadedDetailText("Gemma 4, North Mini Code og automatisk gratisvalg. Virker med internet, også med PC’en slukket. Gratis adgang har en brugsgrænse.")
                if let api {
                    Button("Forbind via denne PC") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                struct Credential: Decodable { let key: String }
                                let value: Credential = try await api.moduleJSON("composio/openrouter-phone-connection",
                                    upload: Data("{}".utf8), timeout: 10, maximumBytes: 1500)
                                try await account.install(value.key)
                                notice = "OpenRouter er forbundet på telefonen."
                            } catch { notice = error.localizedDescription }
                        }
                    }.disabled(busy).frame(minHeight: 44)
                }
                Link("Åbn OpenRouter og hent nøgle", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                SecureField("OpenRouter API-nøgle", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(account.enabled ? "Opdatér forbindelse" : "Forbind OpenRouter") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await account.install(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            notice = "Forbundet. OpenRouter-modellerne kan vælges i chatten."
                        } catch { notice = error.localizedDescription }
                    }
                }.disabled(busy || key.isEmpty).frame(minHeight: 44)
                if busy { ProgressView("Tjekker OpenRouter…") }
                if let notice { FadedDetailText(notice) }
                if account.enabled {
                    Button("Fjern OpenRouter fra telefonen", role: .destructive) { account.remove() }
                        .disabled(busy).frame(minHeight: 44)
                }
            }
        }
    }
}
