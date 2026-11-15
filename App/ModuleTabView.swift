// Displays supported PC module tabs and imports card collections.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ModuleTabView: View {
    let tab: ModuleTab
    let api: LiveAPI
    let onBack: () -> Void
    @State private var cards: [ModuleCards.Card] = []
    @State private var information: String?
    @State private var importing = false
    @State private var confirmImport = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                if let notice { Text(notice) }
                if busy { ProgressView("Opdaterer") }
                if tab.kind == "cards" {
                    Button("Importér Kortscanner-fil", systemImage: "square.and.arrow.down") {
                        confirmImport = true
                    }.frame(minHeight: 44).disabled(busy)
                    if cards.isEmpty && !busy { Text("Ingen kort endnu.") }
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.headline)
                            Text([card.set, card.number, card.language].filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            if let price = card.price { Text(price, format: .currency(code: "DKK")) }
                        }
                    }
                } else if let information {
                    Text(verbatim: information)
                }
                if notice != nil {
                    Button("Prøv igen") { Task { await load() } }.frame(minHeight: 44).disabled(busy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle(tab.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog("Erstat samlingen på PC’en?", isPresented: $confirmImport) {
                Button("Vælg JSON-fil") { importing = true }
            } message: { Text("Den valgte fil sendes til din FadedAI-PC og erstatter den tidligere import.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case let .success(url) = result else { return }
                Task { await load(file: url) }
            }
        }
    }

    private func load(file: URL? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let file {
                let granted = file.startAccessingSecurityScopedResource()
                defer { if granted { file.stopAccessingSecurityScopedResource() } }
                let data = try LocalFileStore.readBytes(from: file, maximumBytes: 1_000_000)
                guard !data.isEmpty else { throw APIError.input }
                cards = try await api.moduleCards(tab.id, upload: data).cards
            } else if tab.kind == "cards" {
                cards = try await api.moduleCards(tab.id).cards
            } else {
                information = try await api.moduleInformation(tab.id).text
            }
            notice = nil
        } catch {
            AppDiagnostics.record(error)
            notice = file == nil ? "Fanen kunne ikke hentes fra PC’en." : "Importen mislykkedes. Vælg en gyldig Kortscanner-fil på højst 1 MB."
        }
    }
}

