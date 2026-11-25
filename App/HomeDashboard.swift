// Viser forsiden, forbindelsesstatus, cache og global søgning.

import SwiftUI
import UIKit
import AVFoundation

struct DashboardVideoCard: View {
    let file: URL
    @Environment(\.fadedPalette) private var palette
    @State private var preview: UIImage?
    @State private var duration: String?

    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(palette.raised)
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title2).foregroundStyle(palette.secondary)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit).clipped()
                .clipShape(RoundedRectangle(cornerRadius: FadedRadius.media))
                .accessibilityHidden(true)
                Text(file.deletingPathExtension().lastPathComponent).font(FadedTypography.action).lineLimit(1)
                if let duration { Text(duration).font(FadedTypography.number).foregroundStyle(palette.secondary) }
            }
        }
        .task(id: file) { await loadPreview() }
    }

    private func loadPreview() async {
        guard (try? LocalFileStore.checkedFileSize(file, maximumBytes: Int.max)) != nil else { return }
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 320)
        if let result = try? await generator.image(at: .zero), !Task.isCancelled {
            preview = UIImage(cgImage: result.image)
        }
        if let value = try? await asset.load(.duration), value.seconds.isFinite, !Task.isCancelled,
           let seconds = Int(exactly: max(0, value.seconds.rounded())) {
            duration = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }
}

extension Home {
    @ViewBuilder var header: some View {
        FadedDashboardHero(openAssistant: { showAgentAssistant = true }, openVillage: openDashboardVillage,
                           openEvening: { showEvening = true }, openContinue: { selectSpace(.resume) })
        FadedSecondaryButton("Spil et mysterium i landsbyen", icon: "moon.stars") { showMystery = true }
        FadedSecondaryButton("Skab noget med dit kreative hold", icon: "paintbrush.pointed") { showCreativeHub = true }
        DisclosureGroup("Værktøjer og genveje") {
            dashboardMainActions
            quickActions
        }
        if !model.isDemo {
            FadedSecondaryButton("Afventer dig", icon: "tray.full") { showAttentionQueue = true }
        }
        if model.isDemo {
            FadedBadge("Demo · Kun testdata", tone: .info)
        }
        dashboardStatus
        VillageLiveRow(work: experimentalVillageWork, open: openDashboardVillage)
        dashboardActivity
        if !onboarded {
            FadedCard {
                VStack(alignment: .leading, spacing: 8) {
                    heading("Kom godt i gang")
                    Label("1. Vælg en agent eller en oplevelse", systemImage: "sparkles")
                    Label("2. Hent en model til brug uden internet", systemImage: "iphone")
                    Label("3. Fortsæt igen fra Fortsæt-fanen", systemImage: "play.circle")
                    FadedSecondaryButton("Klar") { onboarded = true }
                }
            }
        }
    }

    private func openDashboardVillage() {
        UserDefaults.standard.set(false, forKey: AppStorageKeys.villageShowOffice)
        selectSpace(.village)
    }

    var experimentalVillageWork: ExperimentalVillageWork {
        guard ExperimentalVillageGate.available, let api = studioAPI else { return .init() }
        let jobs = model.jobs
        let code = model.observedCodeJobs
        let target = api.queueTargetID
        let videoIDs = jobs.filter { $0.status == .completed && validWireID($0.id) }.map { "\(target):video:\($0.id)" }
        let codeIDs = code.filter { $0.status == "applied" && validWireID($0.id) }.map { "\(target):code:\($0.id)" }
        return .init(online: true, video: jobs.filter { $0.status.active }.count,
                     code: code.filter { $0.status == "queued" || $0.status == "running" }.count,
                     approvals: code.filter { $0.status == "review" }.count,
                     completedIDs: videoIDs + codeIDs)
    }

    func openExperimentalVillageWork(_ action: ExperimentalVillageAction) {
        switch action {
        case .code: selectSpace(.library)
        case .video: openVideoClips()
        case .library: showPhoneModels = true
        case .approvals:
            if let job = dashboardApprovalJob, let api = studioAPI {
                dashboardApproval = DashboardApproval(id: job.id, api: api)
            }
        }
    }

