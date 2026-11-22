import FadedAIPrivateWax
import SwiftUI

@MainActor final class PrivateConversationSearch: ObservableObject {
    @Published var presented = false
    @Published private(set) var busy = false
    @Published private(set) var hits: [UUID] = []
    @Published private(set) var notice: String?
    private var worker: Task<[UUID], Error>?
    private var lookup: PrivateWaxLookup?

    static func cleanAbandoned() {
        // Retry on foreground entry if file protection prevented deletion during a lock.
        try? PrivateWaxLookup.cleanAbandoned()
    }

    func reset() {
        worker?.cancel()
        lookup?.cancel()
        worker = nil
        lookup = nil
        busy = false
        hits = []
        notice = nil
    }

    func close() {
        presented = false
        reset()
    }

    func search(_ text: String, turns: [PrivateChatTurn]) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard presented, !busy, !query.isEmpty else { return }
        reset()
        let engine = PrivateWaxLookup()
        lookup = engine
        busy = true
        let rows = turns.map { PrivateWaxLookup.Turn(id: $0.id, text: $0.prompt + "\n" + $0.reply) }
        let job = Task.detached(priority: .userInitiated) { try await engine.search(query, in: rows) }
        worker = job
        Task { [weak self] in
            let result = await job.result
            guard let self, presented, lookup === engine else { return }
            worker = nil
            lookup = nil
            busy = false
            switch result {
            case .success(let ids):
                hits = ids
                if ids.isEmpty { notice = "Ingen beskeder med de ord." }
            case .failure:
                notice = "Søgningen blev afbrudt. Prøv igen."
            }
        }
    }
}

@MainActor struct PrivateConversationSearchSheet: View {
    @ObservedObject var search: PrivateConversationSearch
    let turns: [PrivateChatTurn]
    @Environment(\.scenePhase) private var phase
    @State private var query = ""

    var body: some View {
        NavigationStack {
            if phase == .active, search.presented {
                List {
                    Section {
                        TextField("Ord fra beskeden", text: $query)
                            .submitLabel(.search)
                            .onSubmit { search.search(query, turns: turns) }
                            .onChange(of: query) { search.reset() }
                        Button("Søg i samtalen", systemImage: "magnifyingglass") {
                            search.search(query, turns: turns)
                        }.disabled(search.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if search.busy { ProgressView("Søger i beskederne…") }
                    if let notice = search.notice { Text(notice).foregroundStyle(.secondary) }
                    ForEach(search.hits, id: \.self) { id in
                        if let turn = turns.first(where: { $0.id == id }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(turn.prompt).font(.headline)
                                if !turn.reply.isEmpty { Text(turn.reply).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background { FadedBackground(variant: .privateChat) }
                .navigationTitle("Søg i denne samtale")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { search.close() } } }
            }
        }
        .onDisappear { search.close() }
        .onChange(of: phase) { _, value in if value != .active { search.close() } }
        .task {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            search.close()
        }
    }
}
