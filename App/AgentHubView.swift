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
    @AppStorage(AppStorageKeys.villageShowOffice) private var showOffice = false
    @AppStorage(AppStorageKeys.villageExperimentalEnabled) private var experimentalVillageEnabled = false
    var localBotsData: Data { MigratedAppData.shared.villageBots }
    @State var localBot: VillageBot?
    @State private var villageChatBot: VillageBot?
    @State var villagePause = false
    @State var cinematic = false
    @State private var showBuilder = false
    @State var offline = false
    @State private var wasOffline = false
    @State private var completions = 0
    @StateObject private var life = VillageLifeSimulator()
    @State private var inspectedLifeBot: VillageLifeBot?
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
                if showOffice && !cinematic {
                    VillageOfficeView(bots: life.bots, onSelect: openLifeBot)
                        .refreshable { attempt += 1 }
                } else {
                    ScrollView {
                        hubContent
                    }
                    .refreshable { attempt += 1 }
                }
            }
            .background { FadedBackground(variant: .village) }
            .foregroundStyle(palette.text)
            .navigationTitle(showOffice && !cinematic ? "Kontoret" : "Landsbyen")
            .toolbarVisibility(cinematic ? .hidden : .visible, for: .navigationBar)
            .sensoryFeedback(.success, trigger: completions)
            .sheet(isPresented: $showBuilder) { botLibrary }
            .sheet(item: $localBot, content: botProfile)
            .sheet(item: $villageChatBot) { bot in
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            }
            .sheet(item: $inspectedLifeBot, content: lifeBotInspector)
            .task(id: "\(attempt):\(hubPhase == .active):\(api?.queueTargetID ?? "offline")") {
                resetRemoteIfNeeded()
                if hubPhase == .active { await followHub() }
            }
            .task(id: "life:\(villageVisible):\(reduceMotion || calmMotion):\(offline)") {
                guard villageVisible else { return }
                let calm = reduceMotion || calmMotion
                let nanos: UInt64 = calm ? 2_000_000_000 : 1_000_000_000
                while !Task.isCancelled {
                    life.tick(now: .now, reduceMotion: calm)
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
            .onAppear {
                life.mergeLocalProfiles(localVillageBots)
                life.setPaused(villagePause)
                life.filmMode = cinematic
                if api == nil {
                    offline = true
                    life.applyHubAgents([], offline: true)
                    wasOffline = true
                }
            }
            .onChange(of: villagePause) { _, value in life.setPaused(value) }
            .onChange(of: cinematic) { _, value in life.filmMode = value }
            .onChange(of: showBuilder) { _, open in
                if !open { life.mergeLocalProfiles(localVillageBots) }
            }
            .onChange(of: localBot) { _, _ in life.mergeLocalProfiles(localVillageBots) }
            .onChange(of: offline) { _, value in
                if value {
                    life.applyHubAgents([], offline: true)
                    wasOffline = true
                } else if wasOffline, let snapshot {
                    life.applyHubAgents(snapshot.agents, offline: false)
                    wasOffline = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(cinematic ? "Vis menu" : "Filmtilstand",
                           systemImage: cinematic ? "eye" : "video") { cinematic.toggle() }
                    .accessibilityLabel(cinematic ? "Afslut filmtilstand" : "Start filmtilstand")
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
            if hubTypeSize.isAccessibilitySize {
                hubViewPicker.pickerStyle(.menu).frame(minHeight: 44)
            } else {
                hubViewPicker.pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, FadedSpacing.edge)
        .padding(.top, FadedSpacing.s)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var hubContent: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.action) {
            villageMapChrome
            if !cinematic {
                if ExperimentalVillageGate.available && experimentalVillageEnabled {
                    ExperimentalVillageView(bots: localVillageBots, work: experimentalWork, paused: villagePause,
                                            isVisible: villageVisible, openProfile: { localBot = $0 },
                                            openWork: onExperimentalAction)
                }
                if offline {
                    Label(VillageCopy.pcUnavailable, systemImage: "cloud.rain")
                        .font(.subheadline).foregroundStyle(palette.secondary)
                }
                if let banner = life.banner, !banner.isEmpty {
                    Text(banner).font(.subheadline).foregroundStyle(palette.secondary)
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
        .accessibilityLabel("Visning · \(showOffice ? "Kontoret" : "Landsbyen")")
    }

    private var villageMapChrome: some View {
        let hour = Calendar.current.component(.hour, from: life.virtualClock)
        let night = hour < 7 || hour >= 22
        return ZStack(alignment: .topTrailing) {
            VillageMapView(
                bots: life.bots,
                night: night,
                cinematic: cinematic,
                reduceMotion: reduceMotion || calmMotion,
                offline: offline,
                banner: life.banner,
                onSelect: openLifeBot
            )
            if cinematic {
                HStack(spacing: 8) {
                    Button("Kontor") { showOffice = true; cinematic = false }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundStyle(palette.text)
                        .fadedGlassSurface(radius: FadedRadius.medium)
                    Button {
                        cinematic = false
                    } label: {
                        Label("Vis menu", systemImage: "eye").labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(palette.text)
                            .fadedGlassSurface()
                    }
                    .accessibilityLabel("Afslut filmtilstand")
                }
                .padding(12)
            }
        }
    }

    private var villageActivity: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Aktivitet i landsbyen")
                Toggle("Pause landsbyen", isOn: $villagePause).tint(palette.lime)
                Text("Lokale bots lever på telefonen. Bekræftede PC-opgaver vises, når hub’en er online.")
                    .font(.caption).foregroundStyle(palette.secondary)
                lifeBotRows
                FadedSecondaryButton("Mine bots", icon: "person.2") { showBuilder = true }
            }
        }
    }

    @ViewBuilder private var lifeBotRows: some View {
        if life.bots.isEmpty {
            Text("Adam og Eva vågner, når landsbyen starter.")
                .font(.subheadline).foregroundStyle(palette.secondary)
        }
        ForEach(life.bots) { bot in
            Divider().overlay(palette.border)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    VillageBotSprite(bot: bot, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.displayName).font(FadedTypography.section)
                        Text(bot.poseLabel + " · " + bot.zoneID.title)
                            .font(.subheadline).foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { openLifeBot(bot) }
                lifeBotActions(bot)
            }
        }
    }

    @ViewBuilder private func lifeBotActions(_ bot: VillageLifeBot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { lifeBotActionButtons(bot) }
            VStack(alignment: .leading) { lifeBotActionButtons(bot) }
        }
    }

    @ViewBuilder private func lifeBotActionButtons(_ bot: VillageLifeBot) -> some View {
        FadedSecondaryButton("Profil", icon: "person.crop.circle") { openLifeBot(bot) }
            .accessibilityLabel("Åbn profil for \(bot.displayName)")
        if let local = matchedLocalBot(bot) {
            FadedSecondaryButton("Chat", icon: "bubble.left") { villageChatBot = local }
                .accessibilityLabel("Start privat chat med \(bot.displayName)")
        }
    }

    private func matchedLocalBot(_ bot: VillageLifeBot) -> VillageBot? {
        localVillageBots.first {
            $0.id.uuidString == bot.id ||
            $0.name.localizedCaseInsensitiveCompare(bot.displayName) == .orderedSame
        }
    }

    private func openLifeBot(_ bot: VillageLifeBot) {
        if let agent = snapshot?.agents.first(where: {
            $0.id == bot.linkedAgentID ||
            $0.id == bot.id ||
            $0.name.localizedCaseInsensitiveCompare(bot.displayName) == .orderedSame
        }) {
            details = agent
            return
        }
        if let local = matchedLocalBot(bot) {
            localBot = local
            return
        }
        inspectedLifeBot = bot
    }

    private func lifeBotInspector(_ bot: VillageLifeBot) -> some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(bot.poseLabel)
                    Text(bot.zoneID.title)
                    Text("Energi \(Int(bot.needs.energy * 100))%")
                    Text("Social \(Int(bot.needs.social * 100))%")
                    Text("Arbejdsglæde \(Int(bot.needs.fulfillment * 100))%")
                    if bot.pcJobRunning { Text("PC-opgave i gang") }
                    if bot.pcJobQueued { Text("Venter på en opgave") }
                    if let live = bot.pcLiveLabel { Text(live) }
                }
                if bot.carrying != nil {
                    Section("Bærer") { Text(bot.carrying?.label ?? "Pakke") }
                }
                Section {
                    FadedSecondaryButton("Mine bots", icon: "person.2") {
                        inspectedLifeBot = nil
                        showBuilder = true
                    }
                }
            }
            .navigationTitle(bot.displayName)
            .toolbar { Button("Luk") { inspectedLifeBot = nil } }
        }
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
                // Any hub fetch failure means PC jobs are no longer confirmed — clear markers.
                offline = true
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
        // Drop previous hub’s PC markers immediately on disconnect or PC switch.
        life.applyHubAgents([], offline: true)
        wasOffline = true
        offline = (target == nil)
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
        wasOffline = false
        storedSnapshot = value
        life.applyHubAgents(value.agents, offline: false)
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