    @ViewBuilder private var dashboardStatus: some View {
        if model.requiresVideoReview {
            dashboardStatusRow("Tjek dit videojob", detail: "PC’en har ikke bekræftet afsendelsen.",
                               icon: "exclamationmark.circle", accent: palette.coral, actionTitle: "Se videojob") {
                openVideoJobs()
            }
        } else if chatReviewCount > 0 {
            dashboardStatusRow("Chat venter på gennemgang", detail: "Beskeder til gennemgang · \(chatReviewCount)",
                               icon: "exclamationmark.circle", accent: palette.coral, actionTitle: "Se udbakken", action: openChat)
        } else if let approval = dashboardApprovalCard {
            approval
        } else if let job = dashboardActiveVideo {
            dashboardActiveJob(job)
        } else if queuedChatCount > 0 {
            dashboardStatusRow("Chat i kø", detail: "Venter på PC’en · \(queuedChatCount)",
                               icon: "bubble.left", accent: palette.cyan, actionTitle: "Se udbakken", action: openChat)
        } else if !model.videoOutbox.isEmpty {
            dashboardStatusRow("Video i kø", detail: "Venter på PC’en · \(model.videoOutbox.count)",
                               icon: "film", accent: palette.cyan, actionTitle: "Se videokø", action: openVideoJobs)
        } else {
            dashboardConnectionStatus
            if model.connected { loadingStatus }
        }
    }

    private var dashboardConnectionStatus: DashboardConnectionStatus {
        DashboardConnectionStatus(model: model, errorDetails: $errorDetails, errorFocus: $errorFocus,
                                  switchDisabled: { switchDisabled }, fixError: fixDashboardError,
                                  openPhoneChat: openPhoneChat)
    }

    private func fixDashboardError(_ action: AppErrorPresentation.FixAction) {
        switch action {
        case .connect: showLogin = true
        case .reviseInput:
            videoPage = .recipe
            selectSpace(.gallery)
        case .review:
            openVideoJobs()
        case .usePhone: openPhoneChat()
        case .retry: Task { await model.refresh() }
        }
    }

    func refreshQueueBadge() {
        let queue = PCChatOutbox()
        let targetID = (model.api as? LiveAPI)?.queueTargetID
        queuedChatCount = queue.pendingCount(for: model.address, targetID: targetID)
        chatReviewCount = queue.reviewCount(for: model.address, targetID: targetID)
    }

    @ViewBuilder var dashboardConnection: some View {
        if showConnectionBanner && !model.isDemo {
            let status = model.connected ? "PC · \(model.address)" : "Telefon"
            HStack(spacing: 6) {
                Circle().fill(latencyColor(model.connected ? model.latencyMs : nil)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(status).font(.caption.monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("Kører på: \(status)")
            .accessibilityValue(model.latencyMs.map { "\($0) millisekunder til PC" } ?? "Ingen målt forbindelse")
        }
    }

    private var dashboardActiveVideo: DashboardJob? {
        (model.connected || model.isDemo)
            ? model.jobs.first(where: { $0.status.active }).map(DashboardJob.init)
            : (cachedJobAddress == model.address ? cachedJobs.first : nil)
    }

    private func dashboardActiveJob(_ job: DashboardJob) -> DashboardActiveJobCard {
        DashboardActiveJobCard(job: job, isCurrent: model.connected || model.isDemo) {
            searchVideoJobID = job.id
            openVideoJobs()
        }
    }

    private var dashboardApprovalJob: CodeBatchList.Job? {
        guard studioAPI != nil else { return nil }
        return model.observedCodeJobs.first { $0.status == "review" }
    }

    private var dashboardApprovalCard: DashboardStatusCard? {
        guard let job = dashboardApprovalJob, let api = studioAPI else { return nil }
        return dashboardStatusRow("Kodeforslag klar", detail: job.goal, icon: "checkmark.circle",
                                  accent: palette.lime, actionTitle: "Se forslag") {
            dashboardApproval = DashboardApproval(id: job.id, api: api)
        }
    }

    private func dashboardStatusRow(_ title: String, detail: String, icon: String, accent: Color,
                                    actionTitle: String, action: @escaping () -> Void) -> DashboardStatusCard {
        DashboardStatusCard(title: title, detail: detail, icon: icon, accent: accent,
                            actionTitle: actionTitle, action: action)
    }

    private var dashboardMainActions: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: FadedSpacing.s),
                            count: videoTypeSize.isAccessibilitySize ? 1 : 2)
        return LazyVGrid(columns: columns, spacing: FadedSpacing.s) {
            quickAction("Start en samtale", icon: "bubble.left", accent: palette.lime,
                        eyebrow: "Bare en tanke?", action: openNewChat)
            quickAction("Mød din Code Bot", icon: "terminal", accent: palette.green,
                        eyebrow: "Noget at bygge?") { selectSpace(.library) }
        }
    }

