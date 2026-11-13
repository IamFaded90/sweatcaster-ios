// Agent hub screens, live status and local bot actions.

import Foundation
import SwiftUI

@MainActor struct AgentHub: View {
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
    @State private var showOffice = false
    @AppStorage(AppStorageKeys.villageExperimentalEnabled) private var experimentalVillageEnabled = false
    var localBotsData: Data { MigratedAppData.shared.villageBots }
    @State private var localBot: VillageBot?
    @State private var computerBot: VillageBot?
    @State private var villageChatBot: VillageBot?
    var villagePause: Bool { simulation.isPaused }
    @State private var cinematic = true
    @StateObject private var life = VillageLifeSimulator()
    @State private var inspectedLifeBot: VillageLifeBot?
    @State private var showBuilder = false
    @State var offline = false
    @State private var completions = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
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
    @State private var observedBotTarget: String?
    @State private var botStatusNotice: String?

    private struct BotActivityRequest: Equatable {
        let targetID: String?
        let ids: [UUID]
        let visible: Bool
        let attempt: Int
    }

    private var simulation: SimulationEngine { .shared }

    private var botActivityRequest: BotActivityRequest {
        let visible = villageVisible && computerBot == nil && localBot == nil && villageChatBot == nil &&
            !showBuilder && details == nil && !achievements && inspectedLifeBot == nil
        return BotActivityRequest(targetID: api?.queueTargetID, ids: localVillageBots.prefix(10).map(\.id),
                                  visible: visible, attempt: attempt)
    }

    var body: some View {
        let request = botActivityRequest
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
            .toolbarVisibility(cinematic && !showOffice ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(isPresented: $showOffice) { office }
            .sensoryFeedback(.success, trigger: completions)
            .sheet(isPresented: $showBuilder) { botLibrary }
            .sheet(item: $localBot, content: botProfile)
            .sheet(item: $computerBot, content: botComputer)
            .sheet(item: $inspectedLifeBot, content: lifeBotInspector)
            .sheet(item: $villageChatBot) { bot in
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            }
            .task(id: "\(attempt):\(hubPhase == .active):\(api?.queueTargetID ?? "offline")") {
                resetRemoteIfNeeded()
                if hubPhase == .active { await followHub() }
            }
            .task(id: request) { await followBotActivity(request) }
            .task(id: villageVisible) {
                guard villageVisible else { return }
                while !Task.isCancelled {
                    life.updateRoundSix(states: simulation.states, activeJobs: simulation.activeJobs,
                                        chatting: simulation.chattingBots, reduceMotion: reduceMotion || calmMotion)
                    life.tick(reduceMotion: reduceMotion || calmMotion)
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                }
            }
            .onChange(of: localBotsData, initial: true) { _, _ in
                life.mergeLocalProfiles(localVillageBots, keepDemoFounders: false)
            }
            .onChange(of: api?.queueTargetID, initial: true) { _, target in
                life.setDemoClock(target == nil)
            }
            .onChange(of: villageVisible, initial: true) { _, visible in
                life.setActive(visible)
            }
            .onChange(of: villagePause, initial: true) { _, paused in life.setPaused(paused) }
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
            Text("Agent-Hub").font(FadedTypography.title).accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, FadedSpacing.edge)
        .padding(.top, FadedSpacing.s)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var hubContent: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.action) {
            villageMap
            if !cinematic {
                if !showOffice && ExperimentalVillageGate.available && experimentalVillageEnabled {
                    ExperimentalVillageView(bots: localVillageBots, work: experimentalWork, paused: villagePause,
                                            isVisible: villageVisible, openProfile: { localBot = $0 },
                                            openWork: onExperimentalAction)
                }
                if offline {
                    Label("Forbindelsen til PC’en er afbrudt.", systemImage: "cloud.rain")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                villageActivity
                hubAgents
            }
        }
        .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }

