// Hovedvisningen ejer appens tilstand, faner og navigation.

import SwiftUI
import UIKit

struct Home: View {
    enum SettingsCategory: String, CaseIterable {
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
    enum SettingsFollowup { case login, models, privateChat, bots, code, export }
    enum Space: String, CaseIterable, Identifiable {
        case brain = "Brain", notes = "Notes", gallery = "Gallery", tasks = "Tasks", library = "Library"
        var id: Self { self }
    }
    enum VideoPage: String, CaseIterable, Identifiable {
        case clips = "Klip", recipe = "Opskrift", jobs = "Jobs"
        var id: Self { self }
    }

    @Environment(\.scenePhase) var phase
    @State var model = Model()
    @State var showLogin = false
    @State var showSettings = false
    @State var showConnections = false
    @State var showTeam = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State var settingsFollowup: SettingsFollowup?
    @State var recentChats: [ChatTurn] = []
    var dashboardChatPreviews: Data { MigratedAppData.shared.dashboardPreviews }
    @State var dashboardRefresh: Task<Void, Never>?
    @State var cachedJobs: [DashboardJob] = []
    @State var cachedJobAddress = ""
    @State var showSearch = false
    @State var searchRecords: [FadedSearchRecord] = []
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
    @State var preferPhoneInChat = false
    @State var errorDetails = false
    @AccessibilityFocusState var errorFocus: Bool
    @AccessibilityFocusState var jobsFocus: Bool
    @State var showJobs = 0
    @State var space: Space = .brain
    @State private var moduleTabs: [ModuleTab] = []
    @State private var moduleAddress: String?
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
    @State var studioToast: StudioToast?
    @State var nsfwSessionUnlocked = false
    @State var showSavedVideos = false
    @State var savedVideos: [URL] = []
    @State var pendingLocalDeletion: URL?
    @State var localDeletionError = false
    @State var pcDeletion: (id: String, api: LiveAPI)?
    @State var failedJobDeletion: (id: String, api: LiveAPI)?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    @State var showClips = 0
    @State var shareResult: Media?

    var privateStudioPresented: Bool { showOfflineStudio && studioPage == .chat }

