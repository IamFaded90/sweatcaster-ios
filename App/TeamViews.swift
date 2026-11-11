// Team roster, agent activity and approval shortcuts.

import Foundation
import SwiftUI

struct TeamRoster: View {
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let connectPC: () -> Void
    let close: (() -> Void)?
    @Binding var compact: Bool

    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    private var savedBots: Data { MigratedAppData.shared.villageBots }
    @AppStorage(AppStorageKeys.teamFavorites) private var favorites = ""
    @AppStorage(AppStorageKeys.teamFavoritesExpanded) private var favoritesOpen = true
    @AppStorage(AppStorageKeys.teamActiveExpanded) private var activeOpen = true
    @AppStorage(AppStorageKeys.teamSleepingExpanded) private var sleepingOpen = false
    @State private var storedHub: V2Hub?
    @State private var storedApprovals: [CodeBatchList.Job]?
    @State private var storedApprovalError: AppErrorPresentation?
    @State private var snapshotTargetID: String?
    @State private var reloadID: UUID?
    @State private var route: Route?
    @State private var refresh = 0
    @State private var query = ""
    @State private var page: Page = .roster
    enum Page: String, CaseIterable {
        case roster = "Bots"
        case approvals = "Godkend"
        case workflows = "Opgaver"
    }

    private enum Route: Identifiable {
        case profile(VillageBot), chat(VillageBot), edit(VillageBot), newBot
        case approval(id: String, targetID: String), agent(V2Hub.Agent, targetID: String)
        case workflow(TeamWorkflowMode), notebook(VillageBot), routines

        var id: String {
            switch self {
            case .profile(let bot): "profile-\(bot.id)"
            case .chat(let bot): "chat-\(bot.id)"
            case .edit(let bot): "edit-\(bot.id)"
            case .newBot: "new"
            case .approval(let id, let targetID): "approval-\(targetID)-\(id)"
            case .agent(let agent, let targetID): "agent-\(targetID)-\(agent.id)"
            case .workflow(let mode): "workflow-\(mode.rawValue)"
            case .notebook(let bot): "notebook-\(bot.id)"
            case .routines: "routines"
            }
        }
    }

    private var hasCurrentSnapshot: Bool { api != nil && snapshotTargetID == api?.queueTargetID }
    private var hub: V2Hub? { hasCurrentSnapshot ? storedHub : nil }
    private var approvals: [CodeBatchList.Job]? { hasCurrentSnapshot ? storedApprovals : nil }
    private var approvalError: AppErrorPresentation? { hasCurrentSnapshot ? storedApprovalError : nil }
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

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            HStack {
                Text("Holdet").font(FadedTypography.title).accessibilityAddTraits(.isHeader)
                Spacer()
                if let close {
                    Button("Luk Holdet", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Fold Holdet sammen", systemImage: "sidebar.left") { compact = true }
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
                LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                    switch page {
                    case .roster: rosterSection
                    case .approvals: approvalSection(showAll: true)
                    case .workflows: workflowSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page)
            .refreshable { await reload() }
        }
    }

    var body: some View {
        Group {
            if close == nil && compact {
                TeamSidebarRail(page: page, approvals: approvals?.count ?? 0) { destination in
                    if let destination { page = destination }
                    compact = false
                }
            } else { expandedSidebar.padding(FadedSpacing.edge) }
        }
        .background { FadedBackground() }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.border).frame(width: 1).accessibilityHidden(true) }
        .task(id: "\(api?.queueTargetID ?? ""):\(phase):\(refresh)") {
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
            case .approval(let id, let targetID):
                navigationSheet {
                    if let api, api.queueTargetID == targetID {
                        BatchProposalView(api: api, id: id).id(targetID)
                    } else {
                        FadedEmptyState(icon: "desktopcomputer", title: "Forbind til den oprindelige PC",
                                        detail: "Luk gennemgangen, og forbind til den PC, der oprettede forslaget.")
                    }
                }
            case .agent(let agent, let targetID):
                navigationSheet {
                    if let api, api.queueTargetID == targetID {
                        let latest = hub?.agents.first { $0.id == agent.id }
                        TeamAgentActivity(api: api, agent: latest ?? agent, snapshotIsCurrent: latest != nil, reloadTasks: reload)
                    } else {
                        FadedEmptyState(icon: "desktopcomputer", title: "Forbind til den oprindelige PC",
                                        detail: "Agentens aktivitet ligger på den PC, du åbnede den fra.")
                    }
                }
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
        approvalSection(showAll: false)
        chiefSection
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
        FadedSecondaryButton("Gruppechats", icon: "person.2") { route = .workflow(.group) }
    }

