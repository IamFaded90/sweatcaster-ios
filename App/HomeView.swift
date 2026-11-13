// Hovedvisningen ejer appens tilstand, faner og navigation.

import SwiftUI
import UIKit

struct Home: View {
    enum InitialScreen: Hashable { case landing, dashboard, dashboardActivity, videoClips, videoFolders, videoFolderClips }

    let onScreenAppeared: ((InitialScreen) -> Void)?
    let onVideoFoldersAppeared: ((String) -> Bool)?
    let onDashboardAppeared: ((@escaping () -> Void) -> Void)?

    @MainActor init(model: Model? = nil, onVideoFoldersAppeared: ((String) -> Bool)? = nil,
                    onDashboardAppeared: ((@escaping () -> Void) -> Void)? = nil,
                    onScreenAppeared: ((InitialScreen) -> Void)? = nil) {
        _model = State(initialValue: model ?? Model())
        self.onScreenAppeared = onScreenAppeared
        self.onVideoFoldersAppeared = onVideoFoldersAppeared
        self.onDashboardAppeared = onDashboardAppeared
    }

    enum SettingsCategory: String, CaseIterable, Hashable, Sendable {
        case connection = "Forbindelse", models = "AI-modeller", appearance = "Udseende", diagnostics = "Fejlfinding"

        var icon: String {
            switch self {
            case .connection: "network"
            case .models: "cpu"
            case .appearance: "paintpalette"
            case .diagnostics: "stethoscope"
            }
        }

        var detail: String {
            switch self {
            case .connection: "Hjem, Tailscale og PC-status"
            case .models: "Kåre, Core ML og Grok"
            case .appearance: "Tema, tekst og bevægelse"
            case .diagnostics: "Ping, log og lokale data"
            }
        }

        var searchKeywords: String {
            switch self {
            case .connection: "netværk forbindelse IP QR Hjem Tailscale"
            case .models: "model download Core ML Apple Foundation Ollama Grok automatisk"
            case .appearance: "tema mørk lys OLED skrifttype tekststørrelse animation haptik"
            case .diagnostics: "ping fejllog eksport ressourcer notifikationer Live Activity ryd"
            }
        }
    }
    struct StudioToast: Identifiable {
        let id = UUID()
        let text: String
    }
    struct DashboardJob: Codable {
        let id: String
        let mood: Mood
        let status: Stage
        let progress: Double

        init(_ job: Job) {
            id = job.id
            mood = job.mood
            status = job.status
            progress = job.progress
        }
    }
    struct SearchBot: Identifiable { let id: UUID }
    struct DashboardApproval: Identifiable {
        let id: String
        let api: LiveAPI
    }
    enum SettingsFollowup { case login, models, privateChat, bots, code, export }
    enum Space: String, CaseIterable, Identifiable {
        case brain = "Brain", notes = "Notes", gallery = "Gallery", tasks = "Tasks", library = "Library"
        var id: Self { self }
    }
    private enum TabDestination: Equatable {
        case fixed(Space)
        case video(VideoPage)
        case module(selection: String, targetID: String)
    }
    enum VideoPage: String, CaseIterable, Identifiable {
        case clips = "Klip", recipe = "Opskrift", jobs = "Jobs"
        var id: Self { self }
    }

