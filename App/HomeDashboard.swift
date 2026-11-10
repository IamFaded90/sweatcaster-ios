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
        if let value = try? await asset.load(.duration), value.seconds.isFinite, !Task.isCancelled {
            let seconds = max(0, Int(value.seconds.rounded()))
            duration = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }
}

extension Home {
    @ViewBuilder var header: some View {
        FadedPrimaryButton("Ny chat", icon: "square.and.pencil", action: openNewChat)
        quickActions
        if model.isDemo {
            FadedBadge("Demo · Kun testdata", tone: .info)
        }
        dashboardStatus
        VillageLiveRow(work: experimentalVillageWork) {
            UserDefaults.standard.set(false, forKey: AppStorageKeys.villageShowOffice)
            selectSpace(.tasks)
        }
        dashboardActivity
        if !onboarded {
            FadedCard {
                VStack(alignment: .leading, spacing: 8) {
                    heading("Kom godt i gang")
                    Label("1. Forbind til PC", systemImage: "desktopcomputer")
                    Label("2. Vælg klip", systemImage: "film")
                    Label("3. Chat med din AI", systemImage: "bubble.left")
                    FadedSecondaryButton("Klar") { onboarded = true }
                }
            }
        }
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
        } else if let job = dashboardApprovalJob {
            dashboardApprovalRow(job)
        } else if let job = dashboardActiveVideo {
            dashboardActiveJob(job)
        } else if queuedChatCount > 0 {
            dashboardStatusRow("Chat i kø", detail: "Venter på PC’en · \(queuedChatCount)",
                               icon: "bubble.left", accent: palette.cyan, actionTitle: "Se udbakken", action: openChat)
        } else if !model.videoOutbox.isEmpty {
            dashboardStatusRow("Video i kø", detail: "Venter på PC’en · \(model.videoOutbox.count)",
                               icon: "film", accent: palette.cyan, actionTitle: "Se videokø", action: openVideoJobs)
        } else {
            dashboardConnectedError
            dashboardConnectionNotice
            if model.connected { loadingStatus }
        }
    }

    @ViewBuilder private var dashboardConnectedError: some View {
        if model.connected, let error = model.errorPresentation {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.title).font(.headline).accessibilityFocused($errorFocus)
                if let detail = error.detail {
                    DisclosureGroup("Tekniske detaljer", isExpanded: $errorDetails) {
                        Text(detail).textSelection(.enabled)
                    }
                }
                action(error.fixAction.title) { fixDashboardError(error.fixAction) }.disabled(switchDisabled)
                FadedCopyErrorButton(title: error.title)
            }
        }
    }

    @ViewBuilder private var dashboardConnectionNotice: some View {
        if !model.isDemo, !model.connected {
            FadedCard(accent: model.refreshing ? palette.cyan : palette.coral) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.refreshing ? "Opdaterer forbindelsen…" : (model.errorTitle ?? "Tjekker PC’en…"))
                        .font(FadedTypography.action)
                    if !model.refreshing, let error = model.errorPresentation {
                        FadedSecondaryButton("Brug Telefon", icon: "iphone", action: openPhoneChat)
                        FadedSecondaryButton(error.fixAction.title, icon: "arrow.clockwise") { fixDashboardError(error.fixAction) }
                        FadedCopyErrorButton(title: error.title)
                    }
                }
            }
        }
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

    @ViewBuilder private var dashboardQueueNotice: some View {
        let videos = model.videoOutbox.count
        if !model.isDemo && (model.requiresVideoReview || queuedChatCount + chatReviewCount + videos > 0) {
            FadedCard(accent: dashboardQueueNeedsAttention ? palette.coral : palette.cyan) {
                VStack(alignment: .leading, spacing: 8) {
                    FadedSectionLabel("Udbakke")
                    if queuedChatCount > 0 {
                        FadedSecondaryButton("Chat i kø · \(queuedChatCount)", icon: "bubble.left", action: openChat)
                    }
                    if chatReviewCount > 0 {
                        FadedSecondaryButton("Tjek afsendelse · \(chatReviewCount)", icon: "exclamationmark.circle", action: openChat)
                    }
                    if videos > 0 {
                        FadedSecondaryButton("Videokø · \(videos)", icon: "film", action: openVideoJobs)
                    }
                    if model.requiresVideoReview {
                        FadedSecondaryButton("Tjek dit videojob", icon: "exclamationmark.circle", action: openVideoJobs)
                    }
                }
            }
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

    private func dashboardActiveJob(_ job: DashboardJob) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("I gang")
                FadedDetailText(job.mood.title)
                VideoJobStatusLine(status: job.status, progress: job.progress,
                                   isCurrent: model.connected || model.isDemo, accent: palette.cyan)
                FadedSecondaryButton("Følg video", icon: "film") {
                    searchVideoJobID = job.id
                    openVideoJobs()
                }
            }
        }
    }

    private var dashboardApprovalJob: CodeBatchList.Job? {
        guard studioAPI != nil else { return nil }
        return model.observedCodeJobs.first { $0.status == "review" }
    }

    @ViewBuilder private func dashboardApprovalRow(_ job: CodeBatchList.Job) -> some View {
        if let api = studioAPI {
            dashboardStatusRow("Kodeforslag klar", detail: job.goal, icon: "checkmark.circle",
                               accent: palette.lime, actionTitle: "Se forslag") {
                dashboardApproval = DashboardApproval(id: job.id, api: api)
            }
        }
    }

    private func dashboardStatusRow(_ title: String, detail: String, icon: String, accent: Color,
                                    actionTitle: String, action: @escaping () -> Void) -> some View {
        FadedCard(accent: accent) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label(title, systemImage: icon).font(FadedTypography.action)
                FadedDetailText(detail)
                FadedSecondaryButton(actionTitle, action: action)
            }
        }
    }

    private var quickActions: some View {
        Group {
            if videoTypeSize.isAccessibilitySize {
                VStack(spacing: FadedSpacing.section) { quickActionCards }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) { quickActionCards }
                    VStack(spacing: 8) { quickActionCards }
                }
            }
        }
    }

    @ViewBuilder private var quickActionCards: some View {
        quickAction("Video Studio", icon: "video", accent: palette.cyan, action: openVideoClips)
        quickAction("Ny bot", icon: "person.crop.circle.badge.plus", accent: palette.purple) { showNewBot = true }
        quickAction("Privat Studio", icon: "lock.shield", accent: palette.purple) { openStudio(.chat) }
    }

    private func quickAction(_ title: String, icon: String, accent: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FadedCard(size: .compact) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon).foregroundStyle(FadedColors.deep).frame(width: 32, height: 32)
                        .background(accent, in: Circle()).accessibilityHidden(true)
                    Text(title).font(FadedTypography.action)
                        .fixedSize(horizontal: !videoTypeSize.isAccessibilitySize, vertical: true)
                }
            }
        }.buttonStyle(.plain)
    }

    private var dashboardQueueNeedsAttention: Bool {
        chatReviewCount > 0 || model.requiresVideoReview || model.videoOutbox.contains {
            $0.state == .rejected || ($0.state == .attempted && !model.checkingVideoOutbox)
        }
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
        return NavigationLink { dashboardActivityPage } label: {
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

    @ViewBuilder private var dashboardContinueActivity: some View {
        if !recentChats.isEmpty || !savedVideos.isEmpty {
            FadedCard {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    FadedSectionHeader("Fortsæt hvor du slap")
                    if let turn = recentChats.first {
                        Button {
                            searchChatQuery = FadedSearchIndex.boundedQuery(turn.prompt)
                            openChat()
                        } label: {
                            Label(turn.prompt, systemImage: "bubble.left")
                                .lineLimit(2).frame(minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityHint("Find beskeden i chatarkivet")
                    }
                    if let file = savedVideos.first {
                        FadedSecondaryButton("Afspil seneste gemte video", icon: "play.circle") {
                            media = Media(url: file, demo: false)
                        }
                    }
                }
            }
        }
    }

    private var dashboardActivityPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                dashboardConnectedError
                dashboardConnectionNotice
                dashboardQueueNotice
                if let approval = dashboardApprovalJob { dashboardApprovalRow(approval) }
                if let job = dashboardActiveVideo { dashboardActiveJob(job) }
                dashboardContinueActivity
                dashboardRecentChats
                dashboardVideos
            }.padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Seneste aktivitet")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { refreshDashboard() }
    }

    @ViewBuilder private var dashboardRecentChats: some View {
        if !recentChats.isEmpty {
            FadedSectionLabel("Sidste chats")
            ForEach(recentChats) { turn in
                FadedCard(accent: dashboardSourceColor(turn.source)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.prompt).font(FadedTypography.body).lineLimit(2)
                        if let date = turn.createdAt { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }.foregroundStyle(palette.text)
                }
            }
        } else {
            FadedDetailText("Samtaler dukker op her, når du har skrevet i chatten.")
        }
    }

    private func dashboardSourceColor(_ source: String?) -> Color {
        if source == GrokAPI.sourceLabel { return palette.purple }
        if source == "PC" { return palette.cyan }
        return palette.green
    }

    private var dashboardVideos: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionHeader("Gemte videoer")
            if savedVideos.isEmpty {
                FadedDetailText("Gem en færdig video fra Video Studio for at se den her.")
            }
            ForEach(savedVideos.prefix(3), id: \.self) { file in
                Button { media = Media(url: file, demo: false) } label: { DashboardVideoCard(file: file) }
                    .buttonStyle(.plain)
            }
            FadedSecondaryButton("Åbn videobibliotek", icon: "film.stack") { reloadSavedVideos(); showSavedVideos = true }
        }
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
        let bots = (try? JSONDecoder().decode([VillageBot].self, from: data.villageBots)) ?? []
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
}
