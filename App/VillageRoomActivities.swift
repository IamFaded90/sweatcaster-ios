import SwiftUI

@MainActor struct VillageRoomActivities: View {
    let residents: [VillageLifeBot]
    @Environment(\.villagePlannerAPI) private var api
    @Environment(\.scenePhase) private var phase
    @State private var items: [Item] = []
    @State private var profiles: [VillageBot] = []
    @State private var selected: VillageSurprise?
    @State private var creating: VillageBot?
    @State private var refresh = 0
    @State private var notice: String?

    private struct Item: Identifiable {
        let owner: String
        let job: VillageSurprise
        var id: UUID { job.id }
    }

    private var owners: [VillageBot] {
        let ids = Set(residents.compactMap { UUID(uuidString: $0.id) })
        return profiles.filter { ids.contains($0.id) }
    }
    private var requestID: String { residents.map(\.id).sorted().joined(separator: ",") + String(refresh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !items.isEmpty {
                Text("Prøv det, vi har lavet").font(.headline)
                ForEach(items) { item in
                    Button { selected = item.job } label: {
                        FadedCard {
                            HStack(spacing: 12) {
                                Image(systemName: item.job.state == "ready" ? "sparkles" : "wrench.and.screwdriver")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.job.title).font(.headline)
                                    Text(item.owner + " · " + item.job.stateTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            if let owner = owners.first, api != nil {
                FadedSecondaryButton("Bed " + owner.name + " skabe noget til rummet", icon: "sparkles") { creating = owner }
            }
            if api == nil && !residents.isEmpty {
                Text("Forbind din PC for at hente agenternes nye aktiviteter.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: requestID) { await load() }
        .onChange(of: phase) { _, phase in if phase == .active { refresh += 1 } }
        .sheet(item: $selected, onDismiss: { refresh += 1 }) { job in
            if let api { VillageSurpriseDetails(api: api, job: job) }
        }
        .sheet(item: $creating, onDismiss: { refresh += 1 }) { owner in
            VillageSurprisesView(api: api, bot: owner)
        }
    }

    private func load() async {
        profiles = (try? MigratedAppData.shared.loadBots().get()) ?? []
        guard let api else { items = []; return }
        var found: [Item] = []
        do {
            struct Library: Decodable { let items: [VillageSurprise] }
            for owner in owners {
                let result: Library = try await api.moduleJSON("village-surprises",
                    query: [.init(name: "bot_id", value: owner.id.uuidString)])
                try Task.checkCancellation()
                found.append(contentsOf: result.items.filter { ["ready", "kept"].contains($0.state) }.map {
                    Item(owner: owner.name, job: $0)
                })
            }
            items = found
            notice = nil
        } catch is CancellationError { return }
        catch {
            items = []
            notice = (error as? APIError)?.title ?? "Aktiviteterne kunne ikke hentes fra PC’en."
        }
    }
}
