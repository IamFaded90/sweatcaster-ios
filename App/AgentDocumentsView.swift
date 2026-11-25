import SwiftUI
import UniformTypeIdentifiers

extension AgentPhoneChat {
    func canAskAboutDocumentDeadline(_ prompt: String) -> Bool {
        guard keepHistory, !web, !answerAsCard, source != .composio else { return false }
        if nextDocument != nil { return AgentDocumentDeadline.requested(in: prompt) || AgentDocumentDeadline.isFollowUp(prompt) }
        return AgentDocumentDeadline.isFollowUp(prompt) && turns.last?.documentSources?.contains(where: { $0.deadline != nil }) == true
    }

    func answerDocumentDeadline(_ prompt: String) -> Bool {
        guard canAskAboutDocumentDeadline(prompt) else { return false }
        let selected = nextDocument
        let sources = selected.map(AgentDocumentDeadline.sources(in:)) ?? turns.last?.documentSources ?? []
        let reply: String
        if sources.isEmpty {
            reply = "Jeg fandt ingen frist med en tydelig dato og et årstal. Du kan spørge om et bestemt uddrag eller skrive datoen direkte."
        } else if sources.count == 1, let source = sources.first, let quote = source.deadline?.quote {
            reply = "“\(quote)”\n\(source.citation)"
        } else {
            reply = "Jeg fandt \(sources.count) mulige frister. Vælg det uddrag, du vil mindes om."
        }
        // Document conversations are kept only in the open chat, just like other document answers.
        turns.append(PrivateChatTurn(prompt: prompt, reply: reply, source: Source.phone.rawValue,
                                     botID: bot.id, replyModelName: "Dokumenter", documentSources: sources))
        composerFocused = false
        appleDictation.stop()
        speech.stop()
        openAgentAction = nil
        notice = nil
        draft = ""
        // Keep the attachment available when an ambiguous/missing date needs another look.
        if !sources.isEmpty {
            nextDocument = nil
            if let selected, selected.id == sharedAttachment?.document.id { sharedAttachment?.onUse() }
        }
        saveDraft()
        return true
    }
}

@MainActor struct AgentDocumentReminderButton: View {
    let source: AgentDocumentSource
    let deadline: AgentDocumentDeadline
    let botName: String
    let showsEvidence: Bool
    @State private var reviewing = false
    @State private var receipt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsEvidence {
                Text(verbatim: deadline.quote).textSelection(.enabled)
                Text(verbatim: source.citation).font(.caption).foregroundStyle(.secondary)
            }
            if let receipt {
                Text(verbatim: receipt).font(.subheadline)
            } else {
                Button("Gennemgå påmindelsen", systemImage: "bell.badge") { reviewing = true }
                    .frame(minHeight: 44)
                    .accessibilityHint(Text(verbatim: deadline.quote + ", " + source.citation))
            }
        }
        .sheet(isPresented: $reviewing) {
            BotPhoneActionReview(action: deadline.reminder(for: source), jobID: deadline.reminderID, botName: botName,
                                 suggestedDay: BotPhoneAction.localFormatter().date(from: deadline.day + "T12:00"),
                                 reminderNotes: source.citation + "\n" + deadline.quote,
                                 onSaved: { receipt = $0 }, onApplied: {})
        }
    }
}

@MainActor struct AgentDocumentsView: View {
    let bot: VillageBot
    let api: LiveAPI?
    let answersOnPC: Bool
    let onSelect: (AgentDocument) -> Void
    let onRemove: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [AgentDocument] = []
    @State private var picker = false
    @State private var officeImport = false
    @State private var importTask: Task<Void, Never>?
    @State private var failure: String?
    @State private var deleteCandidate: AgentDocument?
    @State private var query = ""
    @State private var searching = false
    @State private var searched = false
    @State private var hits: [(document: AgentDocument, match: AgentDocumentMatch)] = []
    @State private var searchTask: Task<Void, Never>?