    private var villageMap: some View {
        let hour = Calendar.current.component(.hour, from: life.virtualClock)
        return VillageMapView(bots: life.bots, night: hour < 7 || hour >= 22,
                              cinematic: cinematic, reduceMotion: reduceMotion || calmMotion,
                              offline: api == nil || offline, banner: life.banner, paused: life.paused,
                              onSelect: openLifeComputer)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    mapControl("Kontor", icon: "desktopcomputer") { showOffice = true }
                    mapControl(cinematic ? "Vis menu" : "Filmtilstand", icon: cinematic ? "eye" : "video") {
                        cinematic.toggle()
                    }
                }
                .padding(8)
            }
    }

    private func mapControl(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .foregroundStyle(palette.text)
                .fadedGlassSurface()
        }
        .accessibilityLabel(title)
    }

    private var office: some View {
        VillageOfficeView(bots: life.bots, onOpenProfile: openLifeProfile, onOpenComputer: openLifeComputer)
            .background { FadedBackground(variant: .village) }
            .foregroundStyle(palette.text)
            .toolbarVisibility(.visible, for: .navigationBar)
    }

    private func matchedLocalBot(_ bot: VillageLifeBot) -> VillageBot? {
        guard let id = UUID(uuidString: bot.id) else { return nil }
        return localVillageBots.first { $0.id == id }
    }

    private func openLifeComputer(_ bot: VillageLifeBot) {
        if let local = matchedLocalBot(bot) { openBotComputer(local) }
        else { openLifeProfile(bot) }
    }

    private func openLifeProfile(_ bot: VillageLifeBot) {
        if let local = matchedLocalBot(bot) { localBot = local }
        else if let agent = snapshot?.agents.first(where: { $0.id == bot.linkedAgentID }) { details = agent }
        else { inspectedLifeBot = bot }
    }

    private func lifeBotInspector(_ bot: VillageLifeBot) -> some View {
        NavigationStack {
            List {
                Text(bot.poseLabel)
                Text(bot.zoneID.title)
            }
            .navigationTitle(bot.displayName)
            .toolbar { Button("Luk") { inspectedLifeBot = nil } }
        }
    }

    private var villageActivity: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Aktivitet i landsbyen")
                Toggle("Sæt dagsrytmen på pause", isOn: Binding(
                    get: { simulation.isPaused }, set: { simulation.setPaused($0) }
                )).tint(palette.lime)
                if villagePause {
                    FadedDetailText("Botternes dagsrytme og behov står stille. PC-opgaver kører videre.")
                }
                if let botStatusNotice {
                    FadedDetailText(botStatusNotice)
                }
                villageBotRows
                FadedSecondaryButton("Mine bots", icon: "person.2") { showBuilder = true }
            }
        }
    }

    @ViewBuilder private var villageBotRows: some View {
        if localVillageBots.isEmpty {
            Text("Opret en bot under Mine bots, så kan du følge dens hverdag her.")
                .font(.subheadline).foregroundStyle(palette.secondary)
        }
        ForEach(localVillageBots) { bot in
            let activity = residentActivity(bot.id)
            let state = simulation.states[bot.id]
            Divider().overlay(palette.border)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VillageBotAvatar(bot: bot, size: 44, radius: FadedRadius.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.name).font(FadedTypography.section)
                        Label(activity.title, systemImage: activity.symbol)
                            .font(.subheadline).foregroundStyle(palette.secondary)
                    }
                }
                if let state {
                    villageNeeds(state)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { villageBotActions(bot) }
                    VStack(alignment: .leading) { villageBotActions(bot) }
                }
            }
        }
    }

    private func villageNeeds(_ state: BotSimulationState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(state.mood.title, systemImage: state.mood.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.mood.tint(palette))
                .accessibilityLabel("Humør: \(state.mood.title)")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { villageNeedValues(state) }
                VStack(alignment: .leading, spacing: 4) { villageNeedValues(state) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondary)
        }
    }

    @ViewBuilder private func villageNeedValues(_ state: BotSimulationState) -> some View {
        Text("Energi \(state.energyDisplay) %")
        Text("Socialt \(state.socialDisplay) %")
        Text("Arbejdsglæde \(state.workJoyDisplay) %")
    }

    func residentActivity(_ id: UUID) -> PixelOfficeWorker.Status {
        if simulation.activeJobs[id] == .running { return .working }
        if simulation.chattingBots.contains(id) { return .chatting }
        if simulation.activeJobs[id] == .queued { return .queued }
        guard let state = simulation.states[id] else { return .loading }
        switch state.currentActivity {
        case .working, .idle: return .ready
        case .resting: return .resting
        case .sleeping: return .sleeping
        }
    }

    private func followBotActivity(_ request: BotActivityRequest) async {
        if observedBotTarget != request.targetID {
            observedBotTarget = request.targetID
            simulation.clearActiveJobs()
            botStatusNotice = nil
        }
        guard request.visible, let target = request.targetID, let api, !request.ids.isEmpty else { return }
        let ids = Set(request.ids)
        var delay = 5
        while !Task.isCancelled && observedBotTarget == target {
            do {
                let activity = try await api.villageBotActivity(ids: request.ids)
                try Task.checkCancellation()
                guard observedBotTarget == target else { return }
                for bot in activity.bots where ids.contains(bot.id) {
                    simulation.ingestJobs(bot.jobs, for: bot.id, targetID: target)
                    life.observeJobs(bot.jobs, botID: bot.id, targetID: target)
                }
                let reported = Set(activity.bots.map(\.id))
                for id in ids.subtracting(reported) {
                    simulation.ingestJobs([], for: id, targetID: target)
                    life.observeJobs([], botID: id, targetID: target)
                }
                botStatusNotice = nil
                delay = 5
            } catch {
                guard !Task.isCancelled, observedBotTarget == target else { return }
                if case .http(404, _)? = error as? APIError {
                    simulation.clearActiveJobs()
                    botStatusNotice = "Opdatér FadedAI på PC’en for at se opgaver her."
                    return
                }
                simulation.clearActiveJobs()
                botStatusNotice = "Status for PC-opgaver er utilgængelig lige nu."
                delay = min(30, delay * 2)
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
    }

    @ViewBuilder private func villageBotActions(_ bot: VillageBot) -> some View {
        FadedSecondaryButton("Computer", icon: "desktopcomputer") { openBotComputer(bot) }
            .accessibilityLabel("Åbn computer for \(bot.name)")
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
                              onPrivateSessionEnded: onPrivateSessionEnded, onFileShared: recordFileShare)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left") { localBot = nil }
                    }
                }
        }
    }

    func openBotComputer(_ bot: VillageBot) {
        computerBot = bot
    }

    private func botComputer(_ bot: VillageBot) -> some View {
        NavigationStack {
            BotComputerView(bot: bot, roster: localVillageBots, api: api, onFileShared: recordFileShare)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left") { computerBot = nil }
                    }
                }
        }
    }

    private func recordFileShare(_ source: UUID, _ recipient: UUID, _ copyID: UUID) {
        guard let target = api?.queueTargetID else { return }
        life.recordFileShare(source: source, recipient: recipient, copyID: copyID, targetID: target)
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
                    if offline { life.setPCOffline(true) }
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
        life.resetPCProjection()
        offline = target == nil
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
        life.setPCOffline(false)
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
