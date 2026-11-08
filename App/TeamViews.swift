// Team roster, agent activity and approval shortcuts.

import Foundation
import SwiftUI

struct TeamRoster: View {
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let close: (() -> Void)?

    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    private var savedBots: Data { MigratedAppData.shared.villageBots }
    @AppStorage(AppStorageKeys.teamFavorites) private var favorites = ""
    @AppStorage(AppStorageKeys.teamFavoritesExpanded) private var favoritesOpen = true
    @AppStorage(AppStorageKeys.teamActiveExpanded) private var activeOpen = true
    @AppStorage(AppStorageKeys.teamSleepingExpanded) private var sleepingOpen = false
    @State private var hub: V2Hub?
    @State private var approvals: [CodeBatchList.Job]?
    @State private var route: Route?
    @State private var refresh = 0
    @State private var query = ""
    @State private var page: Page = .roster

    private enum Page: String, CaseIterable {
        case roster = "Bots"
        case approvals = "Godkend"
        case workflows = "Opgaver"
    }

    private enum Route: Identifiable {
        case profile(VillageBot), chat(VillageBot), edit(VillageBot), newBot
        case approval(String), agent(V2Hub.Agent)
        case workflow(TeamWorkflowMode), notebook(VillageBot), routines

        var id: String {
            switch self {
            case .profile(let bot): "profile-\(bot.id)"
            case .chat(let bot): "chat-\(bot.id)"
            case .edit(let bot): "edit-\(bot.id)"
            case .newBot: "new"
            case .approval(let id): "approval-\(id)"
            case .agent(let agent): "agent-\(agent.id)"
            case .workflow(let mode): "workflow-\(mode.rawValue)"
            case .notebook(let bot): "notebook-\(bot.id)"
            case .routines: "routines"
            }
        }
    }

