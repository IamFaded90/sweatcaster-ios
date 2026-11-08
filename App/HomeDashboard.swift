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
        if model.isDemo {
            FadedCard(accent: palette.purple) { Text("Demo · Kun testdata").font(FadedTypography.action) }
        }
        dashboardActiveJob
        dashboardConnectionNotice
        dashboardQueueNotice
        FadedSecondaryButton("Søg i FadedAI", icon: "magnifyingglass", action: openSearch)
            .keyboardShortcut("k", modifiers: .command)
        FadedSectionHeader("Hurtige handlinger")
        quickActions
        FadedSecondaryButton("Privat Studio", icon: "lock.shield") { openStudio(.chat) }
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
        if model.connected, let error = model.errorPresentation {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.title).font(.headline).accessibilityFocused($errorFocus)
                if let detail = error.detail {
                    DisclosureGroup("Tekniske detaljer", isExpanded: $errorDetails) {
                        Text(detail).textSelection(.enabled)
                    }
                }
                action(error.fixAction.title) { fixDashboardError(error.fixAction) }.disabled(switchDisabled)
                FadedSecondaryButton("Kopiér fejl", icon: "doc.on.doc") { UIPasteboard.general.string = error.title }
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
                        FadedSecondaryButton("Brug Telefon", icon: "iphone") { showChat = true }
                        FadedSecondaryButton(error.fixAction.title, icon: "arrow.clockwise") { fixDashboardError(error.fixAction) }
                        FadedSecondaryButton("Kopiér fejl", icon: "doc.on.doc") { UIPasteboard.general.string = error.title }
                    }
                }
            }
        }
    }

    private func fixDashboardError(_ action: AppErrorPresentation.FixAction) {
        switch action {
        case .connect: showLogin = true
        case .reviseInput: selectSpace(.gallery)
        case .review:
            selectSpace(.gallery)
            showJobs += 1
        case .usePhone: showChat = true
        case .retry: Task { await model.refresh() }
        }
    }

    @ViewBuilder private var dashboardQueueNotice: some View {
        let videos = model.videoOutbox.count
        if !model.isDemo && queuedChatCount + chatReviewCount + videos > 0 {
            FadedCard(accent: chatReviewCount > 0 ? palette.coral : palette.cyan) {
                VStack(alignment: .leading, spacing: 8) {
                    FadedSectionLabel("I kø")
                    if queuedChatCount > 0 {
                        FadedSecondaryButton("Chat i kø · \(queuedChatCount)", icon: "bubble.left") {
                            selectSpace(.notes); showChat = true
                        }
                    }
                    if chatReviewCount > 0 {
                        FadedSecondaryButton("Tjek afsendelse · \(chatReviewCount)", icon: "exclamationmark.circle") {
                            selectSpace(.notes); showChat = true
                        }
                    }
                    if videos > 0 {
                        FadedSecondaryButton("Videokø · \(videos)", icon: "film") { selectSpace(.gallery); showJobs += 1 }
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

    @ViewBuilder private var dashboardActiveJob: some View {
        let job = (model.connected || model.isDemo)
            ? model.jobs.first(where: { $0.status.active }).map(DashboardJob.init)
            : (cachedJobAddress == model.address ? cachedJobs.first : nil)
        if let job {
            FadedSectionLabel("I gang")
            FadedCard(accent: palette.cyan) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(job.mood.title) · \(job.status.title)").font(FadedTypography.title)
                    if !model.connected && !model.isDemo { Text("Sidst set på PC’en").font(.caption).foregroundStyle(palette.secondary) }
                    FadedProgress(value: job.progress)
                    FadedSecondaryButton("Følg video", icon: "film") {
                        selectSpace(.gallery)
                        searchVideoJobID = job.id
                        showJobs += 1
                    }
                }
                .padding(8)
                .background(LinearGradient(colors: [palette.lime.opacity(0.13), palette.cyan.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: FadedRadius.small))
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
        quickAction("Ny chat", detail: "Dit AI-hold", icon: "message", accent: palette.green) { selectSpace(.notes); showChat = true }
        quickAction("Ny video", detail: "Video Studio", icon: "video", accent: palette.cyan) { showClips += 1 }
        quickAction("Ny bot", detail: "Byg din makker", icon: "person.crop.circle.badge.plus", accent: palette.purple) { showNewBot = true }
    }

    private func quickAction(_ title: String, detail: String, icon: String, accent: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FadedCard {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon).foregroundStyle(FadedColors.deep).frame(width: 32, height: 32)
                        .background(accent, in: Circle()).accessibilityHidden(true)
                    Text(title).font(FadedTypography.action).fixedSize(horizontal: true, vertical: false)
                    Text(detail).font(.caption).foregroundStyle(palette.secondary)
                }
            }
        }.buttonStyle(.plain)
    }

    private var dashboardActivity: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.section) {
                FadedSectionHeader("Fortsæt hvor du slap")
                if let turn = recentChats.first {
                    Button {
                        searchChatQuery = turn.prompt
                        selectSpace(.notes)
                        showChat = true
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
                NavigationLink { dashboardActivityPage } label: {
                    Label("Se seneste aktivitet", systemImage: "clock")
                }.buttonStyle(FadedButtonStyle(kind: .secondary))
            }
        }
    }

    private var dashboardActivityPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
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
            let previews = await Task.detached(priority: .utility) {
                ChatArchive.turns().prefix(3).map { turn in
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
        reloadSavedVideos()
        searchRecords = dashboardSearchRecords
        showSearch = true
        Task {
            let chats = await Task.detached(priority: .userInitiated) {
                ChatArchive.turns().prefix(1_500).map { turn in
                    let source: FadedSearchSource = turn.source == GrokAPI.sourceLabel ? .cloud : turn.source == "PC" ? .pc : .phone
                    return FadedSearchRecord(id: "chat:\(turn.id)", category: .chat, title: turn.prompt,
                                             detail: String(turn.reply.prefix(160)), source: source,
                                             destination: .chat(query: String(turn.prompt.prefix(120))))
                }
            }.value
            if showSearch { searchRecords += chats }
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
        records += model.jobs.prefix(80).map { job in
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
                              detail: category.detail, destination: .settings)
        }
        records.append(FadedSearchRecord(id: "settings:private-studio", category: .settings, title: "Privat Studio",
                                        keywords: "Offline Studio NSFW privat chat", source: .phone,
                                        destination: .privateStudio))
        return records
    }

    func followSearchResult() {
        guard let destination = searchDestination else { return }
        searchDestination = nil
        switch destination {
        case .chat(let query):
            searchChatQuery = query
            selectSpace(.notes)
            showChat = true
        case .bot(let id): searchBot = SearchBot(id: id)
        case .video(let jobID):
            searchVideoJobID = jobID
            selectSpace(.gallery)
            showJobs += 1
        case .savedVideo(let file):
            if savedVideos.contains(file) { media = Media(url: file, demo: false) }
        case .file(let path):
            searchCodePath = path
            showCodeWorkspace = true
        case .connection: showLogin = true
        case .connections: showConnections = true
        case .note: showNotes = true
        case .settings: showSettings = true
        case .privateStudio: openStudio(.chat)
        }
    }

    @ViewBuilder var loadingStatus: some View {
        if model.busy || model.refreshing || model.mediaLoading {
            LoadingSkeleton(label: model.mediaLoading ? "Henter video…" : "Henter klip og job…")
        }
    }
}
