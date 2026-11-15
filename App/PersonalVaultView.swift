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
    var basicRead: Bool?

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
                Text("Alle dine agenter bruger samme Vault. Logins ligger i iPhonens nøglering. Du godkender hvert opslag, før resultatet deles med en agent.")
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
                                Text(entry.basicRead == true ? "Agentopslag · \(host)" : host)
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if entry.traderaAppID != nil {
                                Text("Tidligere gemt Tradera-nøgle").font(.caption).foregroundStyle(.secondary)
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
        .navigationTitle("Fælles Vault")
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Tilføj", systemImage: "plus") {
                    Button("Weblogin", systemImage: "key") { editing = VaultEntry(website: "", username: "") }
                    Button("Agentopslag med adgangskode", systemImage: "person.badge.key") {
                        editing = VaultEntry(website: "", username: "", basicRead: true)
                    }
                    Button("Token eller oplysning", systemImage: "lock") { editing = VaultEntry() }
                    Button("GitHub-adgang", systemImage: "chevron.left.forwardslash.chevron.right") {
                        editing = VaultEntry(repository: "")
                    }
                    if let tradera = URL(string: "https://www.tradera.com/") {
                        Link(destination: tradera) { Label("Åbn Tradera", systemImage: "safari") }
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
        if isWebsite { return entry.basicRead == true ? "Agentopslag" : "Weblogin" }
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
        if entry.basicRead == true {
            return VaultBasicRead.validUser(entry.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        if let repository = entry.repository { return VaultGitHub.valid(repository, token: entry.value) }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Navn", text: $entry.title)
                if isWebsite {
                    if entry.basicRead == true {
                        Text("Angiv den præcise HTTPS-adresse til en tekstfil eller et API, der bruger HTTP Basic-login. Fra agentens computer godkender du ét opslag ad gangen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
        case github(String), basicRead(URL)

        var detail: String {
            switch self {
            case .github(let repository): "GitHub · \(repository)"
            case .basicRead(let address): "Agentopslag · \(address.host() ?? "")"
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
                    }
                } else if options.isEmpty && status == nil {
                    Text("Tilføj et agentopslag eller GitHub i Fælles Vault.")
                    NavigationLink("Åbn Fælles Vault") { PersonalVaultView() }
                } else {
                    Section("Hent med en gemt adgang") {
                        ForEach(options) { option in
                            Button { load(option) } label: {
                                VStack(alignment: .leading) {
                                    Text(option.title)
                                    Text(option.source.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(busy)
                        }
                    }
                }
                if busy { ProgressView() }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Brug Fælles Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
        }
        .privacySensitive()
        .onAppear {
            do {
                options = try PersonalVaultStorage.load().compactMap { entry in
                    if let repository = entry.repository {
                        return Option(id: entry.id, title: entry.title, source: .github(repository))
                    }
                    if entry.basicRead == true, let address = entry.website.flatMap(VaultEntry.signInURL) {
                        return Option(id: entry.id, title: entry.title, source: .basicRead(address))
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

    private func load(_ option: Option) {
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
                case .basicRead(let address) where entry.basicRead == true && entry.website == address.absoluteString:
                    let content = try await VaultBasicRead.fetch(
                        address: address, username: entry.username ?? "", secret: entry.value
                    )
                    result = Preview(provider: address.host() ?? "forbindelsen", content: content)
                default:
                    status = "Adgangen er ændret i Vault. Luk og prøv igen."
                    return
                }
                if !Task.isCancelled { preview = result }
            } catch {
                if !Task.isCancelled {
                    status = (error as? VaultGitHub.Failure)?.message ??
                        (error as? VaultBasicRead.Failure)?.message ??
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

private enum VaultBasicRead {
    enum Failure: Error {
        case denied, response

        var message: String {
            switch self {
            case .denied: "Tjenesten afviste login. Tjek adressen og loginoplysningerne i Fælles Vault."
            case .response: "Adressen skal give tekst eller JSON direkte og må ikke omdirigere."
            }
        }
    }

    static func validUser(_ username: String) -> Bool {
        !username.isEmpty && username.utf8.count <= 320 && !username.contains(":") &&
            username.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func fetch(address: URL, username: String, secret: String) async throws -> String {
        guard VaultEntry.signInURL(address.absoluteString) == address,
              validUser(username), !secret.isEmpty, secret.utf8.count <= 2_048 else {
            throw Failure.denied
        }

        // The phone uses the credential for one HTTPS request to the exact saved address.
        // Only a reviewed copy of the response is sent to the agent as task context.
        let pair = "\(username):\(secret)"
        let header = Data(pair.utf8).base64EncodedString()
        var request = URLRequest(url: address)
        request.httpMethod = "GET"
        request.setValue("Basic \(header)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            data = try await VaultLookupHTTP.get(request, maxBytes: 64_000, mimeTypes: ["text/plain", "application/json"])
        } catch let failure as VaultLookupHTTP.Failure {
            if case .status(let status) = failure, status == 401 || status == 403 {
                throw Failure.denied
            }
            throw Failure.response
        }
        guard let decoded = String(data: data, encoding: .utf8),
              !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.response
        }

        var values = Set([username, secret, pair, header, Data(secret.utf8).base64EncodedString()])
        for credential in [username, secret, pair] {
            if let encoded = credential.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                values.insert(encoded)
            }
            if let escaped = try? JSONEncoder().encode(credential),
               let literal = String(data: escaped, encoding: .utf8), literal.count >= 2 {
                values.insert(String(literal.dropFirst().dropLast()))
            }
        }
        let redacted = values.filter { !$0.isEmpty }.sorted { $0.utf8.count > $1.utf8.count }
            .reduce(decoded) { value, credential in
                value.replacingOccurrences(of: credential, with: "[skjult]")
            }
        return String(decoding: redacted.utf8.prefix(7_800), as: UTF8.self)
    }
}

private enum VaultLookupHTTP {
    enum Failure: Error {
        case status(Int), badResponse
    }

    static func get(_ request: URLRequest, maxBytes: Int, mimeTypes: Set<String>? = nil) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode == 200 else { throw Failure.status(http.statusCode) }
        guard response.expectedContentLength <= Int64(maxBytes) else { throw Failure.badResponse }
        if let mimeTypes, !mimeTypes.contains(response.mimeType?.lowercased() ?? "") {
            throw Failure.badResponse
        }
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
