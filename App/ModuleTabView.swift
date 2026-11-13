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