    @Environment(\.scenePhase) var phase
    @State var model: Model
    @State var showLogin = false
    @State var showDashboardActivity = false
    @State var showMoreDestinations = false
    @State var showProjects = false
    @State var showHoldchatFromMore = false
    @State var showBackupFromMore = false
    @AppStorage(AppStorageKeys.appearanceLookPreset) var v0LookPresetID = ""
    @State var pendingMoreDestination: FadedMoreDestination?
    @State var enteredWithoutPC = false
    @State var showSettings = false
    @State var showPCStatus = false
    @State var showingBackupTools = false
    @State var settingsPath: [SettingsCategory] = []
    @State var showConnections = false
    @State var pairAfterConnections = false
    @State var showTeam = false
    @State var teamSidebarCompact = false
    @State var dashboardApproval: DashboardApproval?
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    var teamPinned: Bool { UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular }
    @State var settingsFollowup: SettingsFollowup?
    @State var recentChats: [ChatTurn] = []
    var dashboardChatPreviews: Data { MigratedAppData.shared.dashboardPreviews }
    @State var dashboardRefresh: Task<Void, Never>?
    @State var cachedJobs: [DashboardJob] = []
    @State var cachedJobAddress = ""
    @State var showSearch = false
    @State var searchRecords: [FadedSearchRecord] = []
    @State var searchLoad: Task<Void, Never>?
    @State var searchDestination: FadedSearchDestination?
    @State var searchBot: SearchBot?
    @State var searchChatQuery = ""
    @State var searchVideoJobID: String?
    @State var searchCodePath: String?
    @State var showNotes = false
    @State var queuedChatCount = 0
    @State var chatReviewCount = 0
    @State var pingResult: String?
    @State var pinging = false
    @AppStorage(AppStorageKeys.studioImagesAutoSavePhotos) var saveImagesToPhotos = false
    @AppStorage(AppStorageKeys.appearanceTheme) var theme = FadedTheme.faded
    @AppStorage(AppStorageKeys.appearanceMode) var appearanceMode = FadedAppearance.system
    @AppStorage(AppStorageKeys.chatAutoModelRouter) var autoModelRouter = false
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage(AppStorageKeys.chatVoiceMode) var readChatAloud = false
    @AppStorage(AppStorageKeys.aiShowTools) var showChatTools = true
    @AppStorage(AppStorageKeys.liveActivityEnabled) var liveActivityEnabled = true
    @State var diagnosticsExport: DiagnosticsExport?
    @State var diagnosticsError = false
    @State var media: Media?
    @State var showChat = false
    @State var newChatRequest: UUID?
    @State var preferPhoneInChat = false
    @State private var tabHistory: [TabDestination] = []
    @State private var restoredNavigation = false
    @State var errorDetails = false
    @AccessibilityFocusState var errorFocus: Bool
    @AccessibilityFocusState var jobsFocus: Bool
    @State var showJobs = 0
    @State var space: Space = .brain
    @State var moduleTabs: [ModuleTab] = []
    @State private var moduleAddress: String?
    @State private var moduleTargetID: String?
    @State var selectedModuleTab: String?
    @State var showHelp = false
    @State var showCodeWorkspace = false
    @State var showPhoneModels = false
    @State var showOfflineStudio = false
    @State var showBots = false
    @State var showNewBot = false
    @State var studioPage: OfflineStudio.Page = .chat
    @State var studioImagePrompt = ""
    @State var imagePromptAfterChat: String?
    @State var privateStudioAfterChat = false
    @State var botsAfterChat = false
    @State var studioToast: StudioToast?
    @State var nsfwSessionUnlocked = false
    @State var showSavedVideos = false
    @State var savedVideos: [URL] = []
    @State var pendingLocalDeletion: URL?
    @State var localDeletionError = false
    @State var pcDeletion: (id: String, api: LiveAPI)?
    @State var failedJobDeletion: (id: String, api: LiveAPI)?
    @State var unavailableJobDeletion: (ids: [String], api: LiveAPI)?
    @State var deletingPCVideo = false
    @AppStorage(AppStorageKeys.appTextScale) var textScale = 0.0
    @Environment(\.dynamicTypeSize) var videoTypeSize
    @State var videoPage: VideoPage = .clips
    @State var clipGame = ""
    @State var shortClips = false
    @State var recentJobsFirst = false
    @State var clipDateRange = 0
    @State var selectedGameFolder: String?
    @State var clipRoots: [V2ClipRoots.Root] = []
    @State var folderPages: [String: [Clip]] = [:]
    @State var folderPageNotices: [String: String] = [:]
    @State var folderNotice: String?
    @State var videoFolderServer: String?
    @State var legacyClipCatalog = false
    @State var catalogLoading: UUID?
    @State var pageLoading: UUID?
    @State var videoStartNotice: String?
    @State var handledVideoJobRequest: Int?
    @State var saveVideoNotice: String?
    @State var hiddenJobs = Set<String>()
    @AppStorage(AppStorageKeys.spacesOnboarded) var onboarded = false
    @AppStorage(AppStorageKeys.spacesFont) var font = "Standard"
    @AppStorage(AppStorageKeys.spacesMotion) var motion = false
    @AppStorage(AppStorageKeys.spacesShortcut) var shortcut = ""
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(AppStorageKeys.videoLastMood) var selectedVideoMood: Mood = .hype
    @State var jobFilter = 0
    @AppStorage(AppStorageKeys.qolConfirmVideo) var confirmVideoStart = true
    @AppStorage(AppStorageKeys.qolCompactClips) var compactClipCards = false
    @AppStorage(AppStorageKeys.qolShowDurations) var showClipDurations = true
    @AppStorage(AppStorageKeys.qolJobDetails) var showJobDetails = false
    @AppStorage(AppStorageKeys.qolKeepAwake) var keepScreenAwake = false
    @AppStorage(AppStorageKeys.qolHaptics) var appHaptics = true
    @AppStorage(AppStorageKeys.qolReduceMotion) var calmMotion = false
    @AppStorage(AppStorageKeys.qolRememberSpace) var rememberLastSpace = true
    @AppStorage(AppStorageKeys.qolAutoRefreshTabs) var autoRefreshTabs = true
    @AppStorage(AppStorageKeys.qolConnectionBanner) var showConnectionBanner = true
    @AppStorage(AppStorageKeys.qolLastSpace) private var lastSpace = Space.brain.rawValue
    @State var pendingVideoMood: Mood?