struct CodeAddOn: Codable, Identifiable, Sendable {
    struct Action: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case prompt, tool, link, webApp }
        let type: Kind
        let label, value: String

        var website: URL? {
            guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
                  let host = url.host, host.contains("."), url.port == nil || url.port == 443 else { return nil }
            return url
        }
    }
    struct Source: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case manifest, pages
            case staticFiles = "static"
        }
        let repo, revision: String
        let kind: Kind
        let root: String

        var gitHubURL: URL? {
            guard repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#,
                             options: .regularExpression) != nil,
                  !repo.hasSuffix("/."), !repo.hasSuffix("/.."),
                  revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://github.com/\(repo)/tree/\(revision)")
        }

        var description: String {
            switch kind {
            case .manifest: "FadedAI-pakke"
            case .pages: "Udgivet GitHub Pages-webværktøj"
            case .staticFiles: "Webpakke til lokal brug"
            }
        }
    }
    struct Library: Decodable { let items: [CodeAddOn] }

    let id: UUID
    let title, text: String
    let actions: [Action]
    let source: Source?

    static let tools = ["checklist", "stats", "sum", "average", "percent", "discount", "split", "days"]

    var valid: Bool {
        (1...48).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
            && (1...4_000).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
            && (source == nil || source?.gitHubURL != nil)
            && actions.count <= 6 && actions.allSatisfy { action in
                (1...48).contains(action.label.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
                && (1...1_000).contains(action.value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
                && (action.type != .tool || Self.tools.contains(action.value))
                && (action.type != .link || action.website != nil)
                && (action.type != .webApp || (source?.kind == .staticFiles && action.value == "index.html"))
            }
    }
}

@MainActor struct CodeAddOnsView: View {
    let api: LiveAPI?
    @State private var entries: [CodeAddOn] = []
    @State private var brief = ""
    @State private var gitHubLink = ""
    @State private var localGitHubPackage = false
    @State private var proposal: CodeAddOn?
    @State private var removing: CodeAddOn?
    @State private var notice: String?
    @State private var working: Task<Void, Never>?
    @State private var loaded = false

    var body: some View {
        List {
            Section("Installeret") {
                if entries.isEmpty && loaded {
                    FadedDetailText("Dine godkendte sider og værktøjer kommer til at ligge her.")
                }
                ForEach(entries) { item in
                    NavigationLink(item.title) {
                        CodeAddOnDetail(item: item, api: api, preview: false) {
                            entries.removeAll { $0.id == item.id }
                        }
                    }
                        .frame(minHeight: 44)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Fjern", systemImage: "trash", role: .destructive) { removing = item }
                                .disabled(working != nil)
                        }
                }
                if !loaded && api != nil && notice == nil { ProgressView("Henter tilføjelser…") }
            }
            if api != nil {
                gitHubImporter
                creator
                if let proposal { proposalSection(proposal) }
            }
            if working != nil { ProgressView("Arbejder på PC’en…") }
            if let notice { FadedDetailText(notice) }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground() }
        .navigationTitle("Tilføjelser")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: api?.queueTargetID) {
            loaded = false
            entries = []
            proposal = nil
            await reload()
        }
        .refreshable { await reload() }
        .onDisappear { working?.cancel() }
        .alert("Fjern tilføjelsen fra listen?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { item in
            Button("Fjern", role: .destructive) { remove(item) }
        }
    }

    private var creator: some View {
        Section("Lav med Code Bot") {
            FadedDetailText("Bed fx om en pakkeliste med en tjeklisteknap. Du kan gennemgå forslaget før installation.")
            TextField("Hvad skal din tilføjelse gøre?", text: $brief, axis: .vertical)
                .lineLimit(2...5)
            Button("Lav forslag", systemImage: "sparkles", action: generate)
                .frame(minHeight: 44)
                .disabled(working != nil || !(1...800).contains(brief.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count))
        }
    }

    private var gitHubImporter: some View {
        Section("Fra GitHub") {
            TextField("https://github.com/ejer/projekt", text: $gitHubLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .accessibilityLabel("Link til et GitHub-projekt")
            Toggle("Hent en lokal webpakke", isOn: $localGitHubPackage)
                .disabled(working != nil)
            Button("Hent fra GitHub", systemImage: "square.and.arrow.down", action: findGitHubAddOn)
                .frame(minHeight: 44)
                .disabled(working != nil || !gitHubLink.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://"))
        }
    }

    private func proposalSection(_ proposal: CodeAddOn) -> some View {
        Section("Klar til gennemgang") {
            NavigationLink {
                CodeAddOnDetail(item: proposal, api: nil, preview: true)
            } label: {
                Label(proposal.title, systemImage: "magnifyingglass").frame(minHeight: 44)
            }
            Button("Godkend og installér", systemImage: "square.and.arrow.down") { install(proposal) }
                .frame(minHeight: 44)
                .disabled(working != nil)
        }
    }

    private func reload() async {
        guard let api else {
            notice = "Forbind din PC for at hente tilføjelser."
            return
        }
        do {
            let result = try await api.codeAddOns()
            try Task.checkCancellation()
            entries = Array(result.items.filter(\.valid).prefix(40))
            loaded = true
            notice = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            notice = error is APIError ? "Kunne ikke hente tilføjelser. Tjek PC-forbindelsen og versionen." : "Prøv at hente igen."
        }
    }

    private func generate() {
        let input = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...800).contains(input.unicodeScalars.count) else { return }
        proposal = nil
        work("Code Bot kunne ikke lave et gyldigt forslag. Prøv en kortere beskrivelse.") { api in
            let draft = try await api.draftCodeAddOn(input)
            try Task.checkCancellation()
            guard draft.valid else { throw APIError.malformed }
            proposal = draft
        }
    }

    private func findGitHubAddOn() {
        let input = gitHubLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localGitHubPackage
        guard !input.isEmpty else { return }
        proposal = nil
        work("GitHub-projektet kunne ikke hentes. Tjek PC-forbindelsen, og prøv igen.") { api in
            let draft = try await api.findGitHubAddOn(input, local: local)
            try Task.checkCancellation()
            guard draft.valid else { throw APIError.malformed }
            proposal = draft
        }
    }

    private func install(_ proposal: CodeAddOn) {
        work("Tilføjelsen kunne ikke installeres. Prøv igen.") { api in
            let item = try await api.installCodeAddOn(proposal)
            try Task.checkCancellation()
            entries = [item] + entries.filter { $0.id != item.id }
            self.proposal = nil
            if item.source != nil {
                gitHubLink = ""
                localGitHubPackage = false
            } else { brief = "" }
            loaded = true
        }
    }

    private func remove(_ item: CodeAddOn) {
        work("Tilføjelsen kunne ikke fjernes.") { api in
            try await api.removeCodeAddOn(item.id)
            try Task.checkCancellation()
            entries.removeAll { $0.id == item.id }
        }
    }

    private func work(_ failure: String, operation: @escaping (LiveAPI) async throws -> Void) {
        guard let api, working == nil else { return }
        notice = nil
        working = Task {
            defer { working = nil }
            do { try await operation(api) }
            catch is CancellationError { return }
            catch let APIError.http(_, problem) {
                if !Task.isCancelled { notice = problem?.message ?? failure }
            } catch {
                if !Task.isCancelled { notice = failure }
            }
        }
    }
}