    private var quickActions: some View {
        let columns = videoTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 130), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            quickAction("Video Studio", icon: "video", accent: palette.cyan, action: openVideoClips)
            quickAction("Billeder", icon: "photo", accent: palette.cyan) { openStudio(.images) }
            quickAction("Ny bot", icon: "person.crop.circle.badge.plus", accent: palette.purple) { showNewBot = true }
            quickAction("Privat Studio", icon: "lock.shield", accent: palette.purple) { openStudio(.chat) }
        }
    }

    private func quickAction(_ title: String, icon: String, accent: Color,
                             eyebrow: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FadedCard(size: .compact) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon).foregroundStyle(FadedColors.deep).frame(width: 32, height: 32)
                        .background(accent, in: Circle()).accessibilityHidden(true)
                    if let eyebrow { Text(eyebrow).font(.caption).foregroundStyle(palette.secondary) }
                    Text(title).font(FadedTypography.action)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(.plain)
    }

    private var dashboardQueueNeedsAttention: Bool {
        DashboardActivityQueue.needsAttention(model: model, chatReviewCount: chatReviewCount)
    }

    private var dashboardActivitySummary: String {
        guard !model.isDemo else { return "" }
        let waiting = queuedChatCount + model.videoOutbox.filter { $0.state == .waiting }.count
        let statuses: [String?] = [
            dashboardQueueNeedsAttention ? "Afsendelse til gennemgang" : nil,
            dashboardApprovalJob != nil ? "Kodeforslag klar" : nil,
            model.connected && dashboardActiveVideo != nil ? "Video i gang" : nil,
            waiting > 0 ? "\(waiting) i kø" : nil
        ]
        return statuses.compactMap { $0 }.joined(separator: " · ")
    }

    private var dashboardActivity: some View {
        let summary = dashboardActivitySummary
        return Button(action: openDashboardActivity) {
            VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                Label("Seneste aktivitet", systemImage: summary.isEmpty ? "clock" : "tray")
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(palette.secondary)
                }
            }
            .padding(.vertical, summary.isEmpty ? 0 : FadedSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(FadedButtonStyle(kind: .secondary))
    }

    func openDashboardActivity() {
        showDashboardActivity = true
    }

    var dashboardActivityScreen: some View {
        DashboardActivityScreen(
            connection: dashboardConnectionStatus,
            queue: DashboardActivityQueue(model: model, queuedChatCount: $queuedChatCount, chatReviewCount: $chatReviewCount,
                                          openChat: openChat, openVideoJobs: openVideoJobs),
            approval: { dashboardApprovalCard },
            activeJob: { dashboardActiveVideo.map { dashboardActiveJob($0) } },
            recentChats: $recentChats,
            savedVideos: $savedVideos,
            openRecentChat: { turn in
                searchChatQuery = FadedSearchIndex.boundedQuery(turn.prompt)
                openChat()
            },
            playVideo: { media = Media(url: $0, demo: false) },
            openVideoLibrary: {
                reloadSavedVideos()
                showSavedVideos = true
            },
            refresh: refreshDashboard
        )
    }

    func refreshDashboard() {
        reloadSavedVideos()
        if recentChats.isEmpty { recentChats = (try? JSONDecoder().decode([ChatTurn].self, from: dashboardChatPreviews)) ?? [] }
        dashboardRefresh?.cancel()
        dashboardRefresh = Task {
            let archive = MigratedAppData.shared.chatArchive()
            let previews = await Task.detached(priority: .utility) {
                ChatArchive.turns(archived: archive).prefix(3).map { turn in
                    ChatTurn(id: turn.id, prompt: String(turn.prompt.prefix(240)), source: turn.source, createdAt: turn.createdAt)
                }
            }.value
            guard !Task.isCancelled else { return }
            recentChats = previews
            if let data = try? JSONEncoder().encode(previews), dashboardChatPreviews != data {
                do { try MigratedAppData.shared.saveDashboardPreviews(data) }
                catch { AppDiagnostics.record(error) }
            }
        }
    }

    func readJobCache() {
        let address = model.address
        cachedJobAddress = address
        let data = UserDefaults.standard.data(forKey: AppStorageKeys.dashboardJobs(address)) ?? Data()
        cachedJobs = (try? JSONDecoder().decode([DashboardJob].self, from: data)) ?? []
    }

    func cacheJobs() {
        guard model.connected, !model.isDemo, !model.address.isEmpty else { return }
        let jobs = Array(model.jobs.lazy.filter { $0.status.active }.prefix(8).map(DashboardJob.init))
        cachedJobs = jobs
        cachedJobAddress = model.address
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: AppStorageKeys.dashboardJobs(model.address)) }
    }

    func openSearch() {
        searchLoad?.cancel()
        reloadSavedVideos()
        searchRecords = dashboardSearchRecords
        showSearch = true
        searchLoad = Task {
            let archive = MigratedAppData.shared.chatArchive()
            let worker = Task.detached(priority: .userInitiated) {
                ChatArchive.turns(archived: archive).prefix(1_500).map { turn in
                    let source: FadedSearchSource = turn.source == GrokAPI.sourceLabel ? .cloud : turn.source == "PC" ? .pc : .phone
                    return FadedSearchRecord(id: "chat:\(turn.id)", category: .chat, title: turn.prompt,
                                             detail: String(turn.reply.prefix(160)), source: source,
                                             destination: .chat(query: FadedSearchIndex.boundedQuery(turn.prompt)))
                }
            }
            let chats = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled && showSearch { searchRecords += chats }
        }
    }

    private var dashboardSearchRecords: [FadedSearchRecord] {
        let data = MigratedAppData.shared
        let bots = VillageBot.list(from: data.villageBots)
        var records = bots.map { bot in
            FadedSearchRecord(id: "bot:\(bot.id)", category: .bot, title: bot.name, detail: bot.specialtyTitle,
                              keywords: bot.responsibility ?? "",
                              source: .phone, destination: .bot(id: bot.id))
        }
        records += savedVideos.prefix(80).map { file in
            FadedSearchRecord(id: "saved:\(file.lastPathComponent)", category: .video,
                              title: file.deletingPathExtension().lastPathComponent,
                              detail: "Gemt video", source: .phone, destination: .savedVideo(file))
        }
        records += model.jobs.sorted { $0.created_at > $1.created_at }.prefix(80).map { job in
            let clipName = model.clips.first(where: { $0.id == job.clip_id })?.name ?? job.mood.title
            return FadedSearchRecord(id: "job:\(job.id)", category: .video, title: clipName,
                                     detail: job.status.title, source: .pc, destination: .video(jobID: job.id))
        }
        records += data.codeContext().prefix(100).map { path in
            FadedSearchRecord(id: "file:\(path)", category: .file, title: path, detail: "Valgt i Agent Workspace",
                              source: .pc, destination: .file(path: path))
        }
        records += ConnectionProfile.allCases.map { profile in
            FadedSearchRecord(id: "connection:\(profile.rawValue)", category: .connection, title: profile.route,
                              detail: model.savedAddresses[profile] ?? "PC-forbindelse", source: .pc, destination: .connection)
        }
        records.append(FadedSearchRecord(id: "connection:providers", category: .connection, title: "Forbindelser",
                                        keywords: "Apple Fotos iCloud Filer Google Photos Picker Dropbox Spotify",
                                        destination: .connections))
        if !data.notes.isEmpty {
            records += data.notes.split(whereSeparator: \.isNewline).prefix(80).enumerated().map { line in
                FadedSearchRecord(id: "note:\(line.offset)", category: .note, title: String(line.element),
                                  source: .phone, destination: .note)
            }
        }
        records.append(FadedSearchRecord(id: "note:editor", category: .note, title: "Noter", source: .phone, destination: .note))
        records += SettingsCategory.allCases.map { category in
            FadedSearchRecord(id: "settings:\(category.rawValue)", category: .settings, title: category.rawValue,
                              detail: category.detail, keywords: category.searchKeywords, destination: .settingsCategory(category))
        }
        records.append(FadedSearchRecord(id: "settings:private-studio", category: .settings, title: "Privat Studio",
                                        keywords: "Offline Studio NSFW privat chat", source: .phone,
                                        destination: .privateStudio))
        return records
    }

    func followSearchResult() {
        searchLoad?.cancel()
        searchLoad = nil
        guard let destination = searchDestination else { return }
        searchDestination = nil
        switch destination {
        case .chat(let query):
            searchChatQuery = query
            openChat()
        case .bot(let id): searchBot = SearchBot(id: id)
        case .video(let jobID):
            searchVideoJobID = jobID
            openVideoJobs()
        case .savedVideo(let file):
            if savedVideos.contains(file) { media = Media(url: file, demo: false) }
        case .file(let path):
            searchCodePath = path
            showCodeWorkspace = true
        case .connection: showLogin = true
        case .connections: showConnections = true
        case .note: showNotes = true
        case .settings: showSettings = true
        case .settingsCategory(let category):
            settingsPath = [category]
            showSettings = true
        case .privateStudio: openStudio(.chat)
        }
    }

    @ViewBuilder var loadingStatus: some View {
        if model.busy || model.refreshing || model.mediaLoading {
            LoadingSkeleton(label: model.mediaLoading ? "Henter video…" : "Henter klip og job…")
        }
    }

    func openShortcut() {
        guard !shortcut.isEmpty else { return }
        if shortcut == OpenFadedAIMorningOverview.destination && showOfflineStudio { return }
        let destination = shortcut
        shortcut = ""
        switch destination {
        case "private-chat":
            nsfwSessionUnlocked = false
            openStudio(.chat)
        case "chat": showChat = true
        case "images": openStudio(.images)
        case "connection": showLogin = true
        case "video": openVideoClips()
        case "video-jobs": openVideoJobs()
        case "code": selectSpace(.library)
        case let value where value.hasPrefix("tradera/"):
            let ids = value.split(separator: "/")
            guard !privateStudioPresented, ids.count == 3, let botID = UUID(uuidString: String(ids[1])),
                  let actionID = UUID(uuidString: String(ids[2])), case .success(let bots) = MigratedAppData.shared.loadBots(),
                  let bot = bots.first(where: { $0.id == botID && $0.id != VillageBot.lumiID }) else { return }
            searchBot = SearchBot(id: UUID(), entry: .chat(bot), opensAction: actionID)
        case OpenFadedAIHarperChat.destination: openHarperChat()
        case OpenFadedAIMorningOverview.destination:
            showMorningOverview = true
        case OpenFadedAICamera.destination:
            guard !privateStudioPresented else { return }
            showFadedCamera = true
        case OpenFadedAIVillage.destination:
            guard !privateStudioPresented else { return }
            selectSpace(.village)
            if model.needsPairing { enteredWithoutPC = true }
        case OpenFadedAIVideoBrief.destination:
            guard !privateStudioPresented else { return }
            selectSpace(.brain)
            if model.needsPairing { enteredWithoutPC = true }
            showCreativeStudioShortcut = true
            showMoreDestinations = true
        default: break
        }
    }

    @ViewBuilder func presentSearchBot(_ selection: SearchBot) -> some View {
        switch selection.entry {
        case .profile:
            NavigationStack {
                VillageBotProfile(botID: selection.id, api: studioAPI, studioUnlocked: $nsfwSessionUnlocked,
                                  onPrivateSessionEnded: showPrivateSessionNotice)
                    .toolbar { Button("Luk") { searchBot = nil } }
            }
        case .chat(let bot):
            AgentPhoneChat(bot: bot, api: studioAPI, startsOnPhone: true, opensAction: selection.opensAction)
        case .harperSetup:
            HarperShortcutSetup(api: studioAPI)
        }
    }

    private func openHarperChat() {
        guard !privateStudioPresented else { return }
        guard case .success(let bots) = MigratedAppData.shared.loadBots() else {
            studioToast = StudioToast(text: "Agentlisten kunne ikke læses. Åbn Agenter for at prøve igen.")
            return
        }
        let matches = OpenFadedAIHarperChat.matchingProfiles(in: bots)
        guard matches.count <= 1 else {
            studioToast = StudioToast(text: "Flere agenter hedder Harper. Giv dem forskellige navne under Agenter.")
            return
        }
        if model.needsPairing && !enteredWithoutPC {
            selectSpace(.tasks)
            enteredWithoutPC = true
        }
        if let bot = matches.first {
            if case .chat(let current)? = searchBot?.entry, current.id == bot.id { return }
            searchBot = SearchBot(id: UUID(), entry: .chat(bot))
        } else {
            searchBot = SearchBot(id: UUID(), entry: .harperSetup)
        }
    }
}