    private var chiefSection: some View {
        let chief = hub?.agents.first(where: isChief)
        return FadedCard(size: .compact, accent: palette.lime) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label("Chief", systemImage: "crown").font(FadedTypography.action)
                FadedDetailText("Stabschef · Koordinerer holdet")
                FadedSecondaryButton("Spørg Chief", icon: "bubble.left") { route = .workflow(.chief) }
                if let chief, let api {
                    let (status, tone) = agentStatus(chief.status)
                    if chief.status == .offline { FadedDetailText(status) }
                    else { FadedBadge(status, tone: tone) }
                    if let work = currentWork(chief) { FadedDetailText(work) }
                    Button("Se Chiefs arbejde", systemImage: "clock") { route = .agent(chief, targetID: api.queueTargetID) }
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private var workflowSection: some View {
        let working = hub?.agents.filter { currentWork($0) != nil } ?? []
        return VStack(alignment: .leading, spacing: FadedSpacing.section) {
            if !working.isEmpty {
                FadedSectionLabel("Seneste aktive PC-opgaver")
                ForEach(working.prefix(4), content: agentRow)
            }
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

    @ViewBuilder private func approvalSection(showAll: Bool) -> some View {
        FadedSectionHeader("Venter på dig", detail: approvals.map { "\($0.count) forslag til gennemgang" })
        if let api, let approvals {
            if approvals.isEmpty {
                FadedBadge("Ingen forslag venter", tone: .success)
            }
            ForEach(showAll ? approvals[...] : approvals.prefix(1)) { job in
                TeamApprovalCard(api: api, job: job) { route = .approval(id: job.id, targetID: api.queueTargetID) }
                    .id("\(api.queueTargetID):\(job.id)")
            }
            if !showAll, approvals.count > 1 {
                FadedSecondaryButton("Se alle \(approvals.count) forslag", icon: "list.bullet") { page = .approvals }
            }
        } else if let approvalError {
            if case .connect = approvalError.fixAction {
                FadedDetailText(approvalError.title)
                FadedSecondaryButton("Tjek forbindelsen", icon: "network", action: connectPC)
            } else {
                RetryNotice(message: approvalError.title) { refresh += 1 }
            }
        } else if api == nil {
            FadedDetailText("Forbind til PC’en for at se forslag.")
            FadedSecondaryButton("Forbind til PC", icon: "network", action: connectPC)
        } else {
            FadedSkeleton(label: "Henter kodeforslag…")
        }
    }

    private var agentSections: some View {
        let specialists = agents.filter { !isChief($0) }
        let active = specialists.filter { $0.status != .offline }
        let sleeping = specialists.filter { $0.status == .offline }
        return Group {
            FadedSectionHeader("Agenter på din PC", detail: "De arbejder på den samme tilsluttede PC.")
            if active.isEmpty { FadedDetailText("Ingen aktive PC-agenter i listen.") }
            ForEach(active) { agent in agentRow(agent) }
            DisclosureGroup("Sovende", isExpanded: $sleepingOpen) {
                if sleeping.isEmpty { FadedDetailText("Ingen sovende PC-agenter i listen.") }
                ForEach(sleeping) { agent in agentRow(agent) }
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

    private func agentStatus(_ status: V2Hub.Agent.Status) -> (String, FadedStatusTone) {
        switch status {
        case .working: ("Arbejder", .warning)
        case .thinking: ("Tænker", .info)
        case .ready: ("Klar", .success)
        case .offline: ("Sover", .info)
        }
    }

    private func currentWork(_ agent: V2Hub.Agent) -> String? {
        guard let api, agent.status != .offline else { return nil }
        let recent = agent.recent_quests.sorted { $0.updated_at > $1.updated_at }
        guard let quest = recent.first(where: { $0.state == .running }) ?? recent.first(where: { $0.state == .queued }) else {
            return nil
        }
        let name = quest.id.hasPrefix("chat:") ? "Chat på PC’en" : api.redactChat(quest.title, complete: true)
        return "\(quest.state.teamPresentation.title) · \(name)"
    }

    @ViewBuilder private func agentRow(_ agent: V2Hub.Agent) -> some View {
        let (status, tone) = agentStatus(agent.status)
        let color = agent.status == .offline ? palette.muted : tone.color(in: palette)
        if let api {
            Button { route = .agent(agent, targetID: api.queueTargetID) } label: {
                FadedCard(accent: color) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(agent.name, systemImage: "desktopcomputer").font(FadedTypography.action)
                        FadedDetailText(status)
                        if let work = currentWork(agent) { FadedDetailText(work) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain)
        }
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
        let targetID = api.queueTargetID
        let request = UUID()
        reloadID = request
        async let snapshot = try? api.v2Hub()
        do {
            let batches = try await api.codeBatches()
            let nextHub = await snapshot
            guard !Task.isCancelled, reloadID == request else { return }
            snapshotTargetID = targetID
            storedHub = nextHub
            storedApprovals = batches.jobs.filter { $0.status == "review" }
            storedApprovalError = nil
        } catch {
            let nextHub = await snapshot
            guard !Task.isCancelled, reloadID == request else { return }
            AppDiagnostics.record(error)
            snapshotTargetID = targetID
            storedHub = nextHub
            storedApprovals = nil
            if case .http(404, _)? = error as? APIError {
                storedApprovalError = AppErrorPresentation(error, title: "PC’en tilbyder ikke kodeforslag. Tjek FadedAI-modulet på PC’en.")
            } else if case .http(401, _)? = error as? APIError {
                storedApprovalError = AppErrorPresentation(error, title: "PC’en afviste forbindelsen. Tjek IP og token.")
            } else {
                let title = pcBusyMessage(error) ?? "Forslagene kunne ikke hentes. Tjek forbindelsen til PC’en."
                storedApprovalError = AppErrorPresentation(error, title: title)
            }
        }
    }
}

private struct TeamApprovalCard: View {
    let api: LiveAPI
    let job: CodeBatchList.Job
    let review: () -> Void

    @Environment(\.fadedPalette) private var palette
    @State private var showPreview = false
    @State private var preview: DiffPreview?
    @State private var previewError: String?
    @State private var retry = 0

    private struct DiffPreview {
        let files: [String]
        let excerpt: String
    }

    var body: some View {
        FadedCard(size: .compact, accent: palette.coral) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label("Code Bot", systemImage: "terminal").font(FadedTypography.action)
                FadedBadge("Venter på godkendelse", tone: .warning)
                Text(verbatim: job.goal).lineLimit(3)
                Text(verbatim: job.repo).font(.caption.monospaced()).foregroundStyle(palette.secondary)
                DisclosureGroup("Vis filer og diff", isExpanded: $showPreview) {
                    previewContent.padding(.top, FadedSpacing.s)
                }.frame(minHeight: 44)
                FadedSecondaryButton("Gennemgå diff", icon: "arrow.up.right", action: review)
            }
        }
        .task(id: "\(showPreview):\(retry)") {
            if showPreview, preview == nil { await loadPreview() }
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let preview {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                if !preview.files.isEmpty {
                    FadedFieldLabel("Berørte filer")
                    ForEach(preview.files, id: \.self) { file in
                        Text(verbatim: file).font(.caption.monospaced())
                    }
                }
                FadedFieldLabel("Uddrag")
                FadedDiff(diff: preview.excerpt)
            }
        } else if let previewError {
            RetryNotice(message: previewError) { retry += 1 }
        } else {
            FadedSkeleton(label: "Henter uddrag…")
        }
    }

    private func loadPreview() async {
        previewError = nil
        do {
            let detail = try await api.codeBatch(job.id)
            try Task.checkCancellation()
            guard detail.id == job.id else { throw V2Failure.invalidResponse }
            guard detail.status == "review", let diff = detail.result?.diff, !diff.isEmpty else {
                previewError = "Uddraget er ikke længere tilgængeligt. Åbn forslaget for at se status."
                return
            }
            let lines = api.redactChat(diff, complete: true).split(separator: "\n", omittingEmptySubsequences: false)
            var seen = Set<String>()
            let files = zip(lines, lines.dropFirst()).compactMap { old, new -> String? in
                guard old.hasPrefix("--- a/"), new.hasPrefix("+++ b/") else { return nil }
                let path = String(new.dropFirst(6))
                return !path.isEmpty && String(old.dropFirst(6)) == path && seen.insert(path).inserted ? path : nil
            }
            let excerpt = lines.prefix(9).map { String($0.prefix(180)) }.joined(separator: "\n")
            preview = DiffPreview(files: Array(files.prefix(5)), excerpt: excerpt)
        } catch {
            guard !Task.isCancelled else { return }
            AppDiagnostics.record(error)
            previewError = "Uddraget kunne ikke hentes. Prøv igen, eller åbn forslaget."
        }
    }
}

private struct TeamAgentActivity: View {
    let api: LiveAPI
    let agent: V2Hub.Agent
    let snapshotIsCurrent: Bool
    let reloadTasks: () async -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var history: [V2History]?
    @State private var historyError: String?
    @State private var requestID: UUID?
    @State private var reload = 0
    @State private var showActivity = false

    var body: some View {
        VStack(spacing: FadedSpacing.s) {
            Group {
                if typeSize.isAccessibilitySize { activityPicker.pickerStyle(.menu) }
                else { activityPicker.pickerStyle(.segmented) }
            }.frame(minHeight: 44).padding(.horizontal, FadedSpacing.edge)
            List {
                if showActivity {
                    Section("Seneste aktivitet") {
                        if let historyError {
                            RetryNotice(message: historyError) { reload += 1 }
                            if let history, !history.isEmpty { FadedDetailText("Sidst hentet fra PC’en") }
                        }
                        if let history {
                            if history.isEmpty && historyError == nil { FadedDetailText("Ingen aktivitet endnu.") }
                            ForEach(history, content: activityRow)
                        } else if historyError == nil {
                            FadedSkeleton(label: "Henter aktivitet…")
                        }
                    }
                } else {
                    Section("Seneste opgaver") {
                        if !snapshotIsCurrent {
                            FadedDetailText("Sidst hentet fra PC’en")
                            FadedSecondaryButton("Opdatér opgaver", icon: "arrow.clockwise") { Task { await reloadTasks() } }
                        }
                        if agent.recent_quests.isEmpty { FadedDetailText("PC’en har ingen seneste opgaver for denne agent.") }
                        ForEach(agent.recent_quests.sorted { $0.updated_at > $1.updated_at }) { quest in
                            VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                                Text(verbatim: api.redactChat(quest.title, complete: true)).font(.headline)
                                FadedBadge(quest.state.teamPresentation.title, tone: quest.state.teamPresentation.tone)
                                Text(quest.updated_at, format: .dateTime.day().month().hour().minute()).font(.caption)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { if showActivity { await load() } else { await reloadTasks() } }
        }
        .background(FadedBackground())
        .navigationTitle(agent.name)
        .task(id: "\(showActivity):\(reload)") {
            if showActivity && (history == nil || historyError != nil) { await load() }
        }
    }

    private var activityPicker: some View {
        Picker("Agentens arbejde", selection: $showActivity) {
            Text("Opgaver").tag(false)
            Text("Aktivitet").tag(true)
        }
    }

    private func activityRow(_ item: V2History) -> some View {
        let title = api.redactChat(item.title, complete: true)
        let summary = item.summary.map { api.redactChat($0, complete: true) }
        return VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            Text(verbatim: title).font(.headline)
            if let state = V2Hub.Quest.State(rawValue: item.state) {
                FadedBadge(state.teamPresentation.title, tone: state.teamPresentation.tone)
            }
            Text(item.at, format: .dateTime.day().month().hour().minute()).font(.caption)
            if let summary, !summary.isEmpty, summary != title {
                DisclosureGroup("Se detaljer") { FadedDetailText(summary) }.frame(minHeight: 44)
            }
        }
    }

    private func load() async {
        let request = UUID()
        requestID = request
        historyError = nil
        do {
            let items = try await api.v2History(agentID: agent.id).items
            try Task.checkCancellation()
            guard requestID == request else { return }
            history = items
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            AppDiagnostics.record(error)
            historyError = "Aktiviteten kunne ikke hentes. Tjek forbindelsen til PC’en."
        }
    }
}

private extension V2Hub.Quest.State {
    var teamPresentation: (title: String, tone: FadedStatusTone) {
        switch self {
        case .queued: ("I kø", .info)
        case .running: ("I gang", .warning)
        case .completed: ("Færdig", .success)
        case .failed: ("Fejl", .error)
        }
    }
}
