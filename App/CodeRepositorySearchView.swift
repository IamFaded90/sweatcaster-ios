import SwiftUI

@MainActor struct CodeRepositorySearchView: View {
    let api: LiveAPI
    let repository: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [PCRepositoryHit] = []
    @State private var loading: Task<Void, Never>?
    @State private var message: String?
    @State private var preview: Preview?

    private struct Preview: Identifiable {
        let id: String
        let text: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Søg i projektets kildefiler", text: $query).submitLabel(.search).onSubmit(search)
                    Button("Søg på PC’en", systemImage: "magnifyingglass", action: search)
                        .frame(minHeight: 44)
                        .disabled(loading != nil || !(3...500).contains(query.trimmingCharacters(in: .whitespacesAndNewlines).count))
                    if loading != nil { ProgressView("Læser på PC’en…") }
                    if let message { FadedDetailText(message) }
                }
                ForEach(hits) { hit in
                    Section {
                        Text(verbatim: "\(hit.path) · Linje \(hit.line)").font(FadedTypography.action)
                        Text(verbatim: hit.text).font(FadedTypography.code).lineLimit(7)
                        Button("Læs fil", systemImage: "doc.text") { read(hit) }
                            .frame(minHeight: 44).disabled(loading != nil)
                        Button("Vælg fil til opgave", systemImage: "plus.circle") {
                            onSelect(hit.path)
                            dismiss()
                        }.frame(minHeight: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground(variant: .terminal))
            .navigationTitle("Søg i projektet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .sheet(item: $preview) { file in
                NavigationStack {
                    ScrollView {
                        Text(verbatim: file.text).font(FadedTypography.code).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle(file.id)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Luk") { preview = nil } }
                }
            }
        }
        .onDisappear { loading?.cancel() }
    }

    private func search() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loading == nil, (3...500).contains(input.count) else { return }
        run {
            hits = try await PCRepositoryTools(api: api).search(repository: repository, query: input)
            if hits.isEmpty { message = "Ingen fund. Prøv andre søgeord." }
        }
    }

    private func read(_ hit: PCRepositoryHit) {
        guard loading == nil else { return }
        run {
            let text = try await PCRepositoryTools(api: api).read(repository: repository, path: hit.path)
            preview = Preview(id: hit.path, text: text)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        message = nil
        loading = Task {
            defer { loading = nil }
            do { try await action() }
            catch is CancellationError { return }
            catch {
                message = "PC’en kunne ikke læse projektet. Tjek PC-forbindelsen, hent projektet og opdatér dets indeks."
            }
        }
    }
}