    var homeContent: some View {
        TabView(selection: Binding(get: { selectedModuleTab ?? space.rawValue }, set: { value in
            if let fixed = Space(rawValue: value) {
                selectedModuleTab = nil
                space = fixed
            } else {
                selectedModuleTab = value
            }
        })) {
            homeTab
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Hjem", systemImage: "house.fill") }.tag(Space.brain.rawValue)
            chatTab
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Chat", systemImage: "bubble.left.fill") }.tag(Space.notes.rawValue)
            videoStudio
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Video", systemImage: "film.fill") }.tag(Space.gallery.rawValue)
            AgentHub(api: studioAPI, isVisible: space == .tasks && selectedModuleTab == nil,
                     studioUnlocked: $nsfwSessionUnlocked,
                     onPrivateSessionEnded: showPrivateSessionNotice, onBack: { selectSpace(.brain) })
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Landsby", systemImage: "house.lodge.fill") }.tag(Space.tasks.rawValue)
            CodeWorkspaceView(api: privateStudioPresented ? nil : model.api as? LiveAPI, onBack: { selectSpace(.brain) })
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Code Bot", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(Space.library.rawValue)
            if !privateStudioPresented, moduleAddress == model.address, let api = model.api as? LiveAPI {
                ForEach(moduleTabs) { tab in
                    ModuleTabView(tab: tab, api: api, onBack: { selectSpace(.brain) })
                        .id(model.address + ":" + tab.id)
                        .toolbarVisibility(.hidden, for: .tabBar)
                        .tabItem { Label(tab.title, systemImage: tab.kind == "cards" ? "rectangle.on.rectangle" : "info.circle") }
                        .tag("module:" + tab.id)
                }
            }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { spacesBar }
        .onChange(of: showJobs) {
            videoPage = .jobs
            selectSpace(.gallery)
        }
        .onChange(of: showClips) {
            videoPage = .clips
            selectSpace(.gallery)
        }
        .task(id: "\(model.isDemo):\(model.address):\(phase == .active && !privateStudioPresented)") {
            if phase == .active && !privateStudioPresented { await loadModuleTabs() }
        }
        .onChange(of: space) { _, value in
            selectedModuleTab = nil
            if value == .brain { refreshDashboard() }
            if rememberLastSpace { lastSpace = value.rawValue }
            if autoRefreshTabs && !model.isDemo && !privateStudioPresented { Task { await model.refresh() } }
        }
        .onChange(of: keepScreenAwake) { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onAppear {
            if rememberLastSpace, let saved = Space(rawValue: lastSpace) { space = saved }
            refreshDashboard()
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func loadModuleTabs() async {
        let address = model.address
        if moduleAddress != address {
            moduleTabs = []
            selectedModuleTab = nil
        }
        guard !model.isDemo, let api = model.api as? LiveAPI else {
            moduleTabs = []
            selectedModuleTab = nil
            return
        }
        guard let manifest = try? await api.moduleManifest(), manifest.version == 1,
              !Task.isCancelled, !model.isDemo, model.address == address else { return }
        var seen = Set<String>()
        moduleAddress = address
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
                FadedSignature()
                header
                loadingStatus
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if horizontalSizeClass == .regular {
                        Text("FadedAI").font(FadedTypography.title).tracking(-0.5)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        HStack(spacing: 4) {
                            Button("Holdet", systemImage: "person.2") { showTeam = true }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            Text("FadedAI").font(FadedTypography.title).tracking(-0.5)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                ToolbarItem(placement: .principal) { dashboardConnection }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Søg", systemImage: "magnifyingglass", action: openSearch)
                        Button("Noter", systemImage: "note.text") { showNotes = true }
                        if horizontalSizeClass != .regular {
                            Button("Holdet", systemImage: "person.2") { showTeam = true }
                        }
                        Button("Indstillinger", systemImage: "gearshape") { showSettings = true }
                        Button("Forbindelser", systemImage: "link") { showConnections = true }
                        Button("Privat Studio", systemImage: "lock.shield") { openStudio(.chat) }
                        Button("Lokale modeller", systemImage: "iphone") { showPhoneModels = true }
                        Button("Code Bot", systemImage: "terminal") { selectSpace(.library) }
                        Button("Skift forbindelse", systemImage: "network") { showLogin = true }.disabled(switchDisabled)
                        Button("Hvad kan jeg?", systemImage: "questionmark.circle") { showHelp = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 40, height: 40)
                            .background(palette.card, in: RoundedRectangle(cornerRadius: FadedRadius.small))
                            .overlay { RoundedRectangle(cornerRadius: FadedRadius.small).strokeBorder(palette.border) }
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Flere muligheder")
                }
            }
            .toolbarBackground(palette.background, for: .navigationBar)
        }
    }

    private var chatTab: some View {
        NavigationStack {
            List {
                chatEntry("AI-chat", detail: "Vælg telefon, PC eller Grok.", icon: "bubble.left") { showChat = true }
                chatEntry("Privat Studio", detail: "Privat chat (NSFW) · Kun på telefonen", icon: "lock.shield") { openStudio(.chat) }
                chatEntry("Billeder", detail: "Generér billeder, eller åbn dit galleri.", icon: "photo") { openStudio(.images) }
                chatEntry("Mine bots", detail: "Åbn en bot, og prøv dens personlighed og stemme.", icon: "person.2") { showBots = true }
            }
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { FadedSignature().padding(.horizontal, FadedSpacing.edge) }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left") { selectSpace(.brain) }
                }
            }
        }
    }

    private func chatEntry(_ title: String, detail: String, icon: String, work: @escaping () -> Void) -> some View {
        Button(action: work) {
            FadedCard {
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 24).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(FadedTypography.action)
                        Text(detail).font(.subheadline).foregroundStyle(palette.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(palette.secondary).accessibilityHidden(true)
                }
            }.frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    func selectSpace(_ destination: Space) {
        selectedModuleTab = nil
        if destination == .brain { showSettings = false }
        space = destination
    }

    private var spacesBar: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons
            ScrollView(.horizontal) { tabButtons }.scrollIndicators(.hidden)
        }
        .padding(6)
        .background(palette.card, in: RoundedRectangle(cornerRadius: FadedRadius.media))
        .overlay { RoundedRectangle(cornerRadius: FadedRadius.media).strokeBorder(palette.border).allowsHitTesting(false) }
        .frame(maxWidth: 570)
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private var tabButtons: some View {
        HStack(spacing: 2) {
            ForEach(Space.allCases) { item in
                let selected = selectedModuleTab == nil && space == item
                Button {
                    if reduceMotion { selectSpace(item) }
                    else { withAnimation(.spring(response: calmMotion ? 0.70 : 0.35, dampingFraction: 0.8)) { selectSpace(item) } }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: spaceIcon(item)).font(.body)
                        Text(spaceTitle(item)).font(.caption2.bold()).fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 4)
                    .foregroundStyle(selected ? FadedColors.deep : palette.secondary)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
                    .background(selected ? palette.lime : Color.clear, in: RoundedRectangle(cornerRadius: FadedRadius.small))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Åbn " + spaceTitle(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if moduleAddress == model.address, !moduleTabs.isEmpty { moduleTabMenu }
        }
    }

    private var moduleTabMenu: some View {
        Menu {
            ForEach(moduleTabs) { tab in
                Button(tab.title) { selectedModuleTab = "module:" + tab.id }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis").font(.body)
                Text("Mere").font(.caption2.bold())
            }
            .frame(minWidth: 44, minHeight: 48)
            .foregroundStyle(selectedModuleTab != nil ? FadedColors.deep : palette.secondary)
            .background(selectedModuleTab != nil ? palette.lime : Color.clear, in: RoundedRectangle(cornerRadius: FadedRadius.small))
        }
        .accessibilityLabel("Flere faner")
    }

    private func spaceTitle(_ item: Space) -> String {
        switch item {
        case .brain: "Hjem"
        case .notes: "Chat"
        case .gallery: "Video"
        case .tasks: "Landsby"
        case .library: "Code Bot"
        }
    }

    private func spaceIcon(_ item: Space) -> String {
        switch item {
        case .brain: "house.fill"
        case .notes: "bubble.left.fill"
        case .gallery: "play.rectangle.fill"
        case .tasks: "house.lodge.fill"
        case .library: "chevron.left.forwardslash.chevron.right"
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
            .preferredColorScheme(appearanceMode.preferredScheme(for: theme))
            .tint(palette.isDark ? palette.lime : palette.text)
            .foregroundStyle(palette.text)
    }

}
