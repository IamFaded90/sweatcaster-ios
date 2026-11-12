import Foundation
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct VaultEntry: Codable, Identifiable {
    var id = UUID()
    var title = ""
    var value = ""
    var repository: String?
    var website: String?
    var username: String?
    var traderaAppID: String?

    static func signInURL(_ text: String) -> URL? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 2048,
              let parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }
}

private enum PersonalVaultStorage {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dk.fadedai.personal-vault",
        kSecAttrAccount as String: "entries"
    ]

    static func load() throws -> [VaultEntry] {
        var filter = query
        filter[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(filter as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError.storage }
        return try JSONDecoder().decode([VaultEntry].self, from: data)
    }

    static func save(_ entries: [VaultEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }
}

struct PersonalVaultView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var entries: [VaultEntry] = []
    @State private var editing: VaultEntry? = nil
    @State private var pendingRemoval: VaultEntry? = nil
    @State private var canWrite = false
    @State private var notice: String? = nil

    var body: some View {
        List {
            Section {
                Text("Gem logins og tokens i iPhonens nøglering. GitHub og Tradera kan bruges fra bottens computerskærm.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                ContentUnavailableView("Ingen gemte oplysninger", systemImage: "lock.doc")
            }
            ForEach(entries) { entry in
                HStack {
                    Button { editing = entry } label: {
                        VStack(alignment: .leading) {
                            Text(entry.title)
                            if let website = entry.website, let host = VaultEntry.signInURL(website)?.host() {
                                Text(host).font(.caption).foregroundStyle(.secondary)
                            } else if entry.traderaAppID != nil {
                                Text("Tradera · Søg efter annoncer").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let website = entry.website, let url = VaultEntry.signInURL(website) {
                        Menu("Loginmuligheder", systemImage: "ellipsis.circle") {
                            Button("Åbn login-side", systemImage: "safari") { openURL(url) }
                            if let username = entry.username {
                                Button("Kopiér brugernavn", systemImage: "person") { copy(username) }
                            }
                            Button("Kopiér adgangskode", systemImage: "key") { copy(entry.value) }
                        }
                        .labelStyle(.iconOnly)
                    } else if entry.repository == nil && entry.traderaAppID == nil {
                        Button("Kopiér", systemImage: "doc.on.doc") { copy(entry.value) }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Kopiér \(entry.title)")
                    } else {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .swipeActions(allowsFullSwipe: false) {
                    Button("Slet", role: .destructive) { pendingRemoval = entry }
                }
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Vault")
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Tilføj", systemImage: "plus") {
                    Button("Weblogin", systemImage: "key") { editing = VaultEntry(website: "", username: "") }
                    Button("Token eller oplysning", systemImage: "lock") { editing = VaultEntry() }
                    Button("GitHub-adgang", systemImage: "chevron.left.forwardslash.chevron.right") {
                        editing = VaultEntry(repository: "")
                    }
                    Button("Tradera-adgang", systemImage: "cart") {
                        editing = VaultEntry(title: "Tradera", traderaAppID: "")
                    }
                }
                .disabled(!canWrite || entries.count >= 40)
            }
        }
        .onChange(of: phase, initial: true) { _, current in
            if current == .active {
                load()
            } else if current == .background {
                editing = nil
                pendingRemoval = nil
                entries = []
                canWrite = false
            }
        }
        .sheet(item: $editing) { entry in
            VaultEntryEditor(entry: entry) { updated in
                var next = entries
                if let index = next.firstIndex(where: { $0.id == updated.id }) {
                    next[index] = updated
                } else {
                    next.append(updated)
                }
                return save(next)
            }
        }
        .confirmationDialog("Slet oplysningen fra Vault?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { entry in
            Button("Slet", role: .destructive) { _ = save(entries.filter { $0.id != entry.id }) }
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)]
        )
        notice = "Kopieret i ét minut."
    }

    private func load() {
        do {
            entries = try PersonalVaultStorage.load()
            canWrite = true
            notice = nil
        } catch {
            entries = []
            canWrite = false
            notice = "Vault kunne ikke åbnes. Lås telefonen op, og prøv igen."
        }
    }

    private func save(_ updated: [VaultEntry]) -> Bool {
        guard canWrite else { return false }
        do {
            try PersonalVaultStorage.save(updated)
            entries = updated
            notice = nil
            return true
        } catch {
            notice = "Oplysningen kunne ikke gemmes."
            return false
        }
    }
}

private struct VaultEntryEditor: View {
    @State var entry: VaultEntry
    let onSave: (VaultEntry) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saveFailed = false

    private var isWebsite: Bool { entry.website != nil }
    private var title: String {
        if isWebsite { return "Weblogin" }
        if entry.traderaAppID != nil { return "Tradera-adgang" }
        return entry.repository == nil ? "Token eller oplysning" : "GitHub-adgang"
    }

    private var secretLabel: String {
        if isWebsite { return "Adgangskode" }
        if entry.traderaAppID != nil { return "Tradera-appnøgle" }
        return entry.repository == nil ? "Oplysning" : "GitHub-token"
    }

    private var validLogin: Bool {
        guard let website = entry.website else { return true }
        return VaultEntry.signInURL(website) != nil &&
            !(entry.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (entry.username?.utf8.count ?? 0) <= 320
    }

    private var canSave: Bool {
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.title.count <= 80, !entry.value.isEmpty, entry.value.utf8.count <= 2048,
              validLogin else { return false }
        if let repository = entry.repository { return VaultGitHub.valid(repository, token: entry.value) }
        if let appID = entry.traderaAppID { return VaultTradera.valid(appID: appID, key: entry.value) }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Navn", text: $entry.title)
                if isWebsite {
                    TextField("https://…", text: Binding(
                        get: { entry.website ?? "" }, set: { entry.website = $0 }
                    ))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField("Brugernavn", text: Binding(
                        get: { entry.username ?? "" }, set: { entry.username = $0 }
                    ))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } else if entry.repository != nil {
                    TextField("ejer/repository", text: Binding(
                        get: { entry.repository ?? "" }, set: { entry.repository = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Text("Opret en fine-grained token hos GitHub til det valgte repository med læseadgang til Metadata.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if entry.traderaAppID != nil {
                    TextField("Tradera-app-id", text: Binding(
                        get: { entry.traderaAppID ?? "" }, set: { entry.traderaAppID = $0 }
                    ))
                    .keyboardType(.numberPad)
                    if let developerURL = URL(string: "https://api.tradera.com/documentation/rest-getting-started") {
                        Link("Sådan får du app-id og appnøgle", destination: developerURL)
                            .font(.footnote)
                    }
                }
                SecureField(secretLabel, text: $entry.value)
                    .textContentType(isWebsite ? .password : nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if saveFailed { Text("Oplysningen kunne ikke gemmes. Prøv igen.") }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem") {
                        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.repository = entry.repository?.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.website = entry.website.flatMap { VaultEntry.signInURL($0)?.absoluteString }
                        entry.username = entry.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.traderaAppID = entry.traderaAppID?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if entry.repository != nil || entry.traderaAppID != nil {
                            entry.value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if onSave(entry) { dismiss() } else { saveFailed = true }
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

struct VaultJobAccessView: View {
    let botName: String
    let onUse: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var options: [Option] = []
    @State private var preview: Preview?
    @State private var searchOption: Option?
    @State private var searchText = ""
    @State private var status: String?
    @State private var busy = false
    @State private var lookup: Task<Void, Never>?

    private struct Option: Identifiable {
        let id: UUID
        let title: String
        let source: Source
    }

    private struct Preview {
        let provider: String
        let content: String
    }

    private enum Source {
        case github(String), tradera(String)

        var detail: String {
            switch self {
            case .github(let repository): "GitHub · \(repository)"
            case .tradera: "Tradera · Søg efter annoncer"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let preview {
                    Section("Data fra \(preview.provider)") {
                        Text(preview.content).textSelection(.enabled)
                        Text("Opslaget følger med den næste opgave, du sender til \(botName).")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Vedhæft til \(botName)s opgave", systemImage: "paperclip") {
                            guard !busy else { return }
                            busy = true
                            Task {
                                defer { busy = false }
                                if await onUse(preview.content) { dismiss() }
                                else { status = "Opslaget kunne ikke føjes til opgaven." }
                            }
                        }
                        .disabled(busy)
                        if searchOption != nil {
                            Button("Søg igen", systemImage: "magnifyingglass") {
                                self.preview = nil
                                status = nil
                            }
                            .disabled(busy)
                        }
                    }
                } else if options.isEmpty && status == nil {
                    Text("Tilføj GitHub eller Tradera under Mere → Vault for at bruge en adgang her.")
                } else {
                    Section("Hent med en gemt adgang") {
                        ForEach(options) { option in
                            Button { select(option) } label: {
                                VStack(alignment: .leading) {
                                    Text(option.title)
                                    Text(option.source.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(busy)
                        }
                    }
                    if let searchOption {
                        Section("Søg på Tradera") {
                            TextField("Fx Nintendo Switch", text: $searchText)
                                .submitLabel(.search)
                                .onSubmit { search(searchOption) }
                            Button("Søg efter annoncer", systemImage: "magnifyingglass") { search(searchOption) }
                                .disabled(busy || !VaultTradera.validQuery(searchText))
                        }
                    }
                }
                if busy { ProgressView() }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Brug Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
        }
        .privacySensitive()
        .task {
            do {
                options = try PersonalVaultStorage.load().compactMap { entry in
                    if let repository = entry.repository {
                        return Option(id: entry.id, title: entry.title, source: .github(repository))
                    }
                    if let appID = entry.traderaAppID {
                        return Option(id: entry.id, title: entry.title, source: .tradera(appID))
                    }
                    return nil
                }
            } catch {
                status = "Vault kunne ikke åbnes. Lås din iPhone op, og prøv igen."
            }
        }
        .onChange(of: phase) { _, current in
            if current == .background { dismiss() }
        }
        .onDisappear { lookup?.cancel() }
    }

    private func select(_ option: Option) {
        status = nil
        switch option.source {
        case .github:
            searchOption = nil
            load(option)
        case .tradera:
            searchOption = option
            searchText = ""
        }
    }

    private func search(_ option: Option) {
        guard VaultTradera.validQuery(searchText) else { return }
        load(option, query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func load(_ option: Option, query: String? = nil) {
        guard !busy else { return }
        busy = true
        status = nil
        lookup = Task {
            defer { busy = false }
            do {
                let entry = try PersonalVaultStorage.load().first { $0.id == option.id }
                guard let entry else {
                    status = "Adgangen er ændret i Vault. Luk og prøv igen."
                    return
                }
                let result: Preview
                switch option.source {
                case .github(let repository) where entry.repository == repository:
                    result = Preview(provider: "GitHub", content: try await VaultGitHub.summary(repository: repository, token: entry.value))
                case .tradera(let appID) where entry.traderaAppID == appID:
                    guard let query else { return }
                    result = Preview(provider: "Tradera", content: try await VaultTradera.search(query: query, appID: appID, key: entry.value))
                default:
                    status = "Adgangen er ændret i Vault. Luk og prøv igen."
                    return
                }
                if !Task.isCancelled { preview = result }
            } catch {
                if !Task.isCancelled {
                    status = (error as? VaultGitHub.Failure)?.message ?? (error as? VaultTradera.Failure)?.message ??
                        "Opslaget mislykkedes. Tjek forbindelsen, og prøv igen."
                }
            }
        }
    }
}

private enum VaultGitHub {
    enum Failure: Error {
        case invalidEntry, accessDenied, badResponse

        var message: String {
            switch self {
            case .invalidEntry: "Tjek repository og token i Vault."
            case .accessDenied: "GitHub afviste adgangen. Tjek repository, token og tilladelser."
            case .badResponse: "GitHub returnerede et uventet svar."
            }
        }
    }

    private struct Repository: Decodable {
        let full_name: String
        let description: String?
        let default_branch: String?
        let language: String?
        let open_issues_count: Int?
    }

    static func valid(_ repository: String, token: String) -> Bool {
        let name = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
            && !name.hasSuffix("/.") && !name.hasSuffix("/..")
            && credential.range(of: #"^github_pat_[A-Za-z0-9_]{20,255}$"#, options: .regularExpression) != nil
    }

    static func summary(repository: String, token: String) async throws -> String {
        guard valid(repository, token: token), let url = URL(string: "https://api.github.com/repos/\(repository)") else {
            throw Failure.invalidEntry
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data: Data
        do {
            data = try await VaultLookupHTTP.get(request, maxBytes: 256_000)
        } catch VaultLookupHTTP.Failure.status(let code) where [401, 403, 404].contains(code) {
            throw Failure.accessDenied
        } catch is VaultLookupHTTP.Failure {
            throw Failure.badResponse
        }
        guard let result = try? JSONDecoder().decode(Repository.self, from: data),
              result.full_name.caseInsensitiveCompare(repository) == .orderedSame else {
            throw Failure.badResponse
        }
        var lines = ["GitHub · \(repository)"]
        if let branch = result.default_branch { lines.append("Standardgren · \(safeText(branch, token: token))") }
        if let language = result.language { lines.append("Sprog · \(safeText(language, token: token))") }
        if let count = result.open_issues_count { lines.append("Åbne issues og pull requests · \(count)") }
        if let description = result.description { lines.append(safeText(description, token: token)) }
        return lines.joined(separator: "\n")
    }

    private static func safeText(_ value: String, token: String) -> String {
        String(value.replacingOccurrences(of: token, with: "[skjult]").prefix(400))
    }
}

private enum VaultTradera {
    enum Failure: Error {
        case invalidEntry, invalidQuery, accessDenied, rateLimited, badResponse

        var message: String {
            switch self {
            case .invalidEntry: "Tjek app-id og appnøglen i Vault."
            case .invalidQuery: "Skriv et søgeord på højst 100 tegn."
            case .accessDenied: "Tradera afviste adgangen. Tjek app-id og appnøgle i Vault."
            case .rateLimited: "Tradera beder dig vente. Prøv igen senere."
            case .badResponse: "Tradera returnerede et uventet svar."
            }
        }
    }

    private struct SearchResult: Decodable {
        struct Listing: Decodable {
            let id: Int
            let shortDescription: String?
            let buyItNowPrice: Int?
            let nextBid: Int?
            let isEnded: Bool?
            let itemUrl: String?
        }

        struct Issue: Decodable {
            let code: String?
        }

        let totalNumberOfItems: Int?
        let items: [Listing]?
        let errors: [Issue]?
    }

    static func valid(appID: String, key: String) -> Bool {
        let identifier = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int32(identifier), number > 0,
              identifier.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return secret.utf8.count == 36 && UUID(uuidString: secret) != nil
    }

    static func validQuery(_ input: String) -> Bool {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...100).contains(query.count) && query.utf8.count <= 400 &&
            query.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func search(query: String, appID: String, key: String) async throws -> String {
        guard valid(appID: appID, key: key) else { throw Failure.invalidEntry }
        guard validQuery(query), query.range(of: key, options: .caseInsensitive) == nil else { throw Failure.invalidQuery }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.tradera.com"
        parts.path = "/v4/search"
        parts.queryItems = [URLQueryItem(name: "query", value: query)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw Failure.invalidQuery }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(appID, forHTTPHeaderField: "X-App-Id")
        request.setValue(key, forHTTPHeaderField: "X-App-Key")
        let data: Data
        do {
            data = try await VaultLookupHTTP.get(request, maxBytes: 1_000_000)
        } catch VaultLookupHTTP.Failure.status(let code) where [401, 403].contains(code) {
            throw Failure.accessDenied
        } catch VaultLookupHTTP.Failure.status(429) {
            throw Failure.rateLimited
        } catch is VaultLookupHTTP.Failure {
            throw Failure.badResponse
        }
        guard let result = try? JSONDecoder().decode(SearchResult.self, from: data),
              result.errors?.isEmpty != false,
              result.items != nil || result.totalNumberOfItems == 0 else { throw Failure.badResponse }

        let active = (result.items ?? []).filter { $0.isEnded != true && $0.id > 0 }
        var lines = ["Tradera · Aktuelle annoncer for \(query)"]
        if active.isEmpty {
            lines.append("Søgningen gav ingen aktuelle annoncer.")
        }
        for listing in active.prefix(8) {
            let title = (listing.shortDescription ?? "")
                .replacingOccurrences(of: key, with: "[skjult]", options: .caseInsensitive)
                .components(separatedBy: .controlCharacters).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let shortTitle = String(decoding: title.prefix(120).utf8.prefix(400), as: UTF8.self)
            var fields = [shortTitle.isEmpty ? "Annonce \(listing.id)" : shortTitle]
            if let buy = listing.buyItNowPrice, buy > 0 { fields.append("Køb nu \(buy) SEK") }
            if let bid = listing.nextBid, bid > 0 { fields.append("Næste bud \(bid) SEK") }
            if let link = listing.itemUrl, let safe = safeLink(link, key: key) { fields.append(safe) }
            lines.append(fields.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    private static func safeLink(_ link: String, key: String) -> String? {
        guard link.utf8.count <= 400, link.range(of: key, options: .caseInsensitive) == nil,
              let parts = URLComponents(string: link), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), ["www.tradera.com", "tradera.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, parts.path.hasPrefix("/item/") else { return nil }
        guard let normalized = parts.url?.absoluteString, normalized.utf8.count <= 400 else { return nil }
        return normalized
    }
}

private enum VaultLookupHTTP {
    enum Failure: Error {
        case status(Int), badResponse
    }

    static func get(_ request: URLRequest, maxBytes: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else { throw Failure.status(http.statusCode) }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw Failure.badResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw Failure.badResponse }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
