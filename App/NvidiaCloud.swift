import Foundation
import Security
import SwiftUI

enum NvidiaKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FadedAI NVIDIA", kSecAttrAccount as String: "phone"
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

@MainActor final class NvidiaCloudAccount: ObservableObject {
    static let shared = NvidiaCloudAccount()
    @Published private(set) var enabled = NvidiaKey.load() != nil
    @Published private(set) var models = UserDefaults.standard.stringArray(forKey: "fadedai.nvidia.models.v1") ?? []

    func install(_ key: String) async throws {
        guard key.hasPrefix("nvapi-"), key.count > 20, key.count < 1024,
              !key.contains(where: { $0.isWhitespace }) else { throw APIError.input }
        let result = try await NvidiaCloud.request(path: "models", key: key)
        let available = (result["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let choices = NvidiaCloud.preferredModels.filter { available.contains($0) }
        guard !choices.isEmpty else {
            throw ComposioCloudError.unavailable("NVIDIA viser ingen af de understøttede chatmodeller for denne nøgle.")
        }
        try NvidiaKey.save(key)
        UserDefaults.standard.set(choices, forKey: "fadedai.nvidia.models.v1")
        models = choices
        enabled = true
    }

    func remove() {
        NvidiaKey.remove()
        enabled = NvidiaKey.load() != nil
        if !enabled {
            models = []
            UserDefaults.standard.removeObject(forKey: "fadedai.nvidia.models.v1")
        }
    }
}

enum NvidiaCloud {
    static let preferredModels = ["nvidia/nemotron-3.5-bolt-e4b",
                                  "nvidia/nemotron-3.5-super-vl-120b-a12b"]

    static func title(_ id: String) -> String {
        switch id {
        case "deepseek-ai/deepseek-v3.2": "DeepSeek V3.2 · NVIDIA"
        case "nvidia/nemotron-3.5-bolt-e4b": "Nemotron Bolt · NVIDIA"
        case "nvidia/nemotron-3.5-super-vl-120b-a12b": "Nemotron Super · NVIDIA"
        default: "Llama 3.1 · NVIDIA"
        }
    }

    static func request(path: String, key: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard ["models", "chat/completions"].contains(path) else { throw APIError.input }
        let url = URL(string: "https://integrate.api.nvidia.com/v1/" + path)!
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
        case 401, 403: throw ComposioCloudError.unavailable("NVIDIA afviste nøglen. Tjek adgangen på din NVIDIA-konto.")
        case 402: throw ComposioCloudError.unavailable("NVIDIAs gratis adgang er brugt op eller kræver en anden konto.")
        case 429: throw ComposioCloudError.unavailable("NVIDIAs gratis brugsgrænse er nået. Vent lidt, og prøv igen.")
        default: throw ComposioCloudError.unavailable("NVIDIA kunne ikke svare. Prøv igen senere.")
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

    static func reply(model: String, messages: [[String: String]]) async throws -> String {
        guard preferredModels.contains(model), let key = NvidiaKey.load() else {
            throw ComposioCloudError.unavailable("Forbind NVIDIA under chatindstillinger først.")
        }
        let result = try await request(path: "chat/completions", key: key, body: [
            "model": model, "messages": messages, "stream": false, "max_tokens": 2048, "temperature": 0.6,
            "chat_template_kwargs": ["enable_thinking": false]
        ])
        guard let choices = result["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposioCloudError.invalidResponse
        }
        return text
    }
}

@MainActor struct NvidiaCloudSetup: View {
    let api: LiveAPI?
    @ObservedObject private var account = NvidiaCloudAccount.shared
    @State private var key = ""
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        FadedCard(accent: .green) {
            VStack(alignment: .leading, spacing: 12) {
                Label("NVIDIA · Gratis prøveadgang", systemImage: "cloud").font(.headline)
                FadedDetailText("Chat med Nemotron over internet, også med PC’en slukket. NVIDIA bestemmer brugsgrænsen.")
                if let api {
                    Button("Forbind via denne PC") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                struct Credential: Decodable { let key: String }
                                let value: Credential = try await api.moduleJSON("composio/nvidia-phone-connection",
                                    upload: Data("{}".utf8), timeout: 10, maximumBytes: 1500)
                                try await account.install(value.key)
                                notice = "NVIDIA er forbundet på telefonen."
                            } catch { notice = error.localizedDescription }
                        }
                    }.disabled(busy).frame(minHeight: 44)
                }
                Link("Åbn NVIDIA og hent nøgle", destination: URL(string: "https://build.nvidia.com/")!)
                SecureField("NVIDIA API-nøgle", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(account.enabled ? "Opdatér forbindelse" : "Forbind NVIDIA") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await account.install(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            notice = "Forbundet. NVIDIA-modellerne kan vælges i chatten."
                        } catch { notice = error.localizedDescription }
                    }
                }.disabled(busy || key.isEmpty).frame(minHeight: 44)
                if busy { ProgressView("Tjekker NVIDIA…") }
                if let notice { FadedDetailText(notice) }
                if account.enabled {
                    Button("Fjern NVIDIA fra telefonen", role: .destructive) { account.remove() }
                        .disabled(busy).frame(minHeight: 44)
                }
            }
        }
    }
}