    var palette: FadedPalette {
        FadedPalette(theme: appearanceMode.resolve(theme: theme, system: systemScheme))
    }

    @State var shareResult: Media?

    var privateStudioPresented: Bool { showOfflineStudio && studioPage == .chat }

    var visibleModuleTarget: String? {
        guard !privateStudioPresented, !model.isDemo, moduleAddress == model.address,
              let live = model.api as? LiveAPI, moduleTargetID == live.queueTargetID else { return nil }
        return live.queueTargetID
    }

    private var currentDestination: TabDestination {
        if let selection = selectedModuleTab, let targetID = visibleModuleTarget {
            return .module(selection: selection, targetID: targetID)
        }
        return space == .gallery ? .video(videoPage) : .fixed(space)
    }

    var homeContent: some View {
        VStack(spacing: 0) {
            homeTabs
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if currentDestination != .fixed(.notes) {
                spacesBar
            }
        }
        .onChange(of: showJobs) {
            navigate(to: .video(.jobs))
        }
        .task(id: "\(model.isDemo):\(model.address):\((model.api as? LiveAPI)?.queueTargetID ?? ""):\(model.connected):\(phase == .active && !privateStudioPresented)") {
            if phase == .active && !privateStudioPresented { await loadModuleTabs() }
        }
        .onChange(of: space) { _, value in
            if value == .brain { refreshDashboard() }
            if rememberLastSpace { lastSpace = value.rawValue }
            if autoRefreshTabs && !model.isDemo && !privateStudioPresented { Task { await model.refresh() } }
        }
        .onChange(of: keepScreenAwake) { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onAppear {
            if !restoredNavigation {
                restoredNavigation = true
                if tabHistory.isEmpty, rememberLastSpace, let saved = Space(rawValue: lastSpace) { space = saved }
            }
            refreshDashboard()
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var selectedHomeTab: String {
        if case .module(let selection, _) = currentDestination { return selection }
        return space.rawValue
    }

    private var homeTabs: some View {
        TabView(selection: Binding(get: { selectedHomeTab }, set: { value in
            guard !privateStudioPresented else { return }
            if let fixed = Space(rawValue: value) { selectTab(fixed) }
            else { selectModule(value) }
        })) {
            DeferredHomeTab(isSelected: selectedHomeTab == Space.brain.rawValue) { AnyView(homeTab) }
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Hjem", systemImage: "house.fill") }.tag(Space.brain.rawValue)
            DeferredHomeTab(isSelected: selectedHomeTab == Space.notes.rawValue) { AnyView(chatTab) }
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Chat", systemImage: "bubble.left.fill") }.tag(Space.notes.rawValue)
            DeferredHomeTab(isSelected: selectedHomeTab == Space.gallery.rawValue, keepAlive: false) {
                AnyView(videoStudio.onAppear { if videoPage == .clips { onScreenAppeared?(.videoClips) } })
            }
            .toolbarVisibility(.hidden, for: .tabBar)
            .tabItem { Label("Video", systemImage: "film.fill") }.tag(Space.gallery.rawValue)
            DeferredHomeTab(isSelected: selectedHomeTab == Space.tasks.rawValue) {
                AnyView(AgentHub(api: studioAPI, isVisible: selectedHomeTab == Space.tasks.rawValue,
                                 studioUnlocked: $nsfwSessionUnlocked,
                                 onPrivateSessionEnded: showPrivateSessionNotice, onBack: goBack,
                                 experimentalWork: experimentalVillageWork, onExperimentalAction: openExperimentalVillageWork))
            }
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Landsby", systemImage: "house.lodge.fill") }.tag(Space.tasks.rawValue)
            DeferredHomeTab(isSelected: selectedHomeTab == Space.library.rawValue) {
                AnyView(CodeWorkspaceView(api: privateStudioPresented ? nil : model.api as? LiveAPI, onBack: goBack))
            }
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Code Bot", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(Space.library.rawValue)
            if visibleModuleTarget != nil, let api = model.api as? LiveAPI {
                ForEach(moduleTabs) { tab in
                    DeferredHomeTab(isSelected: selectedHomeTab == "module:" + tab.id) {
                        AnyView(ModuleTabView(tab: tab, api: api, onBack: goBack))
                    }
                        .id(api.queueTargetID + ":" + tab.id)
                        .toolbarVisibility(.hidden, for: .tabBar)
                        .tabItem { Label(tab.title, systemImage: tab.kind == "cards" ? "rectangle.on.rectangle" : "info.circle") }
                        .tag("module:" + tab.id)
                }
            }
        }
    }

    private func loadModuleTabs() async {
        guard !privateStudioPresented else { return }
        let address = model.address
        let targetID = (model.api as? LiveAPI)?.queueTargetID
        if moduleAddress != address || moduleTargetID != targetID {
            moduleTabs = []
            selectedModuleTab = nil
        }
        guard !model.isDemo, let api = model.api as? LiveAPI else {
            moduleTabs = []
            selectedModuleTab = nil
            return
        }
        guard model.connected, !Task.isCancelled else { return }
        guard let manifest = try? await api.moduleManifest(), manifest.version == 1,
              !Task.isCancelled, model.connected, !model.isDemo, !privateStudioPresented, model.address == address,
              (model.api as? LiveAPI)?.queueTargetID == api.queueTargetID else { return }
        var seen = Set<String>()
        moduleAddress = address
        moduleTargetID = api.queueTargetID
        moduleTabs = Array(manifest.tabs.filter { $0.supported && seen.insert($0.id).inserted }.prefix(8))
        if let selectedModuleTab, !moduleTabs.contains(where: { "module:" + $0.id == selectedModuleTab }) {
            self.selectedModuleTab = nil
        }
    }

    private func tabPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.section, content: content)
                .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .refreshable { await model.refresh(); await loadModuleTabs() }
    }

    private var homeTab: some View {
        NavigationStack {
            tabPage("Hjem") {
                header
            }
            .onAppear {
                guard selectedHomeTab == Space.brain.rawValue else { return }
                onDashboardAppeared?(openDashboardActivity)
                onScreenAppeared?(.dashboard)
            }
            .navigationDestination(isPresented: $showDashboardActivity) {
                dashboardActivityScreen.onAppear { onScreenAppeared?(.dashboardActivity) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    dashboardConnection
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, FadedSpacing.edge)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: FadedSpacing.xs) {
                        if !teamPinned {
                            Button("Holdet", systemImage: "person.2", action: openTeam)
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                        dashboardWordmark
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Søg i FadedAI", systemImage: "magnifyingglass", action: openSearch)
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .keyboardShortcut("k", modifiers: .command)
                    Menu {
                        Button("Noter", systemImage: "note.text") { showNotes = true }
                        if !teamPinned {
                            Button("Holdet", systemImage: "person.2", action: openTeam)
                        }
                        Button("Indstillinger", systemImage: "gearshape") { showSettings = true }
                        Button("PC-status", systemImage: "stethoscope") { showPCStatus = true }
                        Button("Forbindelser", systemImage: "link") { showConnections = true }
                        Button("Privat Studio", systemImage: "lock.shield") { openStudio(.chat) }
                        Button("Lokale modeller", systemImage: "iphone") { showPhoneModels = true }
                        Button("Code Bot", systemImage: "terminal") { selectSpace(.library) }
                        Button("Skift forbindelse", systemImage: "network") { showLogin = true }.disabled(switchDisabled)
                        Button("Hvad kan jeg?", systemImage: "questionmark.circle") { showHelp = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 40, height: 40)
                            .fadedGlassSurface(radius: FadedRadius.small)
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Flere muligheder")
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    private var dashboardWordmark: some View {
        HStack(spacing: FadedSpacing.s) {
            Text("f.").font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(FadedColors.deep).padding(FadedSpacing.xs)
                .frame(minWidth: 28, minHeight: 28)
                .background(FadedBrand.gradient, in: RoundedRectangle(cornerRadius: FadedRadius.small))
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                Text("faded").foregroundStyle(palette.text)
                Text("ai").foregroundStyle(palette.secondary)
            }
                .font(FadedTypography.title)
                .accessibilityLabel("FadedAI").accessibilityAddTraits(.isHeader)
        }
    }

    private var chatTab: some View {
        chatContent(embedded: true)
    }

    func selectSpace(_ destination: Space) {
        navigate(to: destination == .gallery ? .video(videoPage) : .fixed(destination))
    }

    func openVideoClips() {
        navigate(to: .video(.clips))
    }

    func openVideoJobs() {
        navigate(to: .video(.jobs))
        showJobs += 1
    }

    func selectTab(_ destination: Space) {
        if destination == .gallery, space != .gallery || selectedModuleTab != nil { openVideoClips() }
        else { selectSpace(destination) }
    }

    func selectModule(_ selection: String) {
        guard let targetID = visibleModuleTarget else { return }
        let destination = TabDestination.module(selection: selection, targetID: targetID)
        if canShow(destination) { navigate(to: destination) }
    }

    private func canShow(_ destination: TabDestination) -> Bool {
        guard case .module(let selection, let targetID) = destination else { return true }
        return targetID == visibleModuleTarget && moduleTabs.contains { "module:" + $0.id == selection }
    }

    private func navigate(to destination: TabDestination) {
        let origin = currentDestination
        guard origin != destination else { return }
        if case .video = origin, case .video = destination {
            apply(destination)
            return
        }
        if tabHistory.count == 32 { tabHistory.removeFirst() }
        tabHistory.append(origin)
        apply(destination)
    }

    func goBackFromChat() { goBack() }

    func goBack() {
        let current = currentDestination
        while let previous = tabHistory.popLast() {
            if previous != current, canShow(previous) {
                apply(previous)
                return
            }
        }
        apply(.fixed(.brain))
    }

    private func apply(_ destination: TabDestination) {
        switch destination {
        case .fixed(let target):
            selectedModuleTab = nil
            if target == .brain { showSettings = false }
            space = target
        case .video(let page):
            selectedModuleTab = nil
            videoPage = page
            space = .gallery
        case .module(let selection, _):
            selectedModuleTab = selection
        }
    }

    var homeBackground: some View {
        FadedBackground().overlay {
            if motion && !reduceMotion && !calmMotion && phase == .active && palette.theme == .faded && space == .brain {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { clock in
                    let strength = 0.04 + 0.02 * sin(clock.date.timeIntervalSinceReferenceDate / 2)
                    LinearGradient(colors: [palette.cyan.opacity(strength), .clear], startPoint: .topLeading, endPoint: .center)
                }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        homeSearchPresentation
            .sheet(item: $media) { Preview(media: $0) }
            .sheet(isPresented: $showChat, onDismiss: refreshAfterChat) { chatSheet }
            .environment(\.fadedPalette, palette)
            .environment(\.fadedLookPreset, v0LookPreset)
            .preferredColorScheme(appearanceMode.preferredScheme(for: theme))
            .tint(palette.isDark ? palette.lime : palette.text)
            .foregroundStyle(palette.text)
    }

}
