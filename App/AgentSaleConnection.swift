import SwiftUI

@MainActor struct AgentSaleConnection: View {
    let api: LiveAPI
    @State var access: AgentSaleAccess?
    @State private var appID = ""
    @State private var appKey = ""
    @State private var publicKey = ""
    @State private var alias = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var waiting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                if access?.authorized == true {
                    Section {
                        Label("Tradera er forbundet", systemImage: "checkmark.circle.fill")
                        if let name = access?.alias { Text(name) }
                        Text("Salgsagenten kan klargøre dine annoncer og følge deres salgsstatus.")
                    }
                } else {
                    Section("Dit Tradera-login") {
                        TextField("Dit Tradera-brugernavn", text: $alias).textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Log ind hos Tradera") { login() }
                            .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      access?.hasPublicKey != true || busy)
                        if waiting {
                            Text("Godkend adgangen hos Tradera. Vend tilbage og tryk her.")
                            Button("Jeg har godkendt · Opdatér") { finish() }.disabled(busy)
                        }
                    }
                    if access?.hasPublicKey != true {
                        Section("Forbindelsen på PC’en") {
                            Text("Traderas annonce-API bruger en appforbindelse. Har du allerede den til prisvagter, genbruger vi den.")
                            if access?.configured != true {
                                TextField("Tradera-appens ID", text: $appID).keyboardType(.numberPad)
                                SecureField("Appnøgle", text: $appKey)
                            }
                            SecureField("Offentlig nøgle fra Tradera-appen", text: $publicKey)
                            Button("Gem forbindelse krypteret på PC’en") { configure() }
                                .disabled(publicKey.isEmpty || busy)
                            Link("Åbn Traderas udviklerside", destination: URL(string: "https://api.tradera.com/")!)
                        }
                    }
                    Section {
                        Text("Du kan også arbejde med annoncen i Tradera-vinduet på PC’en gennem salgsagentens PC-knap.")
                            .font(.callout)
                    }
                }
                if busy { ProgressView("Forbinder…") }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            .scrollContentBackground(.hidden).background { FadedBackground() }
            .navigationTitle("Forbind Tradera").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .task { access = try? await api.moduleJSON("sales/access") }
        }
    }

    private func configure() {
        run {
            let body = ["action": "configure", "appID": appID, "appKey": appKey, "publicKey": publicKey]
            access = try await api.moduleJSON("sales/access", upload: JSONEncoder().encode(body))
            appKey = ""; publicKey = ""
        }
    }

    private func login() {
        run {
            struct Login: Decodable { let url: URL }
            let response: Login = try await api.moduleJSON("sales/access", upload:
                JSONEncoder().encode(["action": "login", "alias": alias.trimmingCharacters(in: .whitespacesAndNewlines)]))
            guard response.url.scheme == "https", response.url.host == "api.tradera.com",
                  response.url.path == "/token-login" else { throw APIError.malformed }
            waiting = true
            openURL(response.url)
        }
    }

    private func finish() {
        run {
            access = try await api.moduleJSON("sales/access", upload: JSONEncoder().encode(["action": "finish"]))
            if access?.authorized == true { waiting = false }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await work() }
            catch { notice = (error as? APIError)?.title ?? "Tradera-forbindelsen kunne ikke godkendes." }
        }
    }
}