@MainActor private struct HarperShortcutSetup: View {
    let api: LiveAPI?
    @Environment(\.dismiss) private var dismiss
    @State private var created: VillageBot?
    @State private var notice: String?

    var body: some View {
        if let created {
            AgentPhoneChat(bot: created, api: api, startsOnPhone: true)
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: FadedSpacing.m) {
                        FadedEmptyState(icon: "person.crop.circle.badge.plus",
                                        title: "Tilføj Harper",
                                        detail: "Harper er en dansk researchagent til spørgsmål, idéer og overblik.",
                                        actionTitle: "Opret Harper og åbn chatten", action: createHarper)
                        if let notice { FadedDetailText(notice) }
                    }
                    .padding(FadedSpacing.edge)
                }
                .background { FadedBackground() }
                .navigationTitle("Tal med Harper")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
            }
        }
    }

    private func createHarper() {
        guard case .success(var bots) = MigratedAppData.shared.loadBots() else {
            notice = "Agentlisten kunne ikke læses."
            return
        }
        let matches = OpenFadedAIHarperChat.matchingProfiles(in: bots)
        guard matches.isEmpty else {
            if matches.count == 1 { created = matches.first }
            else { notice = "Flere agenter hedder Harper. Åbn Agenter for at vælge den rigtige." }
            return
        }
        guard bots.count < 10 else {
            notice = "Du har plads til 10 agenter. Frigør en plads under Agenter for at tilføje Harper."
            return
        }
        let bot = VillageBot(name: "Harper", color: "Grøn",
                             prompt: "Svar på naturligt dansk. Hjælp med research og overblik, og skeln mellem fakta og antagelser.",
                             personality: "Nysgerrig", specialty: "Research")
        bots.append(bot)
        do {
            try MigratedAppData.shared.saveBots(bots)
            VillageHistory.shared.created(bot)
            created = bot
        } catch {
            AppDiagnostics.record(error)
            notice = "Harper kunne ikke gemmes. Prøv igen."
        }
    }
}
