import SwiftUI

struct GrokTemplateReceipt: Decodable, Sendable {
    let name: String
    let instructions: String
    let source: URL
    let hasDetails: Bool
}

@MainActor struct GrokBotTemplateView: View {
    let api: LiveAPI?
    let onUse: (VillageBot) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var previewLink = ""
    @State private var result: GrokTemplateReceipt?
    @State private var fetchedLink: String?
    @State private var notice: String?
    @State private var loading = false
    @State private var retry = 0

    private var link: String { previewLink.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentResult: GrokTemplateReceipt? { fetchedLink == link ? result : nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Find en skabelon") {
                    if let guide = URL(string: "https://x.ai/bot/marketplace") {
                        Link(destination: guide) {
                            Label("Se Groks skabeloner", systemImage: "arrow.up.right.square")
                        }
                    }
                    TextField("Indsæt et Grok-skabelonlink", text: $previewLink)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if api == nil {
                        Text("Forbind din PC, så FadedAI kan hente skabelonen.")
                            .foregroundStyle(.secondary)
                    } else if loading {
                        ProgressView("Henter skabelon fra Grok…")
                    } else if let notice {
                        Text(notice).foregroundStyle(palette.coralText)
                        if Self.officialURL(link) != nil {
                            Button("Prøv igen", systemImage: "arrow.clockwise") { retry += 1 }
                        }
                    }
                }
                if let result = currentResult {
                    Section("Din botkladde") {
                        Text(result.name).font(.headline)
                        Text(result.instructions).textSelection(.enabled)
                        if !result.hasDetails {
                            Text("Grok viser kun botbeskrivelsen for dette link.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Link("Se kilden hos Grok", destination: result.source)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Fra Grok Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Brug som kladde", action: apply)
                        .disabled(currentResult == nil)
                }
            }
        }
        .task(id: "\(api?.queueTargetID ?? "")|\(retry)|\(link)") {
            await fetch(link)
        }
    }

    private func fetch(_ address: String) async {
        result = nil
        fetchedLink = nil
        notice = nil
        loading = false
        guard let api, !address.isEmpty else { return }
        guard Self.officialURL(address) != nil else {
            notice = "Brug et offentligt Grok Bot-link."
            return
        }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            let receipt = try await api.grokTemplate(address)
            try Task.checkCancellation()
            guard Self.officialURL(receipt.source.absoluteString) != nil,
                  (1...80).contains(receipt.name.count),
                  (1...4_000).contains(receipt.instructions.utf8.count) else { throw APIError.malformed }
            fetchedLink = address
            result = receipt
        } catch {
            guard !Task.isCancelled else { return }
            if case APIError.http(_, let problem) = error, let message = problem?.message {
                notice = message
            } else {
                notice = "Skabelonen kunne ikke hentes. Tjek PC-forbindelsen og FadedAI-opdateringen."
            }
        }
        if !Task.isCancelled { loading = false }
    }

    private func apply() {
        guard let result = currentResult else { return }
        onUse(VillageBot(name: result.name, prompt: result.instructions, notifications: false))
        dismiss()
    }

    nonisolated static func officialURL(_ value: String) -> URL? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count <= 2_048,
              let parts = URLComponents(string: clean),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              ["x.ai", "www.x.ai", "grok.com", "www.grok.com"].contains(host),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        return parts.url
    }
}
