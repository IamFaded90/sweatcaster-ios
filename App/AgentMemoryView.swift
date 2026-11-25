import FadedAIPrivateWax
import SwiftUI

@MainActor enum OrdinaryAgentMemory {
    static let index = OrdinaryWaxLookup(root: URL.applicationSupportDirectory.appendingPathComponent("FadedAI/OrdinaryWax", isDirectory: true))
    static func context(botID: UUID, question: String) async -> AgentMemory.Context {
        let store = AgentMemory.Store(botID: botID)
        guard let snapshot = try? store.load(), snapshot.enabled else { return .init(items: []) }
        let candidates = AgentMemory.candidates(question, items: snapshot.items)
        guard !candidates.isEmpty else { return .init(items: []) }
        do {
            let rows = snapshot.items.map { OrdinaryWaxLookup.Row(id: $0.id, text: $0.quote) }
            let query = AgentMemory.words(question).sorted().joined(separator: " ")
            let hits = try await index.search(query, botID: botID, rows: rows)
            try Task.checkCancellation()
            guard let current = try? store.load(), current.enabled else { return .init(items: []) }
            let allowed = candidates.filter { current.items.contains($0) }
            let byID = Dictionary(uniqueKeysWithValues: allowed.map { ($0.id, $0) })
            var ordered = hits.compactMap { byID[$0] }
            ordered += allowed.filter { !hits.contains($0.id) }
            return .init(items: Array(ordered.prefix(2)))
        } catch {
            guard !Task.isCancelled, let current = try? store.load(), current.enabled else { return .init(items: []) }
            return .init(items: Array(candidates.filter { current.items.contains($0) }.prefix(2)))
        }
    }
}

@MainActor struct AgentMemoryView: View {
    let bot: VillageBot
    var highlighted: [UUID] = []
    @State private var snapshot = AgentMemory.Snapshot()
    @State private var preferences: [AgentChatPreferences.Entry] = []
    @State private var note = ""
    @State private var query = ""
    @State private var matches: [UUID]?
    @State private var busy = false
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var store: AgentMemory.Store { .init(botID: bot.id) }
    private var shown: [AgentMemory.Item] { snapshot.items.reversed().filter { matches == nil || matches!.contains($0.id) } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Brug mine gemte kilder i chatten", isOn: Binding(get: { snapshot.enabled }, set: { snapshot.enabled = $0; save(snapshot) }))
                    Text("Gem noget, du vil slippe for at gentage. Du kan se og slette hvert punkt, og de følger agenten, når du skifter model. Faste ønsker, fx sprog, bevares i agentens profil.").font(.footnote).foregroundStyle(.secondary)
                    TextField("Find et gemt udsagn", text: $query).onChange(of: query) { _, _ in matches = nil }
                    Button("Søg i hukommelsen", systemImage: "magnifyingglass") { search() }.disabled(query.isEmpty || busy)
                    if busy { ProgressView("Søger lokalt…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    Button("Ryd kun søgecachen", systemImage: "arrow.clockwise") { Task { do { try await OrdinaryAgentMemory.index.clear(botID: bot.id); notice = "Søgecachen er ryddet. Dine gemte punkter er bevaret." } catch { notice = error.localizedDescription } } }.frame(minHeight: 44)
                }
                Section("Gem en note") {
                    TextField("Det vil jeg have, at du husker…", text: $note, axis: .vertical).lineLimit(2...5)
                    Button("Gem min note", systemImage: "brain") { do { try store.remember(note.trimmingCharacters(in: .whitespacesAndNewlines), sourceTurnID: nil); note = ""; load() } catch { notice = error.localizedDescription } }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 1_200)
                }
                Section("Gemte kilder · \(snapshot.items.count)") {
                    if shown.isEmpty { Text(matches == nil ? "Tryk og hold på din besked i chatten og vælg Husk det, jeg skrev, eller gem en note her." : "Ingen matchende kilder.") }
                    ForEach(shown) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if highlighted.contains(item.id) { Label("Tilgængelig hukommelseskilde", systemImage: "quote.bubble").font(.caption).foregroundStyle(.mint) }
                            Text(item.quote).textSelection(.enabled)
                            Text(item.sourceTitle + " · " + item.saved.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Button("Glem dette", systemImage: "trash", role: .destructive) { var next = snapshot; next.items.removeAll { $0.id == item.id }; save(next, clearIndex: true) }.frame(minHeight: 44)
                        }
                    }
                }
                if !preferences.isEmpty {
                    Section("Faste ønsker fra profilen") {
                        ForEach(preferences, id: \.self) { entry in VStack(alignment: .leading, spacing: 4) { Text(entry.value); Text(entry.bot == nil ? "Fælles ønske" : "Ønske til \(bot.name)").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                if !snapshot.items.isEmpty { Section { Button("Glem alle gemte kilder for \(bot.name)", role: .destructive) { var next = snapshot; next.items = []; save(next, clearIndex: true) } } }
            }.scrollContentBackground(.hidden).background { FadedBackground() }.navigationTitle("\(bot.name)s hukommelse").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { operation?.cancel(); dismiss() } }.onAppear(perform: load).onDisappear { operation?.cancel() }
        }
    }
    private func load() { do { snapshot = try store.load(); preferences = AgentChatPreferences.entries(for: bot.id) } catch { notice = error.localizedDescription } }
    private func save(_ next: AgentMemory.Snapshot, clearIndex: Bool = false) {
        do {
            try store.save(next); snapshot = next; matches = nil
            if clearIndex { Task { do { try await OrdinaryAgentMemory.index.clear(botID: bot.id) } catch { notice = "Punktet er glemt, men søgecachen kunne ikke ryddes endnu. Prøv igen." } } }
        } catch { notice = error.localizedDescription; load() }
    }
    private func search() {
        guard !busy else { return }; busy = true
        let requested = query
        operation = Task {
            defer { busy = false }
            do { matches = try await OrdinaryAgentMemory.index.search(AgentMemory.words(requested).sorted().joined(separator: " "), botID: bot.id, rows: snapshot.items.map { .init(id: $0.id, text: $0.quote) }); notice = matches!.isEmpty ? "Ingen kilder med de søgeord." : nil }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
