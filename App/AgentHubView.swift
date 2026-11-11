// Agent hub screens, live status and local bot actions.

import Foundation
import SwiftUI

struct AgentHub: View {
    @Environment(\.scenePhase) var hubPhase
    @Environment(\.fadedPalette) var palette
    let api: LiveAPI?
    let isVisible: Bool
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let onBack: () -> Void
    var experimentalWork = ExperimentalVillageWork()
    var onExperimentalAction: (ExperimentalVillageAction) -> Void = { _ in }
    @State private var selectedRoom = "research"
    @AppStorage(AppStorageKeys.villageShowOffice) private var showOffice = true
    @AppStorage(AppStorageKeys.villageExperimentalEnabled) private var experimentalVillageEnabled = false
    var localBotsData: Data { MigratedAppData.shared.villageBots }
    @State var localBot: VillageBot?
    @State private var villageChatBot: VillageBot?
    @State var villagePause = false
    @State var cinematic = false
    @State var villageZoom: CGFloat = 1
    @State var villageOffset: CGSize = .zero
    @State private var showBuilder = false
    @State var offline = false
    @State private var completions = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) private var hubTypeSize
    @AppStorage(AppStorageKeys.qolReduceMotion) var calmMotion = false
    @State var details: V2Hub.Agent?
    @State private var achievements = false

    @State private var remoteTarget: String?
    @State private var storedSnapshot: V2Hub?
    var snapshot: V2Hub? { hasCurrentRemote ? storedSnapshot : nil }
    private var hasCurrentRemote: Bool {
        guard let api else { return false }
        return api.queueTargetID == remoteTarget
    }
    @State private var failure: String?
    @State private var attempt = 0
    @State private var history: [V2History] = []
    @State private var memory: [V2Memory] = []
    @State private var badges: [V2Achievements.Item] = []
    @State private var detailError: String?
    @State private var badgeError: String?
    @State private var detailsLoading = false
    @State private var badgesLoading = false
    @State private var detailAgentID: String?
    @State private var detailRequest: UUID?
    @State private var badgeRequest: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !cinematic { hubHeader }
                ScrollView {
                    hubContent
                }
                .refreshable { attempt += 1 }
            }
            .background { FadedBackground(variant: .village) }
            .foregroundStyle(palette.text)
            .navigationTitle("Landsbyen")
            .toolbarVisibility(cinematic ? .hidden : .visible, for: .navigationBar)
            .sensoryFeedback(.success, trigger: completions)
            .sheet(isPresented: $showBuilder) { botLibrary }
            .sheet(item: $localBot, content: botProfile)
            .sheet(item: $villageChatBot) { bot in
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            }
            .task(id: "\(attempt):\(hubPhase == .active):\(api?.queueTargetID ?? "offline")") {
                resetRemoteIfNeeded()
                if hubPhase == .active { await followHub() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .sheet(item: $details) { agent in
                if hasCurrentRemote { agentDetails(agent) }
            }
            .sheet(isPresented: $achievements) {
                if hasCurrentRemote { achievementPage }
            }
        }
    }

    private var hubHeader: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            FadedSignature()
            if hubTypeSize.isAccessibilitySize {
                hubViewPicker.pickerStyle(.menu).frame(minHeight: 44)
            } else {
                HStack(spacing: FadedSpacing.xs) {
                    hubTab("Kontoret", icon: "building.2", office: true)
                    hubTab("Landsbyen", icon: "house.lodge", office: false)
                }
                .padding(FadedSpacing.xs)
                .background(palette.card, in: RoundedRectangle(cornerRadius: FadedRadius.card))
            }
        }
        .padding(.horizontal, FadedSpacing.edge)
        .padding(.top, FadedSpacing.s)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private func hubTab(_ title: String, icon: String, office: Bool) -> some View {
        let selected = showOffice == office
        return Button { showOffice = office } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected && palette.isDark ? FadedBrand.mint : palette.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? FadedBrand.mint.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: FadedRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var hubContent: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.action) {
            if showOffice && !cinematic {
                PixelOfficeView(workers: officeWorkers, isVisible: villageVisible, onSelect: openOfficeWorker)
            } else {
                village
            }
            if !cinematic {
                if !showOffice && ExperimentalVillageGate.available && experimentalVillageEnabled {
                    ExperimentalVillageView(bots: localVillageBots, work: experimentalWork, paused: villagePause,
                                            isVisible: villageVisible, openProfile: { localBot = $0 },
                                            openWork: onExperimentalAction)
                }
                if offline {
                    Label("PC’en er offline. Botsene hviler.", systemImage: "cloud.rain")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                villageActivity
                hubAgents
            }
        }
        .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }

    private var hubViewPicker: some View {
        Picker("Visning", selection: $showOffice) {
            Text("Kontoret").tag(true)
            Text("Landsbyen").tag(false)
        }
    }

    private var villageActivity: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Aktivitet i landsbyen")
                Toggle("Lad lokale bots hvile", isOn: $villagePause).tint(palette.lime)
                if villageVisible {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        villageBotRows(hour: Calendar.current.component(.hour, from: timeline.date))
                    }
                } else {
                    villageBotRows(hour: Calendar.current.component(.hour, from: .now))
                }
                FadedSecondaryButton("Mine bots", icon: "person.2") { showBuilder = true }
            }
        }
    }

    @ViewBuilder private func villageBotRows(hour: Int) -> some View {
        if localVillageBots.isEmpty {
            Text("Opret en bot under Mine bots, så kan du følge dens hverdag her.")
                .font(.subheadline).foregroundStyle(palette.secondary)
        }
        ForEach(Array(localVillageBots.enumerated()), id: \.element.id) { item in
            let bot = item.element
            let activity = botActivity(bot, routine: (hour + item.offset) % 3, sleeping: villageBotsSleep(hour: hour))
            Divider().overlay(palette.border)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VillageBotAvatar(bot: bot, size: 44, radius: FadedRadius.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.name).font(FadedTypography.section)
                        Text(activity).font(.subheadline).foregroundStyle(palette.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { villageBotActions(bot) }
                    VStack(alignment: .leading) { villageBotActions(bot) }
                }
            }
        }
    }

    @ViewBuilder private func villageBotActions(_ bot: VillageBot) -> some View {
        FadedSecondaryButton("Profil", icon: "person.crop.circle") { localBot = bot }
            .accessibilityLabel("Åbn profil for \(bot.name)")
        FadedSecondaryButton("Chat", icon: "bubble.left") { villageChatBot = bot }
            .accessibilityLabel("Start privat chat med \(bot.name)")
    }

    @ViewBuilder private var hubAgents: some View {
        FadedSectionHeader("PC-agenter")
        if api == nil {
            FadedEmptyState(icon: "desktopcomputer", title: "Ingen PC-forbindelse",
                            detail: "Åbn Forbindelser på Hjem for at se PC’ens agenter.",
                            actionTitle: "Gå til Hjem", action: onBack)
        } else if hasCurrentRemote, let failure, snapshot == nil {
            RetryNotice(message: failure) { attempt += 1 }
        } else if let snapshot {
            if let failure { RetryNotice(message: failure) { attempt += 1 } }
            missionHUD(snapshot.summary)
            if !snapshot.rooms.isEmpty {
                Picker("Rum", selection: $selectedRoom) {
                    ForEach(snapshot.rooms) { room in Text(room.name).tag(room.id) }
                }.frame(minHeight: 48)
            }
            let agents = snapshot.rooms.isEmpty ? snapshot.agents : snapshot.agents.filter { $0.room_id == selectedRoom }
            if agents.isEmpty {
                FadedEmptyState(icon: "person.2", title: "Ingen agenter her",
                                detail: snapshot.rooms.count > 1 ? "Vælg et andet rum, eller opdatér listen." : "Opdatér listen for at se nye agenter.",
                                actionTitle: "Opdatér agenter") { attempt += 1 }
            }
            ForEach(agents) { agent in
                agentCard(agent)
            }
            FadedSecondaryButton("Achievements", icon: "trophy") { achievements = true }
        } else {
            LoadingSkeleton(label: "Henter agenter…")
        }
    }

    private var botLibrary: some View {
        VillageBotLibrary(api: api, studioUnlocked: $studioUnlocked,
                          onPrivateSessionEnded: onPrivateSessionEnded, onBack: { showBuilder = false })
    }

    private func botProfile(_ bot: VillageBot) -> some View {
        NavigationStack {
            VillageBotProfile(botID: bot.id, api: api, studioUnlocked: $studioUnlocked,
                              onPrivateSessionEnded: onPrivateSessionEnded)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left") { localBot = nil }
                    }
                }
        }
    }

    private func missionHUD(_ summary: V2Hub.Summary) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Status på PC’en")
                Label("Aktive agenter · \(summary.active_agents)", systemImage: "person.2")
                Label("Aktive jobs · \(summary.active_jobs)", systemImage: "film")
                Label("XP i alt · \(summary.total_xp)", systemImage: "bolt")
                Label("Streak · \(summary.streak_days) dage", systemImage: "flame")
            }
        }
    }

    private func agentCard(_ agent: V2Hub.Agent) -> some View {
        let state = offline ? V2Hub.Agent.Status.offline : agent.status
        let accent = agentAccent(state)
        let ratio = Double(agent.xp_in_level) / Double(max(1, agent.xp_for_next_level))
        let quests = agent.recent_quests.sorted { $0.updated_at > $1.updated_at }
        return FadedCard(accent: accent) {
            VStack(alignment: .leading, spacing: 10) {
                Label(agent.name, systemImage: icon(agent.icon)).font(FadedTypography.section)
                    .accessibilityAddTraits(.isHeader)
                Text(status(state)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.isDark ? accent : palette.text)
                Text("Niveau \(agent.level) · \(agent.xp_in_level) / \(agent.xp_for_next_level) XP")
                    .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                FadedProgress(value: ratio).accessibilityLabel("XP til næste niveau")
                if !quests.isEmpty {
                    FadedSectionLabel("Seneste opgaver")
                    ForEach(quests.prefix(3)) { quest in
                        Text(quest.title + " · " + questStatus(quest.state)).font(.subheadline)
                    }
                }
                FadedSecondaryButton("Historik og hukommelse", icon: "clock.arrow.circlepath") { details = agent }
                    .accessibilityLabel("Historik og hukommelse for \(agent.name)")
            }
        }
    }

    private func agentAccent(_ state: V2Hub.Agent.Status) -> Color {
        switch state {
        case .working: palette.cyan
        case .thinking: palette.purple
        case .ready: palette.green
        case .offline: palette.muted
        }
    }

    private func agentDetails(_ agent: V2Hub.Agent) -> some View {
        let history = detailAgentID == agent.id ? self.history : []
        let memory = detailAgentID == agent.id ? self.memory : []
        let loading = detailAgentID != agent.id || detailsLoading
        return NavigationStack {
            List {
                if loading { LoadingSkeleton(label: "Henter agentdetaljer…") }
                if detailAgentID == agent.id, let detailError {
                    RetryNotice(message: detailError) { Task { await loadDetails(agent.id) } }
                }
                Section("Status") { Text("\(status(agent.status)) · \(agent.xp) XP") }
                Section("Historik") {
                    if history.isEmpty && !loading { Text("Ingen historik at vise.") }
                    ForEach(history) { item in
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.at.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            if let summary = item.summary { Text(summary) }
                        }
                    }
                }
                Section("Værktøjskald") {
                    let tools = history.filter { $0.kind == "tool_call" }
                    if tools.isEmpty && !loading { Text("Ingen værktøjskald at vise.") }
                    ForEach(tools) { item in Text(item.tool_name ?? item.title) }
                }
                Section("Hukommelse") {
                    if memory.isEmpty && !loading { Text("Ingen hukommelse at vise.") }
                    ForEach(memory) { item in
                        VStack(alignment: .leading) {
                            Text(item.title).font(.headline)
                            Text(item.summary)
                        }
                    }
                }
            }.navigationTitle(agent.name)
                .toolbar { Button("Luk") { details = nil } }
                .task(id: agent.id) { await loadDetails(agent.id) }
        }
    }

    private var achievementPage: some View {
        NavigationStack {
            List {
                if badgesLoading { LoadingSkeleton(label: "Henter achievements…") }
                if let badgeError { RetryNotice(message: badgeError) { Task { await loadBadges() } } }
                if badges.isEmpty && !badgesLoading && badgeError == nil { Text("Ingen achievements endnu.") }
                ForEach(badges) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.description)
                            Text(item.earned_at == nil ? "\(item.current) / \(item.target) · Låst" : "Optjent")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: icon(item.icon))
                            .foregroundStyle(item.earned_at == nil ? Color.secondary : Color.orange)
                    }.frame(minHeight: 56)
                }
            }.navigationTitle("Achievements")
                .toolbar { Button("Luk") { achievements = false } }
                .task { await loadBadges() }
        }
    }

    private func followHub() async {
        failure = nil
        guard let api else { failure = "Forbind til din PC i Indstillinger."; return }
        let target = api.queueTargetID
        var delay = 2
        while !Task.isCancelled && remoteTarget == target {
            do {
                let initial = try await api.v2Hub()
                try Task.checkCancellation()
                guard remoteTarget == target else { return }
                apply(initial)
                failure = nil
                delay = 2
                try await api.v2HubEvents(after: initial.revision) { event in
                    guard let updated = try? await api.v2Hub() else { return }
                    await MainActor.run {
                        if !Task.isCancelled, remoteTarget == target,
                           event.type == .resync_required || updated.revision >= (snapshot?.revision ?? 0) {
                            apply(updated)
                        }
                    }
                }
            } catch {
                AppDiagnostics.record(error)
                guard !Task.isCancelled, remoteTarget == target else { return }
                if let networkError = error as? URLError {
                    offline = [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
                               .timedOut, .cannotFindHost].contains(networkError.code)
                }
                failure = "Kunne ikke hente Agent-Hub. Tjek forbindelsen til PC’en."
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { AppDiagnostics.record(error); return }
            delay = min(delay * 2, 30)
        }
    }

    private func resetRemoteIfNeeded() {
        let target = api?.queueTargetID
        guard remoteTarget != target else { return }
        remoteTarget = target
        storedSnapshot = nil
        if target != nil { offline = false }
        failure = nil
        details = nil
        achievements = false
        detailAgentID = nil
        detailRequest = nil
        badgeRequest = nil
        history = []
        memory = []
        badges = []
        detailError = nil
        badgeError = nil
        detailsLoading = false
        badgesLoading = false
    }

    private func apply(_ value: V2Hub) {
        if let snapshot {
            let previous = Set(snapshot.agents.flatMap(\.recent_quests).filter { $0.state == .completed }.map(\.id))
            let next = Set(value.agents.flatMap(\.recent_quests).filter { $0.state == .completed }.map(\.id))
            if !next.subtracting(previous).isEmpty { completions += 1 }
        }
        offline = false
        storedSnapshot = value
        if !value.rooms.contains(where: { $0.id == selectedRoom }) {
            selectedRoom = value.rooms.first?.id ?? ""
        }
    }

    private func loadDetails(_ id: String) async {
        guard let api, hasCurrentRemote, details?.id == id else { return }
        let target = api.queueTargetID
        let request = UUID()
        detailAgentID = id
        detailRequest = request
        history = []; memory = []; detailError = nil; detailsLoading = true
        defer { if detailRequest == request { detailsLoading = false } }
        do {
            async let historyPage = api.v2History(agentID: id)
            async let memoryPage = api.v2Memory(agentID: id)
            let (h, m) = try await (historyPage, memoryPage)
            try Task.checkCancellation()
            guard remoteTarget == target, detailRequest == request, details?.id == id else { return }
            history = h.items; memory = m.items
        } catch {
            AppDiagnostics.record(error)
            if !Task.isCancelled, remoteTarget == target, detailRequest == request, details?.id == id {
                detailError = "Kunne ikke hente agentens detaljer."
            }
        }
    }

    private func loadBadges() async {
        guard let api, hasCurrentRemote else { return }
        let target = api.queueTargetID
        let request = UUID()
        badgeRequest = request
        badgeError = nil; badgesLoading = true
        defer { if badgeRequest == request { badgesLoading = false } }
        do {
            let items = try await api.v2Achievements().items
            try Task.checkCancellation()
            guard remoteTarget == target, badgeRequest == request, achievements else { return }
            badges = items
        } catch {
            AppDiagnostics.record(error)
            if !Task.isCancelled, remoteTarget == target, badgeRequest == request, achievements {
                badgeError = "Kunne ikke hente achievements."
            }
        }
    }

    func icon(_ value: String) -> String {
        value == "search" ? "magnifyingglass" : value
    }

    func status(_ value: V2Hub.Agent.Status) -> String {
        switch value {
        case .working: "Arbejder"
        case .thinking: "Tænker"
        case .ready: "Klar"
        case .offline: "Offline"
        }
    }

    private func questStatus(_ value: V2Hub.Quest.State) -> String {
        switch value {
        case .queued: "I kø"
        case .running: "I gang"
        case .completed: "Færdig"
        case .failed: "Fejlede"
        }
    }
}
