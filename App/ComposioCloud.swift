import Foundation
import Security
import SwiftUI

enum ComposioCloudError: LocalizedError {
    case missingKey, invalidResponse, unavailable(String), uncertain
    var errorDescription: String? {
        switch self {
        case .missingKey: "Forbind Composio på denne iPhone først."
        case .invalidResponse: "Composio gav et svar, appen ikke kunne læse."
        case .unavailable(let text): text
        case .uncertain: "Forbindelsen blev afbrudt. Tjek status, før du starter et nyt job."
        }
    }
}

enum ComposioPhoneKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "FadedAI Composio For You",
         kSecAttrAccount as String: "phone"]
    }
    static func exists() -> Bool { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }
    static func save(_ value: String) throws {
        guard value.range(of: #"^ck_[A-Za-z0-9_-]{8,1021}$"#, options: .regularExpression) != nil else { throw APIError.input }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            guard status == errSecItemNotFound else { throw APIError.storage }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
        }
    }
    static func load() throws -> String {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data, let value = String(data: bytes, encoding: .utf8) else { throw ComposioCloudError.missingKey }
        return value
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

/// A fresh MCP session per operation. Only this fixed endpoint receives the consumer credential.
@MainActor final class ComposioCloud {
    static let endpoint = URL(string: "https://connect.composio.dev/mcp")!
    private let key: String
    private let network: URLSession
    private var protocolVersion = "2025-03-26"
    private var sessionID: String?
    private var counter = 0

    init(key: String) {
        self.key = key
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 240
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        network = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { network.invalidateAndCancel() }

    func initialize() async throws {
        let result = try await rpc("initialize", params: [
            "protocolVersion": protocolVersion, "capabilities": [:],
            "clientInfo": ["name": "FadedAI", "version": "1.0"]
        ])
        guard let version = result["protocolVersion"] as? String,
              version.range(of: #"^20[0-9]{2}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw ComposioCloudError.invalidResponse
        }
        protocolVersion = version
        _ = try await rpc("notifications/initialized", params: [:], notification: true)
    }

    private func rpc(_ method: String, params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        counter += 1
        let id = counter
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if !notification { payload["id"] = id }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue(key, forHTTPHeaderField: "x-consumer-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (bytes, response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse, [200, 202].contains(http.statusCode) else {
            throw ComposioCloudError.unavailable("Composio afviste forbindelsen. Tjek login og forbindelser.")
        }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id"),
           value.range(of: #"^[!-~]{1,512}$"#, options: .regularExpression) != nil { sessionID = value }
        if notification { return [:] }
        let sse = http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true
        var result = Data()
        var line = Data()
        var count = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 2_000_000 else { throw ComposioCloudError.invalidResponse }
            if !sse { result.append(byte); continue }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if line.isEmpty && !result.isEmpty {
                    let entry = try Self.object(result)
                    result.removeAll(keepingCapacity: true)
                    if entry["id"] as? Int == id { return try Self.rpcResult(entry) }
                } else if let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") {
                    result.append(contentsOf: text.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                    result.append(10)
                }
                line.removeAll(keepingCapacity: true)
            } else { line.append(byte) }
        }
        let entry = try Self.object(result)
        guard entry["id"] as? Int == id else { throw ComposioCloudError.invalidResponse }
        return try Self.rpcResult(entry)
    }

    private static func rpcResult(_ entry: [String: Any]) throws -> [String: Any] {
        guard entry["error"] == nil, let result = entry["result"] as? [String: Any] else {
            throw ComposioCloudError.invalidResponse
        }
        return result
    }

    static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ComposioCloudError.invalidResponse
        }
        return value
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await rpc("tools/call", params: ["name": name, "arguments": arguments])
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw ComposioCloudError.invalidResponse
        }
        return try Self.object(Data(text.utf8))
    }

    func discover(_ query: String) async throws -> [String: Any] {
        let result = try await call("COMPOSIO_SEARCH_TOOLS", [
            "queries": [["use_case": query]], "session": ["generate_id": true]
        ])
        guard let data = result["data"] as? [String: Any] else { throw ComposioCloudError.invalidResponse }
        return data
    }

    func execute(_ slug: String, arguments: [String: Any], discovery: [String: Any]) async throws -> [String: Any] {
        guard let schemas = discovery["tool_schemas"] as? [String: Any], schemas[slug] != nil,
              let session = discovery["session"] as? [String: Any], let id = session["id"] as? String else {
            throw ComposioCloudError.unavailable("Handlingen er ikke tilgængelig gennem denne Composio-forbindelse.")
        }
        let result = try await call("COMPOSIO_MULTI_EXECUTE_TOOL", [
            "session_id": id, "sync_response_to_workbench": false,
            "tools": [["tool_slug": slug, "arguments": arguments]]
        ])
        guard let data = result["data"] as? [String: Any], let rows = data["results"] as? [[String: Any]],
              rows.count == 1, rows[0]["tool_slug"] as? String == slug,
              let response = rows[0]["response"] as? [String: Any],
              let output = response["data"] as? [String: Any] else {
            throw ComposioCloudError.unavailable("Tjenesten kunne ikke udføre handlingen. Tjek adgang og saldo i Composio.")
        }
        guard response["successful"] as? Bool == true else { throw Self.failure(response) }
        return output
    }

    static func failure(_ response: [String: Any]) -> ComposioCloudError {
        let data = response["data"] as? [String: Any] ?? [:]
        let message = ((data["message"] as? String) ?? (response["error"] as? String) ?? "").lowercased()
        if data["status_code"] as? Int == 402 || message.contains("insufficient balance") || message.contains("credit balance") {
            return .unavailable("Tjenesten mangler saldo. Din forbindelse er aktiv, men kontoen kan ikke generere endnu.")
        }
        if data["status_code"] as? Int == 429 || message.contains("quota") || message.contains("rate limit") {
            return .unavailable("Tjenestens forbrugsgrænse er nået. Prøv igen senere eller tjek kontoen.")
        }
        if message.contains("not found") || message.contains("not available") || data["status_code"] as? Int == 404 {
            return .unavailable("Denne model er ikke tilgængelig på din konto.")
        }
        return .unavailable("Tjenesten afviste handlingen. Tjek konto, modeladgang og saldo i Composio.")
    }

    static func client() async throws -> ComposioCloud {
        let client = ComposioCloud(key: try ComposioPhoneKey.load())
        try await client.initialize()
        return client
    }

    static func reply(model: String, messages: [[String: String]]) async throws -> String {
        let deepseek = model == "deepseek-chat" || model == "deepseek-reasoner"
        guard deepseek || model == "grok-4.7" else { throw APIError.input }
        let client = try await client()
        let slug = deepseek ? "DEEPSEEK_CREATE_CHAT_COMPLETION" : "GROK_CREATE_CHAT_COMPLETION"
        let search = try await client.discover("Use \(slug) for a chat completion through \(deepseek ? "DeepSeek" : "Grok").")
        let tokenKey = deepseek ? "max_tokens" : "max_completion_tokens"
        let output = try await client.execute(slug, arguments: ["model": model, "messages": messages, tokenKey: 2048], discovery: search)
        guard let choices = output["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposioCloudError.invalidResponse
        }
        return String(text.prefix(20_000))
    }
}