    private var library: AgentDocumentLibrary { AgentDocumentLibrary(botID: bot.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FadedDetailText(answersOnPC ? "Din PC modtager de relevante uddrag, når du spørger \(bot.name)." : "Når du spørger \(bot.name), søger din iPhone i dine valgte dokumenter.")
                    Button("Tilføj PDF, tekst, CSV eller JSON", systemImage: "doc.badge.plus") { officeImport = false; picker = true }
                        .frame(minHeight: 44)
                        .disabled(importTask != nil || documents.count >= AgentDocumentLibrary.limit)
                    Button("Vedhæft Office-fil via PC", systemImage: "desktopcomputer") { officeImport = true; picker = true }
                        .frame(minHeight: 44)
                        .disabled(api == nil || importTask != nil || documents.count >= AgentDocumentLibrary.limit)
                    FadedDetailText(api == nil ? "Forbind din PC for at læse Word, Excel og PowerPoint." : "Office-filen sendes til din parrede PC. Uddragene gemmes på iPhone.")
                    if importTask != nil { ProgressView("Læser dokumentet…") }
                    if let failure { FadedDetailText(failure) }
                }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Søg i agentens filer") {
                        Button("Find relevante uddrag", systemImage: "magnifyingglass", action: search)
                            .frame(minHeight: 44).disabled(searching || importTask != nil)
                        if searching { ProgressView("Søger lokalt…") }
                        if searched && !searching && hits.isEmpty { FadedDetailText("Ingen match. Prøv et navn eller ord fra filen.") }
                        ForEach(hits.indices, id: \.self) { index in
                            let hit = hits[index]
                            Button {
                                onSelect(hit.document); dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: hit.match.source.citation).font(.headline)
                                    Text(verbatim: hit.match.text).lineLimit(6).foregroundStyle(.secondary)
                                    Text("Spørg agenten om denne fil").font(.caption)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("Dokumenter") {
                    if documents.isEmpty { FadedDetailText("Du har endnu ikke tilføjet nogen filer til agenten.") }
                    ForEach(documents) { document in
                        Button {
                            onSelect(document)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: document.name).foregroundStyle(.primary)
                                Text("Brug til næste besked").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(importTask != nil)
                        .swipeActions {
                            Button("Fjern", systemImage: "trash", role: .destructive) { deleteCandidate = document }
                        }
                        .accessibilityAction(named: Text("Fjern dokument")) { deleteCandidate = document }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Dokumenter · \(bot.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Navn, indhold eller JSON-sti")
            .onSubmit(of: .search, search)
            .onChange(of: query) { _, _ in searchTask?.cancel(); searching = false; searched = false; hits = [] }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { load() }
            .fileImporter(isPresented: $picker, allowedContentTypes: officeImport ? AgentDocumentIndex.officeTypes : AgentDocumentIndex.localTypes, onCompletion: add)
            .confirmationDialog("Fjern dokumentet fra agenten?", isPresented: Binding(
                get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
            ), presenting: deleteCandidate) { document in
                Button("Fjern dokument", role: .destructive) { remove(document) }
            } message: { document in
                Text(verbatim: document.name)
            }
            .onDisappear { importTask?.cancel(); searchTask?.cancel() }
        }
    }

    private func load() {
        do { documents = try library.documents() }
        catch { failure = "Dokumenterne kunne ikke læses. Prøv igen, mens telefonen er låst op." }
    }

    private func add(_ result: Result<URL, any Error>) {
        guard importTask == nil else { return }
        failure = nil
        importTask = Task {
            defer { importTask = nil }
            do {
                let url = try result.get()
                let office = officeImport
                let pairedAPI = api
                let worker = Task.detached(priority: .userInitiated) {
                    if office { return try await AgentDocumentIndex.ingestOffice(url, api: pairedAPI) }
                    return try AgentDocumentIndex.ingest(url)
                }
                let document = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                try library.add(document)
                onSelect(document)
                dismiss()
            } catch is CancellationError {
                return
            } catch let error as CocoaError where error.code == .userCancelled {
                return
            } catch let error as AgentDocumentIndex.Failure {
                failure = error.errorDescription
            } catch let error as StructuredDocumentLoader.Failure {
                failure = error.errorDescription
            } catch LocalFileStore.Failure.tooLarge {
                failure = "Filen er for stor, eller agenten har allerede otte dokumenter."
            } catch APIError.http(404, _) {
                failure = "Opdatér FadedAI på PC’en for at bruge dokumentlæseren."
            } catch APIError.http(_, let problem) {
                failure = problem?.message ?? "PC’en kunne ikke læse dokumentet."
            } catch {
                failure = officeImport ? "PC’en kunne ikke åbne filen. Tjek forbindelsen og prøv igen." : "Filen kunne ikke åbnes. Prøv at hente den til Filer og vælg den igen."
            }
        }
    }

    private func remove(_ document: AgentDocument) {
        do {
            try library.remove(document.id)
            onRemove(document.id)
            searchTask?.cancel(); hits = []; searched = false; searching = false
            failure = nil
            load()
        } catch { failure = "Dokumentet kunne ikke fjernes. Prøv igen." }
    }

    private func search() {
        searchTask?.cancel()
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines), snapshot = documents
        guard !question.isEmpty else { return }
        searching = true; searched = false; failure = nil
        searchTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try AgentDocumentIndex.search(question, documents: snapshot) }
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                hits = found; searched = true; searching = false
            } catch is CancellationError { return }
            catch { failure = "Søgningen kunne ikke gennemføres. Prøv igen."; searching = false }
        }
    }
}
