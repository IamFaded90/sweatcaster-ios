import Foundation
import SwiftUI

@MainActor final class ComposioCloudAccount: ObservableObject {
    static let shared = ComposioCloudAccount()
    @Published private(set) var enabled = ComposioPhoneKey.exists()
    @Published private(set) var toolkits: Set<String>
    private let cacheKey = "fadedai.composio.phone.toolkits.v1"

    private init() {
        toolkits = Set(UserDefaults.standard.stringArray(forKey: "fadedai.composio.phone.toolkits.v1") ?? [])
    }

    func install(_ key: String) async throws {
        guard key.range(of: #"^ck_[A-Za-z0-9_-]{8,1021}$"#, options: .regularExpression) != nil else { throw APIError.input }
        let client = ComposioCloud(key: key)
        try await client.initialize()
        let search = try await client.discover("List DeepSeek, Grok and Veo connection status and available chat or video models.")
        guard let rows = search["toolkit_connection_statuses"] as? [[String: Any]] else { throw ComposioCloudError.invalidResponse }
        let active = Set(rows.compactMap { row -> String? in
            guard row["has_active_connection"] as? Bool == true, let name = row["toolkit"] as? String,
                  ["deepseek", "grok", "veo"].contains(name) else { return nil }
            return name
        })
        try ComposioPhoneKey.save(key)
        UserDefaults.standard.set(Array(active).sorted(), forKey: cacheKey)
        toolkits = active
        enabled = true
    }

    func remove() {
        ComposioPhoneKey.remove()
        enabled = ComposioPhoneKey.exists()
        if !enabled {
            toolkits = []
            UserDefaults.standard.removeObject(forKey: cacheKey)
        }
    }

    func allows(_ toolkit: String) -> Bool { enabled && toolkits.contains(toolkit) }
}

@MainActor struct ComposioCloudSetup: View {
    let api: LiveAPI?
    @ObservedObject private var account = ComposioCloudAccount.shared
    @State private var busy = false
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        FadedCard(accent: FadedBrand.pc) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ComposioLogo(slug: "grok")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Composio på iPhone").font(.headline)
                        FadedDetailText(account.enabled ? "Virker med internet, også når PC’en er slukket." : "Brug DeepSeek, Grok og Veo direkte fra telefonen.")
                    }
                }
                if let api {
                    FadedSecondaryButton(account.enabled ? "Opdatér fra denne PC" : "Forbind via denne PC",
                                         icon: "iphone.and.arrow.right.inward") {
                        begin {
                            struct Credential: Decodable { let key: String }
                            let credential: Credential = try await api.moduleJSON("composio/phone-connection",
                                upload: Data("{}".utf8), timeout: 10, maximumBytes: 1500)
                            try await account.install(credential.key)
                        }
                    }.disabled(busy)
                }
                DisclosureGroup("Brug Composio-nøgle") {
                    SecureField("Composio For You-nøgle", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Forbind") { begin { try await account.install(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = "" } }
                        .frame(minHeight: 44).disabled(busy || key.isEmpty)
                }
                FadedDetailText("Forbindelsen gemmes på denne iPhone. Modelkald bruger internet og tjenestens eventuelle saldo.")
                if busy { ProgressView("Tjekker Composio…") }
                if let notice { FadedDetailText(notice) }
                if account.enabled {
                    Button("Fjern fra denne iPhone", role: .destructive) {
                        account.remove()
                        notice = account.enabled ? "Forbindelsen kunne ikke fjernes." : "Forbindelsen er fjernet fra telefonen."
                    }.frame(minHeight: 44).disabled(busy)
                }
            }
        }
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation()
                notice = "Forbundet. Vælg DeepSeek eller Grok i chatten, eller Veo i Video Studio."
            } catch { notice = error.localizedDescription }
        }
    }
}
