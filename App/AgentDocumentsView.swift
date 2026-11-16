import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AgentDocumentsView: View {
    let bot: VillageBot
    let onSelect: (AgentDocument) -> Void
    let onRemove: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [AgentDocument] = []
    @State private var picker = false
    @State private var importTask: Task<Void, Never>?
    @State private var failure: String?
    @State private var deleteCandidate: AgentDocument?

    private var library: AgentDocumentLibrary { AgentDocumentLibrary(botID: bot.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FadedDetailText("Vælg en tekstfil eller PDF fra Filer. Kun \(bot.name) kan bruge dokumentet i sin chat på iPhone.")
                    Button("Tilføj dokument", systemImage: "doc.badge.plus") { picker = true }
                        .frame(minHeight: 44)
                        .disabled(importTask != nil || documents.count >= AgentDocumentLibrary.limit)
                    if importTask != nil { ProgressView("Læser dokumentet…") }
                    if let failure { FadedDetailText(failure) }
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { load() }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.plainText, .pdf], onCompletion: add)
            .confirmationDialog("Fjern dokumentet fra agenten?", isPresented: Binding(
                get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
            ), presenting: deleteCandidate) { document in
                Button("Fjern dokument", role: .destructive) { remove(document) }
            } message: { document in
                Text(verbatim: document.name)
            }
            .onDisappear { importTask?.cancel() }
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
                let worker = Task.detached(priority: .userInitiated) { try AgentDocumentIndex.ingest(url) }
                let document = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                try library.add(document)
                load()
            } catch is CancellationError {
                return
            } catch let error as AgentDocumentIndex.Failure {
                failure = error.errorDescription
            } catch LocalFileStore.Failure.tooLarge {
                failure = "Filen er for stor, eller agenten har allerede otte dokumenter."
            } catch {
                failure = "Filen kunne ikke åbnes. Prøv at hente den til Filer og vælg den igen."
            }
        }
    }

    private func remove(_ document: AgentDocument) {
        do {
            try library.remove(document.id)
            onRemove(document.id)
            failure = nil
            load()
        } catch { failure = "Dokumentet kunne ikke fjernes. Prøv igen." }
    }
}