    private var bots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: savedBots)) ?? [] }
    private var pinned: Set<UUID> {
        Set(favorites.split(separator: ",").compactMap { UUID(uuidString: String($0)) }).intersection(bots.map(\.id))
    }
    private var visibleBots: [VillageBot] {
        bots.filter { matches($0.name, $0.specialtyTitle, $0.responsibility ?? "") }
    }
    private var agents: [V2Hub.Agent] {
        (hub?.agents ?? []).filter { matches($0.name, $0.room_id, isChief($0) ? "Chief Stabschef" : "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            HStack {
                Text("Holdet").font(FadedTypography.title).accessibilityAddTraits(.isHeader)
                Spacer()
                if let close {
                    Button("Luk Holdet", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
            FadedSignature()
            if let hub {
                Text("\(hub.summary.active_agents) aktive på PC · \(hub.summary.active_jobs) jobs")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
            else { pagePicker.pickerStyle(.segmented) }
            if page == .roster {
                TextField("Søg navn eller speciale", text: $query)
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44).accessibilityLabel("Søg i Holdet")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    switch page {
                    case .roster: rosterSection
                    case .approvals: approvalSection
                    case .workflows: workflowSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await reload() }
        }
        .padding(FadedSpacing.edge)
        .background { FadedBackground() }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.border).frame(width: 1).accessibilityHidden(true) }
        .task(id: "\(phase):\(refresh)") {
            guard phase == .active, api != nil else { return }
            repeat {
                await reload()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .sheet(item: $route, onDismiss: { refresh += 1 }) { destination in
            switch destination {
            case .profile(let bot):
                navigationSheet {
                    VillageBotProfile(botID: bot.id, api: api, studioUnlocked: $studioUnlocked,
                                      onPrivateSessionEnded: onPrivateSessionEnded)
                }
            case .chat(let bot):
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            case .edit(let bot):
                VillageBotBuilder(api: api, bot: bot, onBack: { route = nil })
            case .newBot:
                VillageBotBuilder(api: api, onBack: { route = nil })
            case .approval(let id):
                if let api { navigationSheet { BatchProposalView(api: api, id: id) } }
            case .agent(let agent):
                if let api { navigationSheet { TeamAgentActivity(api: api, agent: agent) } }
            case .workflow(let mode):
                navigationSheet { TeamWorkflowView(mode: mode, bots: bots) }
            case .notebook(let bot):
                navigationSheet { TeamBotNotebook(botID: bot.id) }
            case .routines:
                if let api { navigationSheet { TeamPCRoutinesView(api: api) } }
            }
        }
    }

    private var pagePicker: some View {
        Picker("Visning i Holdet", selection: $page) {
            ForEach(Page.allCases, id: \.self) { item in
                if item == .approvals, let count = approvals?.count, count > 0 {
                    Text("Godkend (\(count))").tag(item)
                } else { Text(item.rawValue).tag(item) }
            }
        }.frame(minHeight: 44)
    }

    @ViewBuilder private var rosterSection: some View {
        if let chief = agents.first(where: isChief) { agentRow(chief, chief: true) }
        if visibleBots.contains(where: { pinned.contains($0.id) }) {
            DisclosureGroup("Favoritter", isExpanded: $favoritesOpen) {
                ForEach(visibleBots.filter { pinned.contains($0.id) }, content: botRow)
            }
        }
        DisclosureGroup("På telefonen", isExpanded: $activeOpen) {
            ForEach(visibleBots.filter { !pinned.contains($0.id) }, content: botRow)
            if visibleBots.isEmpty { Text(query.isEmpty ? "Ingen bots endnu." : "Ingen bots matcher.").font(.caption) }
        }
        if hub != nil { agentSections }
        Group {
            if close == nil { FadedSecondaryButton("Ny bot", icon: "plus") { route = .newBot } }
            else { FadedPrimaryButton("Ny bot", icon: "plus") { route = .newBot } }
        }.disabled(bots.count >= 10)
        if bots.count >= 10 { Text("Der er plads til 10 bots.").font(.caption) }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionLabel("Samarbejde på telefonen")
            ForEach([TeamWorkflowMode.group, .handoff, .debate, .chief]) { mode in
                Button { route = .workflow(mode) } label: {
                    FadedCard(accent: palette.cyan) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(mode.title, systemImage: mode.icon).font(FadedTypography.action)
                            Text(mode.detail).font(.subheadline).foregroundStyle(palette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
            }
            FadedSectionLabel("Færdigheder")
            if bots.isEmpty {
                Text("Opret en bot under Bots for at gemme en færdighed.")
                    .font(.subheadline).foregroundStyle(palette.secondary)
            } else {
                Menu("Vælg bottens notesbog", systemImage: "book.closed") {
                    ForEach(bots) { bot in Button(bot.name) { route = .notebook(bot) } }
                }.frame(minHeight: 44)
            }
            FadedSectionLabel("På PC’en")
            FadedSecondaryButton("Planlagte rutiner", icon: "calendar.badge.clock") { route = .routines }
                .disabled(api == nil)
            if api == nil {
                Text("Forbind til PC’en for at se eller ændre dens Git-rutiner.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
    }

    @ViewBuilder private var approvalSection: some View {
        FadedSectionLabel("Venter på dig")
        if let approvals {
            if approvals.isEmpty {
                Label("Ingen kodeforslag venter på dig.", systemImage: "checkmark.circle").font(.subheadline)
            }
            ForEach(approvals) { job in
                Button { route = .approval(job.id) } label: {
                    FadedCard(accent: palette.coral) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Code Bot · Gennemgå forslag").font(FadedTypography.action)
                            Text(job.goal).lineLimit(3)
                            Text(job.repo).font(.caption.monospaced()).foregroundStyle(palette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
            }
        } else {
            Text(api == nil ? "Forbind til PC’en for at se forslag." : "Kan ikke vise kodeforslag endnu.")
                .font(.subheadline).foregroundStyle(palette.secondary)
            if api != nil {
                FadedSecondaryButton("Opdatér", icon: "arrow.clockwise") { refresh += 1 }
            }
        }
    }

    private var agentSections: some View {
        let specialists = agents.filter { !isChief($0) }
        return Group {
            FadedSectionLabel("Aktive på PC")
            ForEach(specialists.filter { $0.status != .offline }) { agent in agentRow(agent) }
            DisclosureGroup("Sovende", isExpanded: $sleepingOpen) {
                ForEach(specialists.filter { $0.status == .offline }) { agent in agentRow(agent) }
            }
        }
    }

    private func botRow(_ bot: VillageBot) -> some View {
        Button { route = .chat(bot) } label: {
            FadedCard(accent: palette.green) {
                HStack(spacing: 8) {
                    VillageBotAvatar(bot: bot, size: 44, radius: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.name).font(FadedTypography.action)
                        Text(bot.specialtyTitle).font(.caption).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Chat", systemImage: "bubble.left") { route = .chat(bot) }
            Button("Se profil", systemImage: "person.crop.circle") { route = .profile(bot) }
            Button("Redigér", systemImage: "pencil") { route = .edit(bot) }
            Button(pinned.contains(bot.id) ? "Fjern favorit" : "Gør til favorit", systemImage: "star") {
                var ids = pinned
                if ids.contains(bot.id) { ids.remove(bot.id) }
                else if ids.count < 3 { ids.insert(bot.id) }
                favorites = ids.map(\.uuidString).sorted().joined(separator: ",")
            }.disabled(pinned.count >= 3 && !pinned.contains(bot.id))
        }
    }

    private func agentRow(_ agent: V2Hub.Agent, chief: Bool = false) -> some View {
        let (status, color): (String, Color) = switch agent.status {
        case .working: ("Arbejder", palette.lime)
        case .thinking: ("Tænker", palette.cyan)
        case .ready: ("Klar", palette.green)
        case .offline: ("Sover", palette.muted)
        }
        return Button { route = .agent(agent) } label: {
            FadedCard(accent: color) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(chief ? "Chief" : agent.name, systemImage: chief ? "crown" : "desktopcomputer")
                        .font(FadedTypography.action)
                    if chief { Text("Stabschef · Koordinerer holdet").font(.caption) }
                    Text(status).font(.caption).foregroundStyle(palette.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(.plain)
    }

    private func navigationSheet<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content().toolbar { Button("Luk") { route = nil } }
        }
    }

    private func matches(_ fields: String...) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || fields.contains { $0.localizedStandardContains(term) }
    }

    private func isChief(_ agent: V2Hub.Agent) -> Bool {
        ["manager", "chief"].contains(agent.id.lowercased())
    }

    private func reload() async {
        guard let api else { return }
        async let snapshot = try? api.v2Hub()
        async let batches = try? api.codeBatches()
        let (nextHub, nextBatches) = await (snapshot, batches)
        guard !Task.isCancelled else { return }
        hub = nextHub
        approvals = nextBatches?.jobs.filter { $0.status == "review" }
    }
}

private struct TeamAgentActivity: View {
    let api: LiveAPI
    let agent: V2Hub.Agent
    @State private var history: [V2History]?

    var body: some View {
        List {
            Section("Seneste aktivitet") {
                if let history {
                    if history.isEmpty { Text("Ingen aktivitet endnu.") }
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            Text(item.at, format: .dateTime.day().month().hour().minute()).font(.caption)
                        }
                    }
                } else {
                    Text("Hent agentens seneste aktivitet fra PC’en.")
                    FadedSecondaryButton("Opdatér", icon: "arrow.clockwise") { Task { await load() } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle(agent.name)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async { history = try? await api.v2History(agentID: agent.id).items }
}