private struct CodeAddOnDetail: View {
    private struct Website: Identifiable {
        let url: URL
        var id: URL { url }
    }
    private struct Prompt: Identifiable {
        let id = UUID()
        let text: String
    }
    let item: CodeAddOn
    let api: LiveAPI?
    let preview: Bool
    var onRemoved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTool: V0LocalTool?
    @State private var prompt: Prompt?
    @State private var publishedSite: Website?
    @State private var confirmDeletion = false
    @State private var deleting = false
    @State private var deletionIssue = false

    var body: some View {
        List {
            Text(verbatim: item.text).textSelection(.enabled)
            if let source = item.source, let link = source.gitHubURL {
                Section("Fra GitHub") {
                    LabeledContent("Pakke", value: source.description)
                    Link(destination: link) {
                        Label(source.repo, systemImage: "arrow.up.right.square").frame(minHeight: 44)
                    }
                    if source.kind == .staticFiles {
                        FadedDetailText("FadedAI åbner pakken fra en lokal kopi. Webværktøjer, der kræver netadgang, skal åbnes som udgivne websider.")
                    }
                }
            }
            ForEach(Array(item.actions.enumerated()), id: \.offset) { entry in
                action(entry.element)
            }
            if !preview {
                Section {
                    Button("Slet tilføjelse", systemImage: "trash", role: .destructive) {
                        confirmDeletion = true
                    }
                    .disabled(deleting || api == nil)
                    .frame(minHeight: 44)
                    if deleting { ProgressView("Sletter fra PC’en…") }
                    if deletionIssue { FadedDetailText("Tilføjelsen kunne ikke slettes. Tjek PC-forbindelsen, og prøv igen.") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground() }
        .navigationTitle(item.title)
        .confirmationDialog("Slet \(item.title)?", isPresented: $confirmDeletion) {
            Button("Slet tilføjelse", role: .destructive) { delete() }
        } message: {
            Text("Siden slettes fra FadedAI-biblioteket på din PC.")
        }
        .sheet(item: $selectedTool) { V0LocalToolSheet(tool: $0) }
        .sheet(item: $publishedSite) { PublishedAddOnBrowser(url: $0.url) }
        .sheet(item: $prompt) { input in
            ChatView(api: api, demo: false, initialDraft: input.text,
                     connection: "PC · Tilføjelse", storageKey: "addon-\(input.id.uuidString)",
                     onBack: { prompt = nil }, openHome: { prompt = nil })
        }
    }

    private func delete() {
        guard let api, !deleting else { return }
        deleting = true
        deletionIssue = false
        Task {
            defer { deleting = false }
            do {
                try await api.removeCodeAddOn(item.id)
                onRemoved?()
                dismiss()
            } catch {
                deletionIssue = true
            }
        }
    }

    @ViewBuilder private func action(_ action: CodeAddOn.Action) -> some View {
        if preview {
            LabeledContent(action.label, value: action.type == .webApp ? "Lokal webpakke" : action.value)
        } else {
            switch action.type {
            case .tool:
                if let tool = V0LocalTool.all.first(where: { $0.id == action.value }) {
                    Button(action.label, systemImage: "wrench.and.screwdriver") { selectedTool = tool }
                        .frame(minHeight: 44)
                }
            case .prompt:
                Button(action.label, systemImage: "bubble.left") { prompt = Prompt(text: action.value) }
                    .frame(minHeight: 44)
            case .link:
                if let site = action.website {
                    Button { publishedSite = Website(url: site) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(action.label, systemImage: "arrow.up.right.square")
                            Text(site.host ?? "").font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                }
            case .webApp:
                if let api {
                    NavigationLink {
                        CodeAddOnWebScreen(api: api, item: item)
                    } label: {
                        Label(action.label, systemImage: "globe").frame(minHeight: 44)
                    }
                }
            }
        }
    }
}
