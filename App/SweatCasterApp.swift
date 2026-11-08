import AVKit
import AVFoundation
import UniformTypeIdentifiers
import PhotosUI
import ImageIO
import Speech
import Observation
import AppIntents
import SwiftUI
import UIKit

struct OpenSweatCasterChat: AppIntent {
    static let title: LocalizedStringResource = "Åbn FadedAI-chat"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("chat", forKey: "spaces.shortcut")
        return .result()
    }
}

struct OpenSweatCasterVideo: AppIntent {
    static let title: LocalizedStringResource = "Vælg klip i FadedAI"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("video", forKey: "spaces.shortcut")
        return .result()
    }
}

struct OpenFadedAIPrivateChat: AppIntent {
    static let title: LocalizedStringResource = "Start privat chat"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("private-chat", forKey: "spaces.shortcut")
        return .result()
    }
}

struct SweatCasterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSweatCasterChat(), phrases: ["Åbn chat i \(.applicationName)"],
                    shortTitle: "Åbn chat", systemImageName: "bubble.left")
        AppShortcut(intent: OpenSweatCasterVideo(), phrases: ["Vælg klip i \(.applicationName)"],
                    shortTitle: "Vælg klip", systemImageName: "film")
        AppShortcut(intent: OpenFadedAIPrivateChat(), phrases: ["Start privat chat i \(.applicationName)"],
                    shortTitle: "Privat chat", systemImageName: "lock.shield")
    }
}

private struct PromptExample: Identifiable {
    let text: String
    var id: String { text }
    static let examples = [
        Self(text: "Lav et hype-klip af den nyeste fil."),
        Self(text: "Analyser denne tekst:"),
        Self(text: "Foreslå en kort titel til mit næste klip."),
        Self(text: "Lav en tjekliste til min næste optagelse."),
        Self(text: "Giv mig tre idéer til et sjovt gamingklip.")
    ]
}

@main struct SweatCasterApp: App {
    @UIApplicationDelegateAdaptor(FadedAIModelDownloadDelegate.self) private var modelDownloadDelegate
    @AppStorage("app.text.scale") private var textScale = 0.0
    @AppStorage("app.resetGeneration") private var resetGeneration = ""
    @Environment(\.dynamicTypeSize) private var systemTextSize
    var body: some Scene {
        WindowGroup {
            Home().id(resetGeneration).dynamicTypeSize(textScale == 0 ? systemTextSize :
                [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge,
                 .accessibility1, .accessibility2][min(5, max(0, Int(textScale)))])
        }
    }
}

private struct Media: Identifiable {
    let id = UUID()
    let url: URL
    let demo: Bool
}

private struct DashboardVideoCard: View {
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

struct Home: View {
    private enum SettingsCategory: String, CaseIterable {
        case connection = "Forbindelse", models = "Modeller", appearance = "Udseende"
        case chat = "Chat", audio = "Lyd", diagnostics = "Diagnostik"

        var icon: String {
            switch self {
            case .connection: "network"
            case .models: "cpu"
            case .appearance: "paintpalette"
            case .chat: "bubble.left"
            case .audio: "speaker.wave.2"
            case .diagnostics: "stethoscope"
            }
        }

        var detail: String {
            switch self {
            case .connection: "Hjem, Tailscale og PC-status"
            case .models: "Kåre, Core ML og Grok"
            case .appearance: "Tema, tekst og bevægelse"
            case .chat: "Værktøjsstatus og genveje"
            case .audio: "Stemme og haptik"
            case .diagnostics: "Ping, log og lokale data"
            }
        }
    }
    private struct StudioToast: Identifiable {
        let id = UUID()
        let text: String
    }
    private enum SettingsFollowup { case login, models, privateChat, bots, code, export }
    private enum Space: String, CaseIterable, Identifiable {
        case brain = "Brain", notes = "Notes", gallery = "Gallery", tasks = "Tasks", library = "Library"
        var id: Self { self }
    }

    @Environment(\.scenePhase) private var phase
    @State private var model = Model()
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var settingsFollowup: SettingsFollowup?
    @State private var recentChats: [ChatTurn] = []
    @State private var pingResult: String?
    @State private var pinging = false
    @AppStorage("studio.images.autoSavePhotos") private var saveImagesToPhotos = false
    @AppStorage("appearance.theme") private var theme = FadedTheme.faded
    @AppStorage("chat.voiceMode") private var readChatAloud = false
    @AppStorage("ai.showTools") private var showChatTools = true
    @State private var diagnosticsExport: DiagnosticsExport?
    @State private var diagnosticsError = false
    @State private var media: Media?
    @State private var showChat = false
    @State private var errorDetails = false
    @AccessibilityFocusState private var errorFocus: Bool
    @AccessibilityFocusState private var jobsFocus: Bool
    @State private var showJobs = 0
    @State private var space: Space = .brain
    @State private var moduleTabs: [ModuleTab] = []
    @State private var moduleAddress: String?
    @State private var selectedModuleTab: String?
    @State private var showHelp = false
    @State private var showCodeWorkspace = false
    @State private var showPhoneModels = false
    @State private var showOfflineStudio = false
    @State private var showBots = false
    @State private var studioPage: OfflineStudio.Page = .chat
    @State private var studioImagePrompt = ""
    @State private var imagePromptAfterChat: String?
    @State private var studioToast: StudioToast?
    @State private var nsfwSessionUnlocked = false
    @State private var showSavedVideos = false
    @State private var savedVideos: [URL] = []
    @State private var pendingLocalDeletion: URL?
    @State private var localDeletionError = false
    @State private var pcDeletion: (id: String, api: LiveAPI)?
    @State private var failedJobDeletion: (id: String, api: LiveAPI)?
    @State private var deletingPCVideo = false
    @AppStorage("app.text.scale") private var textScale = 0.0
    @Environment(\.dynamicTypeSize) private var videoTypeSize
    @State private var clipGame = ""
    @State private var shortClips = false
    @State private var recentJobsFirst = false
    @State private var clipDateRange = 0
    @State private var selectedGameFolder: String?
    @State private var clipRoots: [V2ClipRoots.Root] = []
    @State private var folderPages: [String: [Clip]] = [:]
    @State private var folderPageNotices: [String: String] = [:]
    @State private var folderNotice: String?
    @State private var videoFolderServer: String?
    @State private var legacyClipCatalog = false
    @State private var catalogLoading: UUID?
    @State private var pageLoading: UUID?
    @State private var videoStartNotice: String?
    @State private var saveVideoNotice: String?
    @State private var confirmClear = false
    @State private var hiddenJobs = Set<String>()
    @AppStorage("spaces.onboarded") private var onboarded = false
    @AppStorage("spaces.font") private var font = "Standard"
    @AppStorage("spaces.motion") private var motion = false
    @AppStorage("spaces.shortcut") private var shortcut = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("video.lastMood") private var selectedVideoMood: Mood = .hype
    @State private var jobFilter = 0
    @AppStorage("qol.confirmVideo") private var confirmVideoStart = true
    @AppStorage("qol.compactClips") private var compactClipCards = false
    @AppStorage("qol.showDurations") private var showClipDurations = true
    @AppStorage("qol.jobDetails") private var showJobDetails = false
    @AppStorage("qol.keepAwake") private var keepScreenAwake = false
    @AppStorage("qol.haptics") private var appHaptics = true
    @AppStorage("qol.reduceMotion") private var calmMotion = false
    @AppStorage("qol.rememberSpace") private var rememberLastSpace = true
    @AppStorage("qol.autoRefreshTabs") private var autoRefreshTabs = true
    @AppStorage("qol.connectionBanner") private var showConnectionBanner = true
    @AppStorage("qol.lastSpace") private var lastSpace = Space.brain.rawValue
    @State private var pendingVideoMood: Mood?

    private var palette: FadedPalette { FadedPalette(theme: theme) }

    private var visibleJobs: [Job] {
        model.jobs.filter { job in
            !hiddenJobs.contains(job.id) &&
            (jobFilter == 0 || (jobFilter == 1 && job.status.active) ||
             (jobFilter == 2 && job.status == .completed) || (jobFilter == 3 && job.status == .failed))
        }
    }

    private var homeContent: some View {
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
            AgentHub(api: model.api as? LiveAPI, isVisible: space == .tasks && selectedModuleTab == nil,
                     studioUnlocked: $nsfwSessionUnlocked,
                     onPrivateSessionEnded: showPrivateSessionNotice, onBack: { selectSpace(.brain) })
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Landsby", systemImage: "house.lodge.fill") }.tag(Space.tasks.rawValue)
            CodeWorkspaceView(api: model.api as? LiveAPI, onBack: { selectSpace(.brain) })
                .toolbarVisibility(.hidden, for: .tabBar)
                .tabItem { Label("Code Bot", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(Space.library.rawValue)
            if moduleAddress == model.address, let api = model.api as? LiveAPI {
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
        .onChange(of: showJobs) { selectedModuleTab = nil; space = .gallery; jobsFocus = true }
        .onChange(of: showClips) { selectedModuleTab = nil; space = .gallery }
        .task(id: "\(model.isDemo):\(model.address):\(phase == .active)") {
            if phase == .active { await loadModuleTabs() }
        }
        .onChange(of: space) { _, value in
            selectedModuleTab = nil
            if value == .brain { refreshDashboard() }
            if rememberLastSpace { lastSpace = value.rawValue }
            if autoRefreshTabs && !model.isDemo { Task { await model.refresh() } }
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
                    Text("FadedAI").font(FadedTypography.title).tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .principal) { dashboardConnection }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Indstillinger", systemImage: "gearshape") { showSettings = true }
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
                chatEntry("Privat chat (NSFW)", detail: "Lokal botchat · Face ID", icon: "lock.shield") { openStudio(.chat) }
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

    private func selectSpace(_ destination: Space) {
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

    private var homeBackground: some View {
        FadedBackground().overlay {
            if motion && !reduceMotion && phase == .active && theme == .faded && space == .brain {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { clock in
                    let strength = 0.04 + 0.02 * sin(clock.date.timeIntervalSinceReferenceDate / (calmMotion ? 4 : 2))
                    LinearGradient(colors: [palette.cyan.opacity(strength), .clear], startPoint: .topLeading, endPoint: .center)
                }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private var homeLifecycle: some View {
        homeContent
        .onAppear {
            prunePreviews()
        }
        .onChange(of: model.error?.title) { _, title in
            errorDetails = false
            if title != nil { errorFocus = true }
        }
        .onChange(of: model.isDemo) { hiddenJobs.removeAll() }
        .onChange(of: model.address) { hiddenJobs.removeAll() }
    }

    private var homeFeedback: some View {
        let completed: [String] = model.jobs.filter { $0.status == .completed }.map(\.id)
        let rendering: [String] = model.jobs.filter { $0.status == .rendering }.map(\.id)
        let failed: [String] = model.jobs.filter { $0.status == .failed }.map(\.id)
        return homeLifecycle
            .sensoryFeedback(.impact(weight: .light), trigger: appHaptics ? selectedModuleTab ?? space.rawValue : "")
            .sensoryFeedback(.success, trigger: completed) { old, new in
                appHaptics && !Set(new).subtracting(old).isEmpty
            }
            .sensoryFeedback(.impact(weight: .light), trigger: rendering) { old, new in
                appHaptics && !Set(new).subtracting(old).isEmpty
            }
            .sensoryFeedback(.error, trigger: failed) { old, new in
                appHaptics && !Set(new).subtracting(old).isEmpty
            }
    }

    private var homePresentation: some View {
        let design: Font.Design = font == "Afrundet" ? .rounded :
            (font == "Monospace" ? .monospaced : .default)
        return ZStack {
            homeBackground
            if model.connected || model.isDemo {
                homeFeedback
            } else {
                LoginView(model: model, openLocalChat: { showChat = true },
                          openLocalStudio: { openStudio(.chat) }, openLocalBots: { showBots = true },
                          exportDiagnostics: exportDiagnostics)
            }
        }
        .fontDesign(design)
    }

    private var homeStartup: some View {
        homePresentation
        .onAppear {
            FadedTheme.migrateIfNeeded()
            UIDevice.current.isBatteryMonitoringEnabled = true
            StudioScratch.purgeOnceAtLaunch()
            openShortcut()
        }
        .onOpenURL { url in
            guard url.scheme == "fadedai" else { return }
            switch url.host {
            case "video": space = .gallery; showClips += 1
            default: break
            }
        }
        .onChange(of: shortcut) { openShortcut() }
        .onChange(of: phase, initial: true) { _, value in
            if value == .background { LocalCompute.suspend() }
            if value == .active { LocalCompute.resume() }
        }
        .task(id: renderActivityKey) {
            await RenderLiveActivity.shared.sync(jobs: model.jobs, server: model.address, enabled: !model.isDemo && model.connected)
        }
    }

    private var homeNotices: some View {
        homeStartup
        .overlay(alignment: .top) {
            if let studioToast {
                Text(studioToast.text).font(.callout)
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 8)
            }
        }
        .task(id: studioToast?.id) {
            guard let id = studioToast?.id else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if studioToast?.id == id { studioToast = nil }
        }
        .sheet(isPresented: $showLogin) { LoginView(model: model, close: { showLogin = false }) }
        .sheet(isPresented: $showSettings, onDismiss: openSettingsFollowup) { settingsSheet }
        .sheet(item: $diagnosticsExport) { DiagnosticsShareSheet(url: $0.url) }
        .alert("Fejlloggen kunne ikke eksporteres", isPresented: $diagnosticsError) {
            Button("OK", role: .cancel) {}
        }
    }

    private var homeVideoDialogs: some View {
        homeNotices
        .confirmationDialog("Slet den redigerede video fra PC’en?", isPresented: Binding(
            get: { pcDeletion != nil }, set: { if !$0 { pcDeletion = nil } }
        ), presenting: pcDeletion) { target in
            Button("Slet video fra PC’en", role: .destructive) {
                Task { await deletePCVideo(target.id, using: target.api) }
            }
        } message: { _ in
            Text("Originalklippet og eventuelle kopier på telefonen bevares.")
        }
        .confirmationDialog("Slet fejlet job fra PC’en?", isPresented: Binding(
            get: { failedJobDeletion != nil }, set: { if !$0 { failedJobDeletion = nil } }
        ), presenting: failedJobDeletion) { target in
            Button("Slet fejlet job", role: .destructive) {
                Task {
                    do {
                        try await target.api.deleteFailedJob(target.id)
                        await model.refresh()
                    } catch { saveVideoNotice = "PC’en kunne ikke slette jobbet. Prøv at opdatere listen." }
                    failedJobDeletion = nil
                }
            }
        } message: { _ in Text("Kun den fejlede jobpost slettes. Originalklippet bevares.") }
        .confirmationDialog("Skjul afsluttede jobs på denne telefon?", isPresented: $confirmClear) {
            Button("Skjul afsluttede jobs", role: .destructive) {
                hiddenJobs.formUnion(model.jobs.filter { !$0.status.active }.map(\.id))
            }
        } message: {
            Text("Videoerne og jobhistorikken bliver liggende på PC’en.")
        }
        .confirmationDialog("Start videomagi?", isPresented: Binding(
            get: { pendingVideoMood != nil }, set: { if !$0 { pendingVideoMood = nil } }
        ), presenting: pendingVideoMood) { mood in
            Button("Start \(mood.title)") { startVideo(mood); pendingVideoMood = nil }
            Button("Annuller", role: .cancel) { pendingVideoMood = nil }
        } message: { mood in
            Text("Starter \(model.selected.count) valgte klip med \(mood.title).")
        }
    }

    private var homeSheets: some View {
        homeVideoDialogs
        .sheet(isPresented: $showCodeWorkspace) {
            CodeWorkspaceView(api: model.api as? LiveAPI, onBack: { showCodeWorkspace = false })
        }
        .sheet(isPresented: $showPhoneModels) { PhoneModelsView() }
        .sheet(isPresented: $showOfflineStudio) {
            OfflineStudio(api: studioAPI, sessionUnlocked: $nsfwSessionUnlocked,
                          onPrivateSessionEnded: showPrivateSessionNotice,
                          initialPage: studioPage, initialImagePrompt: studioImagePrompt,
                          ephemeralOnly: studioPage == .chat)
        }
        .sheet(isPresented: $showBots) {
            VillageBotLibrary(api: studioAPI, studioUnlocked: $nsfwSessionUnlocked,
                              onPrivateSessionEnded: showPrivateSessionNotice, onBack: { showBots = false })
        }
        .sheet(isPresented: $showSavedVideos) { savedVideoLibrary }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                List {
                    Text("Brain: Vælg klip, vælg en stil, eller chat med din PC.")
                    Text("Gallery: Følg dine jobs, og afspil eller del videoer.")
                    Text("Tasks: Se videojobs, der stadig kører.")
                    Text("Notes og Library: Skriv noter, og find forslag til chatten.")
                }.navigationTitle("Hvad kan jeg?")
                    .toolbar { Button("Luk") { showHelp = false } }
            }
        }
    }

    private var homePolling: some View {
        homeSheets
        .task(id: phase) {
            if phase == .active { await model.refresh() }
        }
        .task { await JobNotifications.shared.configure() }
        .task(id: "\(phase == .active && model.connected && !model.isDemo):\(model.address)") {
            guard phase == .active, model.connected, !model.isDemo else { return }
            while !Task.isCancelled {
                guard await model.pollCodeJobs() else { return }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .task(id: phase == .active && model.hasActive) {
            guard phase == .active && model.hasActive else { return }
            while !Task.isCancelled && model.hasActive {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !Task.isCancelled { await model.poll() }
            }
        }
    }

    var body: some View {
        homePolling
            .sheet(item: $media) { Preview(media: $0) }
            .sheet(isPresented: $showChat, onDismiss: refreshAfterChat) { chatSheet }
            .environment(\.fadedPalette, palette)
            .preferredColorScheme(theme.colorScheme)
            .tint(palette.isDark ? palette.lime : palette.text)
            .foregroundStyle(palette.text)
    }

    private func refreshAfterChat() {
        refreshDashboard()
        if let prompt = imagePromptAfterChat {
            imagePromptAfterChat = nil
            openStudio(.images, prompt: prompt)
            return
        }
        guard !model.isDemo else { return }
        Task { await model.refresh() }
    }

    private var chatSheet: some View {
        let session = model.isDemo ? "demo" : (model.connected ? model.address : "offline")
        let api: (any ChatAPI)? = model.connected || model.isDemo ? model.api as? any ChatAPI : nil
        let status = model.connected ? "Forbundet" : "Ikke forbundet"
        let connection = model.isDemo ? "Demo · Testdata" : "\(model.activeProfile.route) · \(status)"
        return ChatView(api: api, demo: model.isDemo, initialDraft: "", connection: connection,
                        storageKey: "spaces.chat." + session, onBack: { showChat = false },
                        openImageStudio: openImagesFromChat)
            .id(session)
    }

    private var studioAPI: LiveAPI? {
        model.isDemo || !model.connected ? nil : model.api as? LiveAPI
    }

    private func openStudio(_ page: OfflineStudio.Page, prompt: String = "") {
        studioPage = page
        studioImagePrompt = prompt
        showOfflineStudio = true
    }

    private func openImagesFromChat(_ prompt: String) {
        imagePromptAfterChat = prompt
        showChat = false
    }

    private func showPrivateSessionNotice() {
        studioToast = StudioToast(text: "Privat session afsluttet og slettet.")
    }

    @ViewBuilder private var header: some View {
        if model.isDemo {
            FadedCard(accent: palette.purple) { Text("Demo · Kun testdata").font(FadedTypography.action) }
        }
        dashboardActiveJob
        FadedSectionLabel("Hurtige handlinger")
        quickActions
        dashboardRecentChats
        dashboardVideos
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
        if let error = model.error {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.errorTitle ?? error.title).font(.headline).accessibilityFocused($errorFocus)
                if let detail = error.detail {
                    DisclosureGroup("Tekniske detaljer", isExpanded: $errorDetails) {
                        Text(detail).textSelection(.enabled)
                    }
                }
                action("Prøv igen") {
                    if model.connected || !model.address.isEmpty { Task { await model.refresh() } }
                    else { showLogin = true }
                }.disabled(switchDisabled)
            }
        }
    }

    @ViewBuilder private var dashboardConnection: some View {
        if showConnectionBanner && !model.isDemo {
            let status = model.connected ? "PC · \(model.address)" : "Telefon"
            HStack(spacing: 6) {
                Circle().fill(model.connected ? palette.cyan : palette.green).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(status).font(.caption.monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(palette.secondary)
            .accessibilityLabel("Kører på: \(status)")
        }
    }

    @ViewBuilder private var dashboardActiveJob: some View {
        if let job = model.jobs.first(where: { $0.status.active }) {
            FadedSectionLabel("I gang")
            FadedCard(accent: palette.cyan) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(job.mood.title) · \(job.status.title)").font(FadedTypography.title)
                    FadedProgress(value: job.progress)
                    FadedSecondaryButton("Følg video", icon: "film") {
                        selectSpace(.gallery)
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) { quickActionCards }
            VStack(spacing: 8) { quickActionCards }
        }
    }

    @ViewBuilder private var quickActionCards: some View {
        quickAction("Ny chat", detail: "Dit AI-hold", icon: "message", accent: palette.green) { selectSpace(.notes) }
        quickAction("Ny video", detail: "Video Studio", icon: "video", accent: palette.cyan) { selectSpace(.gallery) }
        quickAction("Ny bot", detail: "Byg din makker", icon: "person.crop.circle.badge.plus", accent: palette.purple) { showBots = true }
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
        }
    }

    private func dashboardSourceColor(_ source: String?) -> Color {
        if source == GrokAPI.sourceLabel { return palette.purple }
        if source == "PC" { return palette.cyan }
        return palette.green
    }

    private var dashboardVideos: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedSectionLabel("Gemte videoer")
            ForEach(savedVideos.prefix(3), id: \.self) { file in
                Button { media = Media(url: file, demo: false) } label: { DashboardVideoCard(file: file) }
                    .buttonStyle(.plain)
            }
            FadedSecondaryButton("Åbn videobibliotek", icon: "film.stack") { reloadSavedVideos(); showSavedVideos = true }
        }
    }

    private func refreshDashboard() {
        reloadSavedVideos()
        recentChats = Array(ChatArchive.turns().prefix(3))
    }

    @ViewBuilder private var loadingStatus: some View {
        if model.busy || model.refreshing || model.mediaLoading {
            LoadingSkeleton(label: model.mediaLoading ? "Henter video…" : "Henter klip og job…")
        }
    }

    private var connectionIndicator: some View {
        let latency = model.latencyMs
        let color: Color = latency.map { $0 < 100 ? .green : $0 < 300 ? .yellow : .red } ?? .secondary
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Label("\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                  systemImage: model.connected ? "checkmark.circle" : "exclamationmark.circle")
            if let latency { Text("\(latency) ms").foregroundStyle(.secondary) }
        }.font(.subheadline)
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    ForEach(SettingsCategory.allCases, id: \.self) { category in
                        NavigationLink { settingsPage(category) } label: { settingsRow(category) }
                            .buttonStyle(.plain)
                    }
                }.padding(FadedSpacing.edge)
            }
            .background(FadedBackground())
            .navigationTitle("Indstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { showSettings = false } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(palette.background)
    }

    private func settingsRow(_ category: SettingsCategory) -> some View {
        let accent: Color = switch category {
        case .connection: palette.cyan
        case .models: palette.purple
        case .appearance: palette.lime
        case .chat: palette.green
        case .audio: palette.coral
        case .diagnostics: palette.secondary
        }
        return FadedCard {
            HStack(spacing: 12) {
                Image(systemName: category.icon).foregroundStyle(FadedColors.deep)
                    .frame(width: 34, height: 34).background(accent, in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    FadedSectionLabel(category.rawValue)
                    Text(category.detail).font(.subheadline).foregroundStyle(palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(palette.secondary).accessibilityHidden(true)
            }
        }
    }

    private func settingsPage(_ category: SettingsCategory) -> some View {
        Form {
            switch category {
            case .connection:
                connectionIndicator
                Button("Skift forbindelse") { closeSettings(for: .login) }.disabled(switchDisabled)
                Toggle("Vis forbindelsesbanner", isOn: $showConnectionBanner)
                Toggle("Opdatér ved faneskift", isOn: $autoRefreshTabs)
            case .models:
                Button("Lokale modeller") { closeSettings(for: .models) }
                Button("Privat chat (NSFW)") { closeSettings(for: .privateChat) }
                Button("Mine bots") { closeSettings(for: .bots) }
                Button("Code Bot og Agent Workspace") { closeSettings(for: .code) }
                CloudModelSettings()
            case .appearance:
                appearanceSettings
            case .chat:
                Toggle("Vis værktøjsstatus", isOn: $showChatTools)
                Button("Åbn AI-chat", systemImage: "bubble.left") { showSettings = false; selectSpace(.notes) }
            case .audio:
                Toggle("Læs chatsvar op", isOn: $readChatAloud)
                Toggle("Haptisk feedback", isOn: $appHaptics)
                Text("Vælg stemme i chatten eller på din bots profil.").font(.callout).foregroundStyle(palette.secondary)
            case .diagnostics:
                Button(pinging ? "Tester PC…" : "Ping PC", systemImage: "network") {
                    Task {
                        pinging = true
                        defer { pinging = false }
                        pingResult = await model.ping()
                    }
                }.disabled(pinging)
                if let pingResult { Text(pingResult).font(.caption).foregroundStyle(.secondary) }
                ResourceMonitor()
                Button("Eksportér fejllog", systemImage: "square.and.arrow.up") { closeSettings(for: .export) }
                Toggle("Gem genererede billeder i Fotos", isOn: $saveImagesToPhotos)
                Toggle("Bekræft før video startes", isOn: $confirmVideoStart)
                Button("Ryd midlertidige previews") {
                    prunePreviews(); saveVideoNotice = "Midlertidige previews er ryddet."
                }
                Button("Skjul afsluttede jobs på denne telefon", role: .destructive) { confirmClear = true }
                NukeLocalDataButton()
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle(category.rawValue)
    }

    private func closeSettings(for destination: SettingsFollowup) {
        settingsFollowup = destination
        showSettings = false
    }

    private func openSettingsFollowup() {
        guard let destination = settingsFollowup else { return }
        settingsFollowup = nil
        switch destination {
        case .login: showLogin = true
        case .models: showPhoneModels = true
        case .privateChat: openStudio(.chat)
        case .bots: showBots = true
        case .code: showCodeWorkspace = true
        case .export: exportDiagnostics()
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        Picker("Tema", selection: $theme) {
            ForEach(FadedTheme.allCases) { choice in Text(choice.rawValue).tag(choice) }
        }
        textSizeSetting
        Picker("Skrift", selection: $font) {
            ForEach(["Standard", "Afrundet", "Monospace"], id: \.self) { Text($0) }
        }
        Toggle("Bevægelse i baggrunden", isOn: $motion)
        Toggle("Ekstra rolig bevægelse", isOn: $calmMotion)
        Toggle("Husk seneste fane", isOn: $rememberLastSpace)
        Toggle("Hold skærmen vågen", isOn: $keepScreenAwake)
        Toggle("Kompakte klipkort", isOn: $compactClipCards)
        Toggle("Vis kliplængde", isOn: $showClipDurations)
        Toggle("Vis jobdetaljer", isOn: $showJobDetails)
    }

    private var textSizeSetting: some View {
        let slider = Slider<Text, EmptyView>(value: $textScale, in: 0.0...5.0, step: 1.0,
                                             label: { Text("Tekststørrelse") })
        return slider
            .accessibilityLabel("Tekststørrelse i appen")
            .sensoryFeedback(.selection, trigger: textScale) { (old: Double, new: Double) in
                appHaptics && old != new && (new == 0 || new == 5)
            }
    }

    private var renderActivityKey: String {
        "\(model.address):\(model.connected):\(model.isDemo):\(model.jobsObservationWindow):" + model.jobs.filter { $0.status.active }
            .map { "\($0.id):\($0.status.rawValue):\($0.progress)" }.joined(separator: ",")
    }

    private func exportDiagnostics() {
        do { diagnosticsExport = DiagnosticsExport(url: try AppDiagnostics.export()) }
        catch { diagnosticsError = true }
    }

    private func openShortcut() {
        guard !shortcut.isEmpty else { return }
        let destination = shortcut
        shortcut = ""
        switch destination {
        case "private-chat":
            nsfwSessionUnlocked = false
            openStudio(.chat)
        case "chat": showChat = true
        case "video": space = .gallery; showClips += 1
        default: break
        }
    }

    private var switchDisabled: Bool {
        model.busy || model.refreshing || model.mediaLoading || !model.cancelling.isEmpty
    }

    private func prunePreviews() {
        let files = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        for file in files ?? [] where file.pathExtension == "mp4" &&
            (file.lastPathComponent.hasPrefix("Demo-") || file.lastPathComponent.hasPrefix("Sweat-")) {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate, Date().timeIntervalSince(date) > 86400 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private var videoStudio: some View {
        NavigationStack {
            ScrollViewReader { scroll in videoScroll(scroll) }
        }
        .task(id: videoFolderScope) {
            guard let server = videoFolderScope, videoFolderServer != server else { return }
            await loadGameFolders(for: server)
        }
        .task(id: "\(videoFolderScope ?? ""):\(selectedGameFolder ?? "")") {
            guard let id = selectedGameFolder, let server = videoFolderScope else { return }
            await loadFolderPage(id, for: server)
        }
    }

    private func videoScroll(_ scroll: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                videoStudioHeader
                videoFeedback
                clipSection { closeVideoFolder(andShow: "recipe", scroll: scroll) }
                moodSection.id("recipe")
                jobSection.id("jobs")
            }
            .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .navigationTitle("Video Studio")
        .background { FadedBackground(variant: .standard) }
        .toolbar { videoToolbar(scroll) }
        .safeAreaInset(edge: .bottom) { videoBottomBar(scroll) }
        .refreshable { await refreshVideoStudio() }
        .onChange(of: showJobs) { scroll.scrollTo("jobs", anchor: .top) }
        .onChange(of: showClips) { scroll.scrollTo("clips", anchor: .top) }
    }

    @ToolbarContentBuilder private func videoToolbar(_ scroll: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Tilbage", systemImage: "chevron.left") { selectSpace(.brain) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectedGameFolder != nil {
                Button("Luk mappe", systemImage: "folder") {
                    closeVideoFolder(andShow: "clips", scroll: scroll)
                }.labelStyle(.iconOnly)
            }
            Button("Videoindstillinger", systemImage: "slider.horizontal.3") {
                closeVideoFolder(andShow: "recipe", scroll: scroll)
            }.labelStyle(.iconOnly)
        }
    }

    @ViewBuilder private func videoBottomBar(_ scroll: ScrollViewProxy) -> some View {
        if !model.selected.isEmpty {
            VStack(spacing: 4) {
                if selectedGameFolder != nil {
                    FadedSecondaryButton("Luk mappe", icon: "chevron.up") {
                        closeVideoFolder(andShow: "recipe", scroll: scroll)
                    }
                }
                videoStartControls
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(palette.raised.opacity(0.96))
        }
    }

    private func closeVideoFolder(andShow target: String, scroll: ScrollViewProxy) {
        selectedGameFolder = nil
        scroll.scrollTo(target, anchor: .top)
    }

    private var videoStudioHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedSignature()
            FadedSectionLabel("Video Studio")
            Text("Skab noget, der rammer.").font(.largeTitle.bold())
                .foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
            Text("Vælg dine klip. Din agent klarer resten.")
                .font(.body).foregroundStyle(palette.secondary)
            FadedSecondaryButton(model.isDemo ? "Opdatér testklip" : "Opdatér spilmapper", icon: "arrow.clockwise") {
                Task { await refreshVideoStudio() }
            }.disabled(switchDisabled || catalogLoading != nil || pageLoading != nil)
        }
    }

    @ViewBuilder private var videoFeedback: some View {
        if model.selected.isEmpty, let message = videoStartNotice ?? model.errorTitle {
            FadedCard(accent: palette.coral) {
                Label(message, systemImage: "exclamationmark.circle").font(.headline)
                    .accessibilityFocused($errorFocus)
            }
        }
    }

    private func clipSection(onDone: @escaping () -> Void) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Vælg klip")
                Text("\(model.selected.count) valgt af maks. \(model.capabilities?.limit ?? 10)")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                if !model.selected.isEmpty {
                    let seconds = model.clips.filter { model.selected.contains($0.id) }.reduce(0) { $0 + $1.duration_seconds }
                    Text("Valgt spilletid · \(durationLabel(seconds))").font(.caption.bold())
                        .foregroundStyle(palette.isDark ? palette.lime : palette.text)
                    FadedSecondaryButton("Ryd klipvalg", icon: "xmark") { model.clearSelection() }.disabled(model.busy)
                }
                videoFolders(onDone: onDone)
                if let folderNotice { Text(folderNotice).font(.caption).foregroundStyle(palette.secondary) }
            }
        }
        .id("clips")
    }

    @ViewBuilder private func videoFolders(onDone: @escaping () -> Void) -> some View {
        if model.isDemo {
            clipFolder(id: "demo", title: "Testklip", subtitle: nil, onDone: onDone)
        } else if catalogLoading != nil || (videoFolderServer != model.address && folderNotice == nil) {
            LoadingSkeleton(label: "Henter spilmapper…")
        } else if videoFolderServer == model.address {
            if legacyClipCatalog {
                clipFolder(id: "legacy", title: "PC’ens V1-klipliste", subtitle: "Ældre server uden spilmapper", onDone: onDone)
            } else {
                ForEach(clipRoots) { root in
                    let subtitle = root.indexing || !root.ready ? "PC’en indekserer klip" : "\(root.file_count) filer på PC’en"
                    clipFolder(id: root.id, title: root.label, subtitle: subtitle, onDone: onDone)
                }
            }
        }
    }

    private func clipFolder(id: String, title: String, subtitle: String?, onDone: @escaping () -> Void) -> some View {
        let expanded = selectedGameFolder == id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedGameFolder = expanded ? nil : id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: expanded ? "folder.fill" : "folder")
                            .font(.headline)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(palette.secondary) }
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(FadedButtonStyle(kind: .secondary))
            .accessibilityValue(expanded ? "Åben" : "Lukket")
            if expanded {
                if id == "demo" {
                    clipList(model.clips, onDone: onDone)
                } else if pageLoading != nil {
                    LoadingSkeleton(label: "Henter klip i mappen…")
                } else if let clips = folderPages[id] {
                    clipList(clips, onDone: onDone)
                }
                if let notice = folderPageNotices[id] {
                    Text(notice).font(.caption).foregroundStyle(palette.secondary)
                    FadedSecondaryButton("Opdatér mappen", icon: "arrow.clockwise") {
                        guard let server = videoFolderScope else { return }
                        Task { await loadFolderPage(id, for: server, force: true) }
                    }
                }
            }
        }
    }

    private func clipList(_ clips: [Clip], onDone: @escaping () -> Void) -> some View {
        let filtered = filteredClips(clips)
        return VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("Filtrér klip") {
                TextField("Søg i filnavn", text: $clipGame).textFieldStyle(.roundedBorder)
                Toggle("Under ét minut", isOn: $shortClips)
                Toggle("Seneste jobdato først", isOn: $recentJobsFirst)
                Picker("Jobdato", selection: $clipDateRange) {
                    Text("Alle datoer").tag(0)
                    Text("Seneste 7 dage").tag(7)
                    Text("Seneste 30 dage").tag(30)
                }
                Text("Datoen kommer fra tidligere job med klippet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { clipListActions(filtered, onDone: onDone) }
                VStack(alignment: .leading) { clipListActions(filtered, onDone: onDone) }
            }
            if filtered.isEmpty {
                FadedEmptyState(icon: "film", title: clips.isEmpty ? "Mappen er tom" : "Ingen klip matcher",
                                detail: clips.isEmpty ? "PC’en har ingen klip klar i denne mappe." : "Prøv et andet filnavn eller filter.")
            } else {
                Text("PC’en sender klipnavne og varighed.").font(.caption).foregroundStyle(palette.secondary)
                LazyVGrid(columns: videoClipColumns, spacing: 12) {
                    ForEach(filtered) { clip in videoClipCard(clip) }
                }
            }
        }
    }

    @ViewBuilder private func clipListActions(_ clips: [Clip], onDone: @escaping () -> Void) -> some View {
        FadedSecondaryButton("Vælg synlige", icon: "checkmark.circle") { model.select(clips) }
            .disabled(model.busy || clips.isEmpty)
        FadedSecondaryButton("Færdig med klipvalg", icon: "chevron.up", action: onDone)
    }

    private var videoClipColumns: [GridItem] {
        videoTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 132, maximum: 260), spacing: 12)]
    }

    private func videoClipCard(_ clip: Clip) -> some View {
        let selected = model.selected.contains(clip.id)
        let shape = RoundedRectangle(cornerRadius: 14)
        return Button { model.toggle(clip) } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [clipColor(clip).opacity(0.58), Color.black.opacity(0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film").font(.title2.weight(.light)).foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                Text(clip.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2).padding(10)
            }
            .frame(minHeight: compactClipCards ? 86 : 116)
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(palette.lime)
                        .padding(6).background(.black.opacity(0.9), in: Circle()).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showClipDurations {
                    Text(durationLabel(clip.duration_seconds)).font(.caption.monospacedDigit())
                        .foregroundStyle(.white).padding(5).background(.black.opacity(0.9), in: Capsule()).padding(8)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(selected ? palette.lime : palette.border, lineWidth: selected ? 2 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(clip.name), \(durationLabel(clip.duration_seconds))")
        .accessibilityValue(selected ? "Valgt" : "Ikke valgt")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.busy || (!selected && model.selected.count >= (model.capabilities?.limit ?? 0)))
    }

    private func durationLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func startVideo(_ mood: Mood) {
        videoStartNotice = nil
        Task {
            let accepted = await model.submit(mood)
            if accepted || model.uncertain {
                selectedGameFolder = nil
                showJobs += 1
            } else if model.error == nil {
                videoStartNotice = videoStartBlocker ?? "Videojobbet blev ikke sendt. Kontrollér klipvalget, og prøv igen."
            }
        }
    }

    private func clipColor(_ clip: Clip) -> Color {
        let colors = [palette.green, palette.purple, palette.cyan, palette.coral]
        return colors[Int(clip.id.hashValue.magnitude % UInt(colors.count))]
    }

    @State private var showClips = 0

    private func filteredClips(_ source: [Clip]) -> [Clip] {
        let query = clipGame.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = Dictionary(model.jobs.map { ($0.clip_id, $0.created_at) }, uniquingKeysWith: max)
        let cutoff = Calendar.current.date(byAdding: .day, value: -clipDateRange, to: .now) ?? .distantPast
        let clips = source.filter {
            (!shortClips || $0.duration_seconds < 60) &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) &&
                (clipDateRange == 0 || (dates[$0.id] ?? .distantPast) >= cutoff)
        }
        guard recentJobsFirst else { return clips }
        return clips.sorted {
            let lhs = dates[$0.id] ?? .distantPast
            let rhs = dates[$1.id] ?? .distantPast
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }

    private var videoFolderScope: String? {
        guard phase == .active, space == .gallery, selectedModuleTab == nil, model.connected else { return nil }
        return model.isDemo ? "demo" : model.address
    }

    private func refreshVideoStudio() async {
        guard catalogLoading == nil, pageLoading == nil else { return }
        videoStartNotice = nil
        await model.refresh()
        guard let server = videoFolderScope else { return }
        await loadGameFolders(for: server)
        if let id = selectedGameFolder { await loadFolderPage(id, for: server, force: true) }
    }

    private func loadGameFolders(for server: String) async {
        guard videoFolderScope == server else { return }
        if videoFolderServer != server {
            clipRoots = []
            folderPages = [:]
            folderPageNotices = [:]
            folderNotice = nil
            selectedGameFolder = nil
            legacyClipCatalog = false
        }
        if model.isDemo { videoFolderServer = server; return }
        guard let api = model.api as? LiveAPI else { return }
        let ticket = UUID()
        catalogLoading = ticket
        defer { if catalogLoading == ticket { catalogLoading = nil } }
        do {
            let roots = try await api.v2ClipRoots().roots
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            videoFolderServer = server
            legacyClipCatalog = false
            var seen = Set<String>()
            clipRoots = roots.filter { root in
                (root.label.localizedCaseInsensitiveContains("fortnite") || root.label.localizedCaseInsensitiveContains("finals")) &&
                    seen.insert(root.id).inserted
            }
            if let id = selectedGameFolder, !clipRoots.contains(where: { $0.id == id }) { selectedGameFolder = nil }
            folderNotice = clipRoots.isEmpty ? "Ingen Fortnite- eller The Finals-mapper er sat op på PC’en." : nil
        } catch V2Failure.http(let status, _, _) where [404, 405, 501].contains(status) {
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            videoFolderServer = server
            clipRoots = []
            legacyClipCatalog = true
            if selectedGameFolder != "legacy" { selectedGameFolder = nil }
            folderNotice = nil
        } catch {
            guard !Task.isCancelled, videoFolderScope == server, catalogLoading == ticket else { return }
            folderNotice = "Spilmapperne kunne ikke hentes. Tryk på Opdatér spilmapper for at prøve igen."
        }
    }

    private func loadFolderPage(_ id: String, for server: String, force: Bool = false) async {
        guard videoFolderScope == server, videoFolderServer == server, !model.isDemo,
              let api = model.api as? LiveAPI,
              force || folderPages[id] == nil || folderPageNotices[id] != nil else { return }
        let ticket = UUID()
        pageLoading = ticket
        defer { if pageLoading == ticket { pageLoading = nil } }
        do {
            let clips: [Clip]
            let limit: Int
            let notice: String?
            if legacyClipCatalog && id == "legacy" {
                clips = try await api.clips().clips
                limit = 200
                notice = nil
            } else {
                guard clipRoots.contains(where: { $0.id == id }) else { return }
                let page = try await api.v2ClipPage(rootID: id, limit: 100)
                guard page.root_id == id else { throw V2Failure.invalidResponse }
                clips = page.clips
                limit = 100
                notice = page.ready && !page.indexing ? nil : "PC’en indekserer stadig klip. Opdatér mappen om lidt."
            }
            guard !Task.isCancelled, videoFolderScope == server, selectedGameFolder == id, pageLoading == ticket else { return }
            var seen = Set<String>()
            let pageClips = Array(clips.lazy.filter { validWireID($0.id) && seen.insert($0.id).inserted }.prefix(limit))
            folderPages[id] = pageClips
            folderPageNotices[id] = notice
            model.includeFolderClips(pageClips)
        } catch {
            guard !Task.isCancelled, videoFolderScope == server, selectedGameFolder == id, pageLoading == ticket else { return }
            folderPageNotices[id] = "Klip i denne mappe kunne ikke hentes."
        }
    }

    private var availableVideoMood: Mood? {
        guard let moods = model.capabilities?.moods else { return nil }
        return moods.contains(selectedVideoMood) ? selectedVideoMood : moods.first
    }

    private var videoStartBlocker: String? {
        if model.uncertain { return "Tjek joblisten, før du starter et nyt job." }
        if model.blocked { return "PC’en mangler en tjeneste. Se Status på PC’en under videoindstillinger." }
        if !model.options.roi.valid { return "Ret området til tekstlæsning i videoindstillinger." }
        if availableVideoMood == nil { return "PC’en har ingen tilgængelige stilarter." }
        if !model.cancelling.isEmpty { return "Venter på, at PC’en stopper videojobbet." }
        if !model.connected { return "Forbind til PC’en for at starte." }
        return nil
    }

    private var videoStartControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = videoStartNotice ?? model.errorTitle ?? videoStartBlocker {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(palette.secondary)
            }
            FadedPrimaryButton(model.busy ? "Sender videojob…" : "Start videomagi · \(model.selected.count) klip",
                               icon: "play.fill") {
                guard let mood = availableVideoMood else { return }
                if confirmVideoStart { pendingVideoMood = mood }
                else { startVideo(mood) }
            }
            .disabled(!model.canSubmit || videoStartBlocker != nil)
        }
        .frame(maxWidth: 640)
    }

    private var moodSection: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) { videoRecipeContents }
        }
    }

    @ViewBuilder private var videoRecipeContents: some View {
            FadedSectionLabel("Opskrift")
            Text("Vælg din energi").font(FadedTypography.title).foregroundStyle(palette.text)
            if let caps = model.capabilities {
                let columns = videoTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .leading)] :
                    [GridItem(.adaptive(minimum: 118), alignment: .leading)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Mood.allCases.filter(caps.moods.contains)) { mood in
                        FadedChip(mood.title, accent: palette.lime, selected: availableVideoMood == mood) {
                            selectedVideoMood = mood
                        }.disabled(model.busy)
                    }
                }
            }
            if !model.isDemo {
                Toggle("Kommentator", isOn: Binding(
                    get: { model.options.commentary != false },
                    set: { model.options.commentary = $0 ? nil : false }
                ))
                .tint(palette.lime).disabled(model.busy)
                Text(model.options.commentary == false ? "Video uden tale og undertekster" : "Engelsk reaktion med stemme og undertekster")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            if let caps = model.capabilities {
                Toggle("Fjern støj", isOn: Binding(get: { model.options.denoise }, set: { model.options.denoise = $0 }))
                    .tint(palette.lime).disabled(model.busy)
                if model.blocked { Label("PC’en er ikke klar til at lave videoer.", systemImage: "exclamationmark.circle").font(.headline) }
                if !caps.dependencies.isEmpty {
                    DisclosureGroup("Status på PC’en") {
                        ForEach(caps.dependencies, id: \.name) { dependency in
                            Text(dependency.message)
                        }
                    }
                }
                if caps.moods.isEmpty { Text("PC’en tilbyder ingen stilarter lige nu.") }
                advanced(Binding(get: { model.options }, set: { model.options = $0 }))
                    .disabled(model.busy)
                Label(model.options.crop_mode == .auto ? "9:16 · Automatisk beskæring" : "9:16 · Beskær til midten",
                      systemImage: "aspectratio")
                    .font(.caption.monospaced()).foregroundStyle(palette.secondary)
            }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FadedSectionLabel("Dine videojobs").accessibilityFocused($jobsFocus)
            Picker("Vis jobs", selection: $jobFilter) {
                Text("Alle").tag(0)
                Text("Aktive").tag(1)
                Text("Klar").tag(2)
                Text("Fejl").tag(3)
            }.pickerStyle(.segmented)
            if model.uncertain {
                FadedCard(accent: palette.coral) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Starten blev ikke bekræftet. Tjek joblisten for at se, om dine klip allerede er i gang.")
                        FadedSecondaryButton("Jeg har tjekket listen", icon: "checkmark") {
                            Task { await model.acknowledgeAfterReview() }
                        }.disabled(switchDisabled)
                    }
                }
            }
            if visibleJobs.isEmpty {
                FadedEmptyState(icon: "film", title: "Ingen videoer at vise", detail: "Job vises her, når du starter en video.")
            }
            if let saveVideoNotice { Text(saveVideoNotice).foregroundStyle(palette.secondary) }
            ForEach(visibleJobs.sorted { $0.created_at > $1.created_at }) { job in
                videoJobCard(job)
            }
        }
        .sheet(item: $shareResult) { result in
            ShareLink(item: result.url) {
                Label("Del video", systemImage: "square.and.arrow.up").frame(minHeight: 48)
            }.buttonStyle(FadedButtonStyle(kind: .secondary)).padding()
        }
    }

    private func videoJobCard(_ job: Job) -> some View {
        let progress = job.status == .completed ? 1 : min(1, max(0, job.progress))
        let accent = videoJobAccent(job.status)
        return FadedCard(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                    .font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                Label(job.status.title + " · " + job.mood.title, systemImage: videoJobIcon(job.status))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? accent : palette.text)
                Text(job.message).font(.subheadline).foregroundStyle(palette.secondary)
                if job.status.active || job.status == .completed || job.status == .failed {
                    FadedProgress(value: progress, failed: job.status == .failed)
                }
                if showJobDetails {
                    Text("\(job.id) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospaced()).foregroundStyle(palette.secondary)
                }
                videoJobActions(job)
                if !job.warnings.isEmpty || job.error != nil {
                    DisclosureGroup("Detaljer om jobbet") {
                        ForEach(Array(job.warnings.enumerated()), id: \.offset) { Text($0.element) }
                        if let problem = job.error { Text(problem.message) }
                    }
                }
            }
        }.modifier(FadedJobFeedback(status: job.status))
    }

    private func videoJobAccent(_ status: Stage) -> Color {
        switch status {
        case .completed: palette.green
        case .failed: palette.coral
        case .cancelled: palette.muted
        default: palette.cyan
        }
    }

    private func videoJobIcon(_ status: Stage) -> String {
        switch status {
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        default: "clock"
        }
    }

    @ViewBuilder private func videoJobActions(_ job: Job) -> some View {
        if job.status == .failed {
            FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { Task { await model.retry(job) } }
                .disabled(!model.canRetry(job))
            FadedSecondaryButton("Skjul fejlet job på telefonen", icon: "eye.slash") { hiddenJobs.insert(job.id) }
            if !model.isDemo, let api = model.api as? LiveAPI {
                FadedSecondaryButton("Slet fejlet job fra PC’en", icon: "trash", role: .destructive) {
                    failedJobDeletion = (job.id, api)
                }
            }
        }
        if job.status.active {
            if model.waitingForStop.contains(job.id) {
                Text("Venter på, at jobbet stopper.")
            } else if model.capabilities?.features.cancel == true {
                FadedSecondaryButton(model.cancelling.contains(job.id) ? "Beder PC’en stoppe…" : "Stop job",
                                     icon: "stop.circle") { Task { await model.cancel(job) } }
                    .disabled(model.cancelling.contains(job.id) || model.busy || model.refreshing)
            }
        }
        if job.status == .completed, job.output_url != nil {
            FadedSecondaryButton(model.isDemo ? "Se testvideo" : "Se video", icon: "play") {
                Task {
                    let demo = model.isDemo
                    if let url = await model.video(job) { media = Media(url: url, demo: demo) }
                }
            }.disabled(model.mediaLoading)
            if !model.isDemo {
                FadedSecondaryButton("Gem på telefonen", icon: "square.and.arrow.down") { Task { await saveVideo(job) } }
                    .disabled(model.mediaLoading)
            }
            FadedSecondaryButton("Del job-resultat", icon: "square.and.arrow.up") {
                Task {
                    if let url = await model.video(job) { shareResult = Media(url: url, demo: model.isDemo) }
                }
            }.disabled(model.mediaLoading)
            if !model.isDemo, let api = model.api as? LiveAPI {
                FadedSecondaryButton("Slet redigeret video fra PC’en", icon: "trash", role: .destructive) {
                    pcDeletion = (job.id, api)
                }.disabled(deletingPCVideo || model.mediaLoading)
            }
        }
    }

    @State private var shareResult: Media?

    private var videoFolder: URL { URL.applicationSupportDirectory.appending(path: "SavedVideos", directoryHint: .isDirectory) }

    private func reloadSavedVideos() {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoFolder, includingPropertiesForKeys: nil)) ?? []
        savedVideos = files.filter { $0.pathExtension == "mp4" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func saveVideo(_ job: Job) async {
        saveVideoNotice = nil
        guard let downloaded = await model.video(job) else { return }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        do {
            try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
            let filename = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let target = videoFolder.appendingPathComponent("\(filename)-\(UUID().uuidString.prefix(6)).mp4")
            try FileManager.default.copyItem(at: downloaded, to: target)
            saveVideoNotice = "Videoen er gemt på telefonen."
        } catch { saveVideoNotice = "Videoen kunne ikke gemmes. Tjek ledig plads." }
    }

    private func deletePCVideo(_ id: String, using api: LiveAPI) async {
        guard !deletingPCVideo else { return }
        deletingPCVideo = true
        defer { deletingPCVideo = false }
        do {
            try await api.deletePCVideo(id)
            await model.refresh()
            saveVideoNotice = "Den redigerede video er slettet fra PC’en."
        } catch {
            saveVideoNotice = "PC’en kunne ikke bekræfte sletningen. Opdater joblisten."
        }
    }

    private var savedVideoLibrary: some View {
        NavigationStack {
            List {
                if savedVideos.isEmpty { Text("Gem en færdig video fra Video Studio.") }
                ForEach(savedVideos, id: \.self) { file in
                    NavigationLink {
                        Preview(media: Media(url: file, demo: false))
                    } label: {
                        Label(file.deletingPathExtension().lastPathComponent, systemImage: "film")
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Slet fra telefonen", role: .destructive) { pendingLocalDeletion = file }
                    }
                }
            }.navigationTitle("Gemte videoer")
                .toolbar { Button("Luk") { showSavedVideos = false } }
                .confirmationDialog("Slet den gemte video fra telefonen?", isPresented: Binding(
                    get: { pendingLocalDeletion != nil },
                    set: { if !$0 { pendingLocalDeletion = nil } }
                ), presenting: pendingLocalDeletion) { file in
                    Button("Slet fra telefonen", role: .destructive) {
                        do { try FileManager.default.removeItem(at: file); reloadSavedVideos() }
                        catch { localDeletionError = true }
                        pendingLocalDeletion = nil
                    }
                }
                .alert("Videoen kunne ikke slettes.", isPresented: $localDeletionError) {
                    Button("OK", role: .cancel) {}
                }
        }
    }

    private func advanced(_ options: Binding<Options>) -> some View {
        DisclosureGroup("Avancerede indstillinger") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Beskæring", selection: options.crop_mode) {
                    Text("Automatisk").tag(Crop.auto)
                    Text("Midten").tag(Crop.center)
                }.frame(minHeight: 48)
                Text("Område til tekstlæsning").font(.headline)
                Text("Brug tal fra 0 til 1, målt fra øverste venstre hjørne.")
                coordinate("Fra venstre", options.roi.x)
                coordinate("Fra toppen", options.roi.y)
                coordinate("Bredde", options.roi.width)
                coordinate("Højde", options.roi.height)
                if !model.options.roi.valid {
                    Text("Området skal have en bredde og højde og ligge inden for billedet.")
                }
            }.padding(.top, 12)
        }
    }

    private func coordinate(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            TextField(title, value: value, format: .number.locale(Locale(identifier: "da_DK")))
                .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(FadedTypography.title).tracking(-0.5).accessibilityAddTraits(.isHeader)
    }
    private func action(_ title: String, _ work: @escaping () -> Void) -> some View {
        FadedSecondaryButton(title, action: work)
    }
}


struct VillageBot: Codable, Identifiable {
    var id = UUID()
    var name = ""
    var color = "Blå"
    var prompt = ""
    var voice = "da-DK"
    var sprite: Data? = nil
    var personality: String? = nil
    var notifications: Bool? = true
    var voiceRate: Double? = 1.0
    var language: String? = "da-DK"

    private var playbackVoice: AVSpeechSynthesisVoice? {
        let locale = ["da-DK", "en-US", "en-GB"].contains(voice) ? voice : language ?? "da-DK"
        return LocalSpeechVoice.resolve(identifier: voice, language: locale == "auto" ? "da-DK" : locale)
    }

    var previewSentence: String {
        let trait = personality ?? "Nysgerrig"
        if playbackVoice?.language.hasPrefix("en") == true {
            let englishTrait = ["Nysgerrig": "curious", "Rolig": "calm", "Sjov": "playful", "Omsorgsfuld": "caring"][trait] ?? trait.lowercased()
            return "Hi, I'm \(name.isEmpty ? "your bot" : name). I'm \(englishTrait)."
        }
        return "Hej, jeg er \(name.isEmpty ? "din bot" : name). Jeg er \(trait.lowercased())."
    }

    var voiceDetails: String { playbackVoice.map(LocalSpeechVoice.label) ?? "Systemstemme" }

    var voiceQuality: String {
        switch playbackVoice?.quality {
        case .premium?: "Premium"
        case .enhanced?: "Forbedret"
        case .default?: "Standard"
        default: "Systemstemme"
        }
    }

    func utterance(_ text: String) -> AVSpeechUtterance {
        let result = AVSpeechUtterance(string: text)
        result.voice = playbackVoice
        result.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.3, max(0.7, voiceRate ?? 1)))
        return result
    }
}

private struct VillageBotFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let bot: VillageBot

    init(bot: VillageBot) { self.bot = bot }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        bot = try JSONDecoder().decode(VillageBot.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(bot))
    }
}

struct VillageBotBuilder: View {
    private enum Page: String, CaseIterable {
        case profile = "Profil", voice = "Stemme", test = "Prøv bot"
    }

    let api: LiveAPI?
    private let onBack: (() -> Void)?
    private let fixedProfile: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("village.bots") private var savedBots = Data()
    @AppStorage(PhoneModels.selectionKey) private var phoneModel = "apple"
    @State private var draft: VillageBot
    @State private var voicePreview = AVSpeechSynthesizer()
    @State private var importing = false
    @State private var selectedSprite: PhotosPickerItem?
    @State private var exporting = false
    @State private var exportFile: VillageBotFile?
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var improving = false
    @State private var testTask: Task<Void, Never>?
    @State private var testQuestion = ""
    @State private var testReply = ""
    @State private var generatingSprite = false
    @State private var page = Page.profile

    private var bots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: savedBots)) ?? [] }
    private var testing: Bool { testTask != nil }
    private var testModel: String { PhoneModels.effectiveModelID(phoneModel) }
    private var canTest: Bool { testModel == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(testModel) != nil }

    init(api: LiveAPI? = nil, bot: VillageBot? = nil, onBack: (() -> Void)? = nil) {
        self.api = api
        self.onBack = onBack
        fixedProfile = bot != nil
        _draft = State(initialValue: bot ?? VillageBot())
    }

    var body: some View {
        NavigationStack {
            Form {
                if !fixedProfile {
                    DisclosureGroup("Gemte bots · \(bots.count) af 10") {
                        ForEach(bots) { bot in Button(bot.name) { selectDraft(bot) } }
                        Button("Ny bot") { selectDraft(VillageBot()) }.disabled(bots.count >= 10)
                        Button("Importér JSON") { importing = true }.disabled(bots.count >= 10 || testing)
                    }.listRowBackground(palette.card)
                }
                Group {
                    if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
                    else { pagePicker.pickerStyle(.segmented) }
                }.listRowBackground(palette.card)
                switch page {
                case .profile: editor.disabled(testing).listRowBackground(palette.card)
                case .voice: voiceSettings.disabled(testing).listRowBackground(palette.card)
                case .test: localTest.listRowBackground(palette.card)
                }
                if let notice { Text(notice).listRowBackground(palette.card) }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .tint(palette.isDark ? palette.lime : palette.text)
            .navigationTitle("Botbygger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: close)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Færdig") {
                        if !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save(draft) }
                        close()
                    }.fontWeight(.semibold)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importBot)
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                          defaultFilename: "FadedAI-bot") { result in
                if case .failure = result { notice = "Botten kunne ikke eksporteres." }
            }
            .confirmationDialog("Slet botprofil?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Slet bot", role: .destructive) {
                    persist(bots.filter { $0.id != draft.id })
                    if fixedProfile { close() } else { selectDraft(VillageBot()) }
                }
            } message: {
                Text("Botprofilen fjernes fra telefonen og Landsbyen.")
            }
            .onDisappear { stopPreview() }
        }
    }

    private var pagePicker: some View {
        Picker("Sektion", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    private var editor: some View {
        Section("Botprofil på telefonen") {
            TextField("Navn", text: $draft.name)
            PhotosPicker("Vælg figur fra Fotos", selection: $selectedSprite, matching: .images)
                .onChange(of: selectedSprite) { _, item in
                    guard let item else { return }
                    let id = draft.id
                    Task { await loadSprite(item, botID: id) }
                }
            if let api {
                Button(generatingSprite ? "PC’en tegner figuren…" : "Generér pixelfigur på PC’en") {
                    Task { await generateSprite(api) }
                }
                .disabled(generatingSprite)
            }
            if let data = draft.sprite, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none)
                    .scaledToFill().frame(width: 112, height: 112).clipShape(Circle())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Bottens figur")
                Button("Fjern figur") { draft.sprite = nil }
            }
            Picker("Farve", selection: $draft.color) {
                ForEach(["Blå", "Lilla", "Grøn"], id: \.self) { Text($0) }
            }
            TextField("Systemprompt", text: $draft.prompt, axis: .vertical).lineLimit(3...8)
            Picker("Personlighed", selection: Binding(
                get: { draft.personality ?? "Nysgerrig" },
                set: { draft.personality = $0 }
            )) {
                ForEach(["Nysgerrig", "Rolig", "Sjov", "Omsorgsfuld"], id: \.self) { Text($0) }
            }
            Picker("Sprog", selection: Binding(
                get: { draft.language ?? "da-DK" }, set: { draft.language = $0 }
            )) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk").tag("en-US")
                Text("Automatisk").tag("auto")
            }
            Toggle("Notifikationer fra botten", isOn: Binding(
                get: { draft.notifications ?? true }, set: { draft.notifications = $0 }
            ))
            Button("Forbedr prompt på telefonen") { Task { await improvePrompt() } }
                .disabled(improving || draft.prompt.isEmpty || !PhoneModels.appleAvailable)
            Button("Gem bot") { save(draft) }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if bots.contains(where: { $0.id == draft.id }) {
                Button("Eksportér bot") { exportFile = VillageBotFile(bot: draft); exporting = true }
                FadedSecondaryButton("Slet bot", icon: "trash", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private var voiceSettings: some View {
        Section("Oplæsning på telefonen") {
            Picker("Stemme", selection: $draft.voice) {
                Text("Bedste danske stemme").tag("da-DK")
                Text("Bedste engelske stemme").tag("en-US")
                ForEach(LocalSpeechVoice.options(language: "da-DK") + LocalSpeechVoice.options(language: "en-US"),
                        id: \.identifier) { voice in
                    Text(LocalSpeechVoice.label(voice)).tag(voice.identifier)
                }
            }
            VStack(alignment: .leading) {
                Text("Talehastighed · \((draft.voiceRate ?? 1).formatted(.number.precision(.fractionLength(1))))x")
                Slider(value: Binding(get: { draft.voiceRate ?? 1 }, set: { draft.voiceRate = $0 }),
                       in: 0.7...1.3, step: 0.1)
            }
            FadedSecondaryButton("Prøv stemme", icon: "speaker.wave.2") { speakPreview(draft.previewSentence) }
        }
    }

    private func loadSprite(_ item: PhotosPickerItem, botID: UUID) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let sprite = spriteThumbnail(data),
              draft.id == botID, selectedSprite == item else { return }
        draft.sprite = sprite
        selectedSprite = nil
    }

    private func spriteThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).pngData()
    }

    private func generateSprite(_ api: LiveAPI) async {
        guard !generatingSprite else { return }
        generatingSprite = true
        defer { generatingSprite = false }
        let id = draft.id
        let prompt = "Single friendly full body robot, 2D isometric pixel art sprite, centered with margin, simple solid dark backdrop, no text. Color: \(draft.color). Personality: \(draft.personality ?? "rolig")."
        do {
            let data = try await api.v2GenerateImage(prompt: prompt)
            guard draft.id == id else { return }
            guard let sprite = spriteThumbnail(data) else { throw APIError.malformed }
            draft.sprite = sprite
            notice = "Figuren er klar. Tryk Gem bot for at bruge den i Landsbyen."
        } catch {
            guard draft.id == id else { return }
            notice = "PC’en kunne ikke lave figuren. Kontrollér billedtjenesten, eller vælg et billede fra Fotos."
        }
    }

    private var localTest: some View {
        Section("Prøv AI på denne iPhone") {
            Text(canTest ? "Din valgte telefonmodel er klar." : "Vælg en klar model under Lokale modeller.")
            TextField("Besked til botten", text: $testQuestion, axis: .vertical)
                .disabled(testing)
            FadedPrimaryButton(testing ? "Svarer på telefonen…" : "Prøv på telefonen", icon: "arrow.up") {
                testTask = Task { await testBot() }
            }
            .disabled(testing || !canTest || testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !testReply.isEmpty {
                Label("Telefon", systemImage: "iphone")
                Text(testReply).textSelection(.enabled)
                Button("Læs testsvar op", systemImage: "speaker.wave.2") { speakPreview(testReply) }
                    .frame(minHeight: 44).disabled(testing)
            }
        }
    }

    private func testBot() async {
        let modelID = testModel
        let instructions = OfflineStudio.companionInstructions(for: draft)
        let question = testQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        testReply = ""
        notice = nil
        defer { testTask = nil }
        do {
            try await PhoneModels.reply(modelID: modelID, prompt: question, instructions: instructions) {
                if !Task.isCancelled { testReply = $0 }
            }
        } catch is CancellationError {
        } catch {
            notice = "Telefonen kunne ikke svare. Tjek din valgte lokale model, og prøv igen."
        }
    }

    private func speakPreview(_ text: String) {
        voicePreview.stopSpeaking(at: .immediate)
        voicePreview.speak(draft.utterance(text))
    }

    private func stopPreview() {
        testTask?.cancel()
        voicePreview.stopSpeaking(at: .immediate)
    }

    private func selectDraft(_ bot: VillageBot) {
        stopPreview()
        draft = bot
        page = .profile
        testReply = ""
    }

    private func close() {
        stopPreview()
        if let onBack { onBack() } else { dismiss() }
    }

    private func save(_ bot: VillageBot) {
        var updated = bots
        if let index = updated.firstIndex(where: { $0.id == bot.id }) { updated[index] = bot }
        else {
            guard updated.count < 10 else { notice = "Du kan gemme op til 10 bots."; return }
            updated.append(bot)
        }
        persist(updated)
    }

    private func persist(_ value: [VillageBot]) {
        do { savedBots = try JSONEncoder().encode(value); notice = nil }
        catch { notice = "Botten kunne ikke gemmes." }
    }

    private func importBot(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= 256_000 else { throw CocoaError(.fileReadCorruptFile) }
            var bot = try JSONDecoder().decode(VillageBot.self, from: data)
            guard !bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bot.id = UUID()
            save(bot)
            draft = bot
        } catch { notice = "Filen kunne ikke læses som en FadedAI-bot." }
    }

    private func improvePrompt() async {
        improving = true
        defer { improving = false }
        let original = draft
        var suggestion = ""
        do {
            try await PhoneModels.reply(modelID: "apple", prompt:
                "Omskriv denne idé til en kort systemprompt på dansk. Returnér kun prompten. Idé: " +
                original.prompt) { suggestion = $0 }
            if draft.id == original.id && draft.prompt == original.prompt { draft.prompt = suggestion }
        } catch { notice = "Telefonen kunne ikke forbedre prompten." }
    }
}

private struct VillageBotAvatar: View {
    let bot: VillageBot
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.fadedPalette) private var palette

    private var tint: Color {
        switch bot.color {
        case "Grøn": palette.lime
        case "Lilla": palette.purple
        default: palette.cyan
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.42), palette.raised], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let data = bot.sprite, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
            } else {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.35)) }
        .accessibilityHidden(true)
    }
}

private struct VillageBotLibrary: View {
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let onBack: () -> Void
    @Environment(\.fadedPalette) private var palette
    @AppStorage("village.bots") private var savedBots = Data()
    @State private var showBuilder = false
    @State private var editingBot: VillageBot?
    @State private var chattingBot: VillageBot?

    private var bots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: savedBots)) ?? [] }

    var body: some View {
        NavigationStack {
            List {
                FadedPrimaryButton("Ny bot", icon: "plus") { showBuilder = true }
                    .disabled(bots.count >= 10)
                    .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                if bots.isEmpty {
                    FadedEmptyState(icon: "person.crop.circle.badge.plus", title: "Du har ingen bots endnu",
                                    detail: "Opret din første bot med et navn, en stemme og en personlighed.")
                        .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                ForEach(bots) { bot in
                    NavigationLink {
                        VillageBotProfile(botID: bot.id, api: api, studioUnlocked: $studioUnlocked,
                                          onPrivateSessionEnded: onPrivateSessionEnded)
                    } label: {
                        botRow(bot)
                    }
                    .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { chattingBot = bot } label: { Label("Chat", systemImage: "bubble.left") }.tint(palette.lime)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { editingBot = bot } label: { Label("Redigér", systemImage: "pencil") }.tint(palette.purple)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Mine bots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .sheet(isPresented: $showBuilder) { VillageBotBuilder(api: api, onBack: { showBuilder = false }) }
            .sheet(item: $editingBot) { bot in
                VillageBotBuilder(api: api, bot: bot, onBack: { editingBot = nil })
            }
            .sheet(item: $chattingBot) { bot in
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            }
        }
    }

    private var rowInsets: EdgeInsets { EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16) }

    private func botRow(_ bot: VillageBot) -> some View {
        FadedCard {
            HStack(alignment: .top, spacing: 12) {
                VillageBotAvatar(bot: bot, size: 56, radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot.name).font(.headline)
                    Text(bot.personality ?? "Nysgerrig").font(.subheadline).foregroundStyle(palette.secondary)
                    Text(bot.voiceQuality)
                        .font(.caption.weight(.semibold)).foregroundStyle(palette.text)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(palette.raised, in: .capsule)
                        .accessibilityLabel("Stemme: \(bot.voiceQuality)")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct VillageBotProfile: View {
    let botID: UUID
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @AppStorage("village.bots") private var savedBots = Data()
    @AppStorage(PhoneModels.selectionKey) private var phoneModel = "apple"
    @State private var showBuilder = false
    @State private var showPrivateChat = false
    @State private var showModels = false
    @State private var fullPrompt = false
    @State private var confirmDelete = false
    @State private var testQuestion = ""
    @State private var testReply = ""
    @State private var testTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var speech = AVSpeechSynthesizer()

    private var bot: VillageBot? {
        (try? JSONDecoder().decode([VillageBot].self, from: savedBots))?.first { $0.id == botID }
    }

    private var modelID: String { PhoneModels.effectiveModelID(phoneModel) }
    private var canTest: Bool {
        modelID == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(modelID) != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let bot {
                    hero(bot)
                    voiceCard(bot)
                    personalityCard(bot)
                    testCard(bot)
                    profileActions
                } else {
                    FadedEmptyState(icon: "person.crop.circle.badge.questionmark", title: "Botprofilen findes ikke længere",
                                    detail: "Du kan vælge en anden bot under Mine bots.")
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(palette.coralText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("Botprofil")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { speech.stopSpeaking(at: .immediate); testTask?.cancel() }
        .sheet(isPresented: $showBuilder) {
            if let bot { VillageBotBuilder(api: api, bot: bot, onBack: { showBuilder = false }) }
        }
        .sheet(isPresented: $showModels) { PhoneModelsView() }
        .sheet(isPresented: $showPrivateChat) {
            OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                          initialPage: .chat, initialBotID: botID)
        }
        .confirmationDialog("Slet botprofil?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Slet bot", role: .destructive, action: deleteBot)
        } message: {
            Text("Botprofilen fjernes fra telefonen og Landsbyen.")
        }
    }

    private func hero(_ bot: VillageBot) -> some View {
        VStack(spacing: 10) {
            VillageBotAvatar(bot: bot, size: 120, radius: 28)
            Text(bot.name).font(.largeTitle.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            Text(bot.personality ?? "Nysgerrig")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? palette.purple : palette.text)
                .padding(.horizontal, 12).padding(.vertical, 6).background(palette.raised, in: .capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func voiceCard(_ bot: VillageBot) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Stemme")
                Text(bot.voiceDetails).font(.subheadline).foregroundStyle(palette.secondary)
                FadedSecondaryButton("Prøv stemme", icon: "speaker.wave.2") {
                    speech.stopSpeaking(at: .immediate)
                    speech.speak(bot.utterance(bot.previewSentence))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func personalityCard(_ bot: VillageBot) -> some View {
        FadedCard(accent: palette.purple) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Personlighed")
                if bot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Du kan tilføje en systemprompt under Redigér.").font(.subheadline).foregroundStyle(palette.secondary)
                } else {
                    Text(bot.prompt).font(.body).lineLimit(fullPrompt ? nil : 5).textSelection(.enabled)
                    Button(fullPrompt ? "Vis mindre" : "Vis hele") { fullPrompt.toggle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.isDark ? palette.purple : palette.text).frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func testCard(_ bot: VillageBot) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Prøv personligheden")
                if canTest {
                    testComposer(bot)
                } else {
                    Text("Vælg en klar telefonmodel for at prøve botten.").font(.subheadline).foregroundStyle(palette.secondary)
                    FadedSecondaryButton("Lokale modeller", icon: "iphone") { showModels = true }
                }
                if !testReply.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Svar fra telefonen", systemImage: "iphone")
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.isDark ? palette.cyan : palette.text)
                        Text(testReply).textSelection(.enabled)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: .rect(cornerRadius: 12))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func testComposer(_ bot: VillageBot) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Skriv til botten…", text: $testQuestion, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).padding(12).frame(minHeight: 48)
                .background(palette.raised, in: .rect(cornerRadius: 12))
                .disabled(testTask != nil)
            if let testTask {
                FadedSecondaryButton("Stop", icon: "stop.fill") { testTask.cancel() }
            } else {
                Button { startTest(bot) } label: { Image(systemName: "arrow.up").frame(minWidth: 24) }
                    .buttonStyle(FadedButtonStyle(kind: .primary))
                    .disabled(testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send testbesked")
            }
        }
    }

    private var profileActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedSecondaryButton("Chat med botten", icon: "lock.shield") {
                speech.stopSpeaking(at: .immediate)
                showPrivateChat = true
            }
            FadedSecondaryButton("Redigér", icon: "pencil") {
                speech.stopSpeaking(at: .immediate)
                showBuilder = true
            }
            FadedSecondaryButton("Slet bot", icon: "trash", role: .destructive) { confirmDelete = true }
        }.frame(maxWidth: .infinity, alignment: .leading).disabled(testTask != nil)
    }

    private func startTest(_ bot: VillageBot) {
        let question = testQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canTest, !question.isEmpty, testTask == nil else { return }
        let selectedModel = modelID
        testReply = ""
        notice = nil
        testTask = Task {
            defer { testTask = nil }
            do {
                try await PhoneModels.reply(modelID: selectedModel, prompt: question,
                                            instructions: OfflineStudio.companionInstructions(for: bot)) {
                    if !Task.isCancelled { testReply = $0 }
                }
            } catch is CancellationError {
                return
            } catch {
                notice = "Telefonen kunne ikke svare. Tjek din lokale model, og prøv igen."
            }
        }
    }

    private func deleteBot() {
        guard let bots = try? JSONDecoder().decode([VillageBot].self, from: savedBots),
              let remaining = try? JSONEncoder().encode(bots.filter { $0.id != botID }) else {
            notice = "Botprofilen kunne ikke slettes."
            return
        }
        savedBots = remaining
        dismiss()
    }
}

private struct AgentHub: View {
    @Environment(\.scenePhase) private var hubPhase
    @Environment(\.fadedPalette) private var palette
    let api: LiveAPI?
    let isVisible: Bool
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let onBack: () -> Void
    @State private var selectedRoom = "research"
    @AppStorage("village.bots") private var localBotsData = Data()
    @State private var localBot: VillageBot?
    @State private var villageChatBot: VillageBot?
    @State private var villagePause = false
    @State private var cinematic = false
    @State private var villageZoom: CGFloat = 1
    @State private var villageOffset: CGSize = .zero
    @State private var showBuilder = false
    @State private var offline = false
    @State private var completions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("qol.reduceMotion") private var calmMotion = false
    @State private var details: V2Hub.Agent?
    @State private var achievements = false

    @State private var snapshot: V2Hub?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var history: [V2History] = []
    @State private var memory: [V2Memory] = []
    @State private var badges: [V2Achievements.Item] = []
    @State private var detailError: String?
    @State private var badgeError: String?
    @State private var detailsLoading = false
    @State private var badgesLoading = false

    private struct VillagePiece: Identifiable {
        enum Kind {
            case building(Int)
            case agent(V2Hub.Agent)
            case bot(VillageBot, routine: Int, sleeping: Bool)
        }

        let id: String
        let kind: Kind
        let zone: Int
        let point: CGPoint
        let depth: CGFloat
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                hubContent
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
            .task(id: "\(attempt):\(hubPhase == .active):\(api?.server.origin.absoluteString ?? "offline")") {
                if hubPhase == .active { await followHub() }
            }
            .refreshable { attempt += 1 }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .sheet(item: $details) { agent in agentDetails(agent) }
            .sheet(isPresented: $achievements) { achievementPage }
        }
    }

    private var hubContent: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.action) {
            if !cinematic {
                FadedSignature()
                Text("Agent-Hub").font(FadedTypography.title).accessibilityAddTraits(.isHeader)
            }
            village
            if !cinematic {
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
        FadedSectionLabel("PC-agenter")
        if let failure {
            RetryNotice(message: failure) { attempt += 1 }
        }
        if let snapshot {
            missionHUD(snapshot.summary)
            if !snapshot.rooms.isEmpty {
                Picker("Rum", selection: $selectedRoom) {
                    ForEach(snapshot.rooms) { room in Text(room.name).tag(room.id) }
                }.frame(minHeight: 48)
            }
            ForEach(snapshot.agents.filter { $0.room_id == selectedRoom }) { agent in
                agentCard(agent)
            }
            FadedSecondaryButton("Achievements", icon: "trophy") { achievements = true }
        } else if failure == nil {
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

    private var villageVisible: Bool { isVisible && hubPhase == .active }
    private var villageMotionEnabled: Bool { villageVisible && !reduceMotion && !calmMotion }

    private var village: some View {
        Group {
            if villageVisible {
                TimelineView(.periodic(from: .now, by: villageMotionEnabled ? 0.25 : 60)) { timeline in
                    villageScene(at: timeline.date)
                }
            } else {
                villageScene(at: .now)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(cinematic ? "Vis menu" : "Filmtilstand", systemImage: cinematic ? "eye" : "video") {
                cinematic.toggle()
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(cinematic ? "Afslut filmtilstand" : "Start filmtilstand")
            .frame(minWidth: 48, minHeight: 48)
            .foregroundStyle(.white)
            .background(.black.opacity(0.74), in: Circle())
            .padding(8)
        }
    }

    private func villageScene(at date: Date) -> some View {
        let hour = Calendar.current.component(.hour, from: date)
        let night = hour < 7 || hour >= 20
        let shape = RoundedRectangle(cornerRadius: FadedRadius.media)
        return GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [night ? FadedColors.sunset : villageGround(night: false), FadedColors.deep],
                               startPoint: .top, endPoint: .bottom)
                villageTerrain(night: night)
                ForEach(villagePieces(hour: hour, time: date.timeIntervalSinceReferenceDate, size: geometry.size)) { piece in
                    villagePiece(piece, night: night)
                        .zIndex(Double(piece.depth))
                        .animation(villageMotionEnabled ? .easeInOut(duration: 0.75) : nil, value: piece.zone)
                }
            }
            .overlay { if offline { villageRain(at: date) } }
            .scaleEffect(villageZoom)
            .offset(villageOffset)
            .gesture(MagnifyGesture().onChanged { villageZoom = min(2, max(1, $0.magnification)) })
            .simultaneousGesture(DragGesture().onChanged { villageOffset = $0.translation })
            .foregroundStyle(FadedColors.text)
            .clipShape(shape)
        }
        .frame(height: 420)
        .overlay { shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .topLeading) {
            if !cinematic {
                Label(night ? "Nat" : "Dag", systemImage: night ? "moon.stars.fill" : "sun.max.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(FadedColors.text)
                    .padding(8).background(.black.opacity(0.74), in: Capsule()).padding(8)
            }
        }
    }

    private func villageTerrain(night: Bool) -> some View {
        Canvas { context, size in
            var tiles = Path()
            let step: CGFloat = 16
            for row in 0..<Int(size.height / step) {
                for column in 0..<Int(size.width / (2 * step)) where (row * 7 + column * 11) % 5 == 0 {
                    let x = CGFloat(column) * 2 * step + (row.isMultiple(of: 2) ? 0 : step)
                    let y = CGFloat(row) * step
                    tiles.move(to: CGPoint(x: x, y: y - step / 2))
                    tiles.addLine(to: CGPoint(x: x + step, y: y))
                    tiles.addLine(to: CGPoint(x: x, y: y + step / 2))
                    tiles.addLine(to: CGPoint(x: x - step, y: y))
                    tiles.closeSubpath()
                }
            }
            context.fill(tiles, with: .color(FadedColors.daylightWindow.opacity(night ? 0.07 : 0.12)))

            let plaza = CGPoint(x: size.width / 2, y: size.height * 0.57)
            let trails = Path { path in
                for zone in 0..<4 {
                    let room = villagePoint(zone, size: size)
                    path.move(to: CGPoint(x: room.x, y: room.y + 44))
                    path.addLine(to: CGPoint(x: (room.x + plaza.x) / 2, y: (room.y + plaza.y) / 2 + 24))
                    path.addLine(to: plaza)
                }
            }
            context.stroke(trails, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 19, lineCap: .round, lineJoin: .round))
            context.stroke(trails, with: .color(FadedColors.daylightWindow.opacity(night ? 0.22 : 0.38)),
                           style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))

            var trunks = Path()
            var leaves = Path()
            for tree in 0..<12 {
                let x = size.width * (0.08 + Double((tree * 31) % 83) / 100)
                let y = size.height * (0.11 + Double((tree * 47) % 75) / 100)
                trunks.addRect(CGRect(x: x + 4, y: y + 6, width: 4, height: 9))
                leaves.addRect(CGRect(x: x, y: y + 2, width: 13, height: 8))
                leaves.addRect(CGRect(x: x + 2, y: y, width: 9, height: 2))
            }
            context.fill(trunks, with: .color(FadedColors.daylightWindow.opacity(0.46)))
            context.fill(leaves, with: .color(palette.green.opacity(night ? 0.32 : 0.50)))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    private var localVillageBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: localBotsData)) ?? []
    }

    private func villageGround(night: Bool) -> Color {
        night ? FadedColors.sunset : Color(red: 0.28, green: 0.18, blue: 0.12)
    }

    private func villageRain(at date: Date) -> some View {
        Canvas { context, size in
            let phase = villageMotionEnabled ? Int(date.timeIntervalSince1970 * 24) % 100 : 0
            for drop in 0..<30 {
                let x = size.width * Double((drop * 37) % 100) / 100
                let y = size.height * Double((drop * 61 + phase) % 100) / 100
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x - 4, y: y + 10))
                }
                context.stroke(line, with: .color(.cyan.opacity(0.45)), lineWidth: 1)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func villageBuilding(_ zone: Int, center: CGPoint, night: Bool) -> some View {
        let names = ["Research Lab", "Video Studio", "Kaffeområde", "Sovekrog"]
        let symbols = ["books.vertical.fill", "film.fill", "cup.and.saucer.fill", "moon.stars.fill"]
        let colors = [palette.coral, palette.lime, palette.coral, palette.lime]
        let color = colors[zone]
        return ZStack {
            Canvas { context, _ in
                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x, y: center.y + y) }
                func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Path {
                    Path { path in
                        path.move(to: a)
                        path.addLine(to: b)
                        path.addLine(to: c)
                        path.addLine(to: d)
                        path.closeSubpath()
                    }
                }
                func diamond(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> Path {
                    quad(point(x, y - height / 2), point(x + width / 2, y),
                         point(x, y + height / 2), point(x - width / 2, y))
                }
                let west = quad(point(-57, -28), point(0, 1), point(0, 47), point(-57, 18))
                let east = quad(point(0, 1), point(57, -28), point(57, 18), point(0, 47))
                let roof = diamond(0, -29, width: 132, height: 66)
                context.fill(diamond(10, 41, width: 154, height: 86), with: .color(.black.opacity(0.34)))
                context.fill(diamond(0, 22, width: 148, height: 80),
                             with: .color(night ? Color(red: 0.22, green: 0.16, blue: 0.12) : Color(red: 0.39, green: 0.28, blue: 0.19)))
                // Back the tinted faces with opaque color so a sprite behind a wall cannot show through it.
                for face in [west, east, roof] { context.fill(face, with: .color(villageGround(night: night))) }
                context.fill(west, with: .color(color.opacity(night ? 0.28 : 0.46)))
                context.fill(east, with: .color(color.opacity(night ? 0.18 : 0.28)))
                context.fill(roof, with: .color(color.opacity(night ? 0.64 : 0.82)))
                context.stroke(roof, with: .color(FadedColors.text.opacity(0.36)), lineWidth: 1.5)
                context.fill(quad(point(-13, 13), point(0, 20), point(0, 45), point(-13, 38)),
                             with: .color(.black.opacity(0.56)))
                let window = quad(point(17, 17), point(34, 8), point(34, 22), point(17, 31))
                if night { context.stroke(window, with: .color(FadedColors.daylightWindow.opacity(0.22)), lineWidth: 5) }
                context.fill(window, with: .color(FadedColors.daylightWindow.opacity(night ? 0.95 : 0.53)))
            }.accessibilityHidden(true)
            Label(names[zone], systemImage: symbols[zone])
                .font(.caption2.bold()).labelStyle(.titleAndIcon)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.black.opacity(0.72), in: Capsule())
                .position(x: center.x, y: center.y + 25)
        }.allowsHitTesting(false)
    }

    private func villagePieces(hour: Int, time: TimeInterval, size: CGSize) -> [VillagePiece] {
        var pieces = (0..<4).map { zone in
            let point = villagePoint(zone, size: size)
            return VillagePiece(id: "building-\(zone)", kind: .building(zone), zone: zone, point: point,
                                depth: point.y + 47)
        }
        var agentSlots = [0, 0, 0, 0]
        for (index, agent) in (snapshot?.agents ?? []).enumerated() {
            let sleeping = offline || agent.status == .offline
            let zone = sleeping ? 3 : agent.status == .ready ? 2 : agent.room_id.lowercased().contains("video") ? 1 : 0
            let phase = villageMotionEnabled && !sleeping ? time * 0.55 + Double(index) : nil
            let foot = villageFoot(zone, slot: agentSlots[zone], local: false, phase: phase, size: size)
            pieces.append(VillagePiece(id: "agent-\(agent.id)", kind: .agent(agent), zone: zone, point: foot,
                                       depth: foot.y))
            agentSlots[zone] += 1
        }
        var botSlots = [0, 0, 0, 0]
        let sleeping = villageBotsSleep(hour: hour)
        for (index, bot) in localVillageBots.enumerated() {
            let routine = (hour + index) % 3
            let zone = sleeping ? 3 : routine
            let phase = villageMotionEnabled && !sleeping ? time * 0.7 + Double(index) : nil
            let foot = villageFoot(zone, slot: botSlots[zone], local: true, phase: phase, size: size)
            pieces.append(VillagePiece(id: "bot-\(bot.id)", kind: .bot(bot, routine: routine, sleeping: sleeping),
                                       zone: zone, point: foot, depth: foot.y))
            botSlots[zone] += 1
        }
        return pieces
    }

    @ViewBuilder private func villagePiece(_ piece: VillagePiece, night: Bool) -> some View {
        switch piece.kind {
        case .building(let zone):
            villageBuilding(zone, center: piece.point, night: night)
        case .agent(let agent):
            villageAvatar(agent).position(x: piece.point.x, y: piece.point.y - 21)
        case .bot(let bot, let routine, let sleeping):
            localVillageAvatar(bot, routine: routine, sleeping: sleeping)
                .position(x: piece.point.x, y: piece.point.y - 5)
        }
    }

    private func villageBotsSleep(hour: Int) -> Bool { offline || villagePause || hour < 7 || hour >= 22 }

    private func botActivity(_ bot: VillageBot, routine: Int, sleeping: Bool) -> String {
        guard !sleeping else { return "Sover" }
        let routines: [String] = switch bot.personality ?? "Nysgerrig" {
        case "Rolig": ["Læser i biblioteket", "Ordner studiet", "Drikker te"]
        case "Sjov": ["Finder på historier", "Øver en scene", "Fortæller jokes"]
        case "Omsorgsfuld": ["Hjælper i laboratoriet", "Hjælper med video", "Laver kaffe til holdet"]
        default: ["Undersøger nye idéer", "Øver sig i studiet", "Holder kaffepause"]
        }
        return routines[routine]
    }

    private func localVillageAvatar(_ bot: VillageBot, routine: Int, sleeping: Bool) -> some View {
        let activity = botActivity(bot, routine: routine, sleeping: sleeping)
        let color = bot.color == "Grøn" ? palette.green : bot.color == "Lilla" ? palette.purple : palette.cyan
        return Button {
            if !cinematic { localBot = bot }
        } label: {
            VStack(spacing: 0) {
                Group {
                if let data = bot.sprite, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(systemName: sleeping ? "moon.stars.fill" : "sparkle").foregroundStyle(color)
                }
                }.frame(width: 38, height: 38, alignment: .bottom).opacity(sleeping ? 0.55 : 1)
                Text(bot.name).font(.caption2.bold()).lineLimit(1)
                if !sleeping { Text(activity).font(.system(size: 8)).lineLimit(1) }
            }.frame(width: 92, height: 66, alignment: .top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.name + ", " + (bot.personality ?? "Nysgerrig") + ", " + activity)
    }

    private func villagePoint(_ zone: Int, size: CGSize) -> CGPoint {
        let rooms = [CGPoint(x: -0.67, y: -0.21), CGPoint(x: -0.03, y: -0.49),
                     CGPoint(x: 0.07, y: 0.53), CGPoint(x: 0.71, y: 0.25)]
        return isometric(rooms[zone], origin: CGPoint(x: size.width / 2, y: size.height / 2),
                         halfTile: CGSize(width: size.width / 2, height: size.height / 4))
    }

    private func isometric(_ tile: CGPoint, origin: CGPoint, halfTile: CGSize) -> CGPoint {
        CGPoint(x: origin.x + (tile.x - tile.y) * halfTile.width,
                y: origin.y + (tile.x + tile.y) * halfTile.height)
    }

    private func villageFoot(_ zone: Int, slot: Int, local: Bool, phase: Double?, size: CGSize) -> CGPoint {
        let columns = local ? 5 : 4
        let lane = (CGFloat(slot % columns) - CGFloat(columns - 1) / 2) * (local ? 0.34 : 0.43)
        let row = CGFloat(slot / columns)
        let front = (local ? 2.25 : 1.63) + row * 0.42
        let wanderX = phase.map { CGFloat(sin($0)) * 0.32 } ?? 0
        let wanderY = phase.map { CGFloat(cos($0)) * 0.32 } ?? 0
        let tile = CGPoint(x: front + lane + wanderX, y: front - lane + wanderY)
        let foot = isometric(tile, origin: villagePoint(zone, size: size), halfTile: CGSize(width: 32, height: 16))
        let margin: CGFloat = local ? 46 : 22
        return CGPoint(x: min(max(margin, foot.x), max(margin, size.width - margin)),
                       y: min(foot.y, size.height - (local ? 20 : 5)))
    }

    private func villageAvatar(_ agent: V2Hub.Agent) -> some View {
        let sleeping = offline || agent.status == .offline
        let resting = agent.status == .ready
        let matchingSprite = localVillageBots.first {
            $0.name.localizedCaseInsensitiveCompare(agent.name) == .orderedSame ||
            $0.name.localizedCaseInsensitiveCompare(agent.id) == .orderedSame
        }?.sprite
        return Button {
            if !cinematic { details = agent }
        } label: {
            Group {
                if let matchingSprite, let image = UIImage(data: matchingSprite) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(systemName: sleeping ? "moon.zzz.fill" : icon(agent.icon)).font(.title2)
                }
            }
            .frame(width: 42, height: 42, alignment: .bottom)
            .opacity(sleeping ? 0.55 : 1)
            .modifier(AgentPulse(active: villageMotionEnabled && !sleeping && !resting))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name + ", " + (sleeping ? "Hviler" : status(agent.status)))
        .contextMenu {
            if !cinematic {
                Button("Vis historik og hukommelse") { details = agent }
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
        NavigationStack {
            List {
                if detailsLoading { LoadingSkeleton(label: "Henter agentdetaljer…") }
                if let detailError { RetryNotice(message: detailError) { Task { await loadDetails(agent.id) } } }
                Section("Status") { Text("\(status(agent.status)) · \(agent.xp) XP") }
                Section("Historik") {
                    if history.isEmpty && !detailsLoading { Text("Ingen historik at vise.") }
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
                    if tools.isEmpty && !detailsLoading { Text("Ingen værktøjskald at vise.") }
                    ForEach(tools) { item in Text(item.tool_name ?? item.title) }
                }
                Section("Hukommelse") {
                    if memory.isEmpty && !detailsLoading { Text("Ingen hukommelse at vise.") }
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
        var delay = 2
        while !Task.isCancelled {
            do {
                let initial = try await api.v2Hub()
                try Task.checkCancellation()
                apply(initial)
                failure = nil
                delay = 2
                try await api.v2HubEvents(after: initial.revision) { event in
                    guard let updated = try? await api.v2Hub() else { return }
                    await MainActor.run {
                        if !Task.isCancelled, event.type == .resync_required || updated.revision >= (snapshot?.revision ?? 0) {
                            apply(updated)
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let networkError = error as? URLError {
                    offline = [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
                               .timedOut, .cannotFindHost].contains(networkError.code)
                }
                failure = "Kunne ikke hente Agent-Hub. Tjek forbindelsen til PC’en."
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            delay = min(delay * 2, 30)
        }
    }

    private func apply(_ value: V2Hub) {
        if let snapshot {
            let previous = Set(snapshot.agents.flatMap(\.recent_quests).filter { $0.state == .completed }.map(\.id))
            let next = Set(value.agents.flatMap(\.recent_quests).filter { $0.state == .completed }.map(\.id))
            if !next.subtracting(previous).isEmpty { completions += 1 }
        }
        offline = false
        snapshot = value
        if !value.rooms.contains(where: { $0.id == selectedRoom }) {
            selectedRoom = value.rooms.first?.id ?? ""
        }
    }

    private func loadDetails(_ id: String) async {
        guard let api else { return }
        history = []; memory = []; detailError = nil; detailsLoading = true
        defer { detailsLoading = false }
        do {
            async let historyPage = api.v2History(agentID: id)
            async let memoryPage = api.v2Memory(agentID: id)
            let (h, m) = try await (historyPage, memoryPage)
            try Task.checkCancellation()
            history = h.items; memory = m.items
        } catch {
            if !Task.isCancelled { detailError = "Kunne ikke hente agentens detaljer." }
        }
    }

    private func loadBadges() async {
        guard let api else { return }
        badgeError = nil; badgesLoading = true
        defer { badgesLoading = false }
        do { badges = try await api.v2Achievements().items }
        catch { if !Task.isCancelled { badgeError = "Kunne ikke hente achievements." } }
    }

    private func icon(_ value: String) -> String {
        value == "search" ? "magnifyingglass" : value
    }

    private func status(_ value: V2Hub.Agent.Status) -> String {
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

private struct Preview: View {
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var player: AVPlayer?
    @State private var invalid = false
    @State private var audioReady = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(media.demo ? "Testvideo · Demo" : "Din video")
                    .font(.title.bold()).accessibilityAddTraits(.isHeader)
                Button("Luk") { dismiss() }.frame(minHeight: 48)
                if invalid { Text("Videoen kan ikke afspilles på telefonen.") }
                else if let player {
                    VideoPlayer(player: player).aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 540).accessibilityLabel("Videoafspiller")
                    if !audioReady { Text("Lydudgangen kunne ikke aktiveres. Prøv igen.") }
                    Button("Afspil fra starten") {
                        activateAudio()
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                            if completed { player.play() }
                        }
                    }.frame(minHeight: 48)
                    ShareLink(item: media.url) { Text("Del video").frame(minHeight: 48) }
                        .buttonStyle(.bordered)
                } else { ProgressView("Åbner video…") }
            }.padding(20)
        }.task {
            let asset = AVURLAsset(url: media.url)
            do {
                guard try await asset.load(.isPlayable) else { invalid = true; return }
                try Task.checkCancellation()
                let preview = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                preview.isMuted = false
                preview.volume = 1
                player = preview
                activateAudio()
            } catch { if !Task.isCancelled { invalid = true } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notice in
            guard let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { player?.pause(); audioReady = false }
            if type == .ended { activateAudio() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notice in
            if notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ==
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            audioReady = true
        } catch { audioReady = false }
    }
}

private struct ChatTurn: Identifiable, Codable {
    var id = UUID()
    let prompt: String
    var reply = ""
    var notice: String?
    var source: String?
    var favorite: Bool?
    var createdAt: Date?
    var feedback: Int?
}

private struct LoadingSkeleton: View {
    let label: String
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @AppStorage("qol.reduceMotion") private var calmMotion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline)
            let paused = reduceMotion || phase != .active
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
                let speed: Double = calmMotion ? 2 : 4
                let opacity = paused ? 0.22 : 0.22 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * speed)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([1.0, 0.72, 0.48], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.secondary.opacity(opacity))
                            .frame(height: 12)
                            .scaleEffect(x: width, y: 1, anchor: .leading)
                    }
                }.accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct RetryNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
            FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise", action: retry)
        }
    }
}

private struct AgentPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fadedPalette) private var palette

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || reduceMotion)) { context in
            let intensity = active && !reduceMotion
                ? 0.18 + 0.12 * sin(context.date.timeIntervalSinceReferenceDate * 2)
                : 0.0
            content.overlay {
                RoundedRectangle(cornerRadius: FadedRadius.media).strokeBorder(palette.cyan.opacity(intensity), lineWidth: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

private struct StatsBar: View {
    let turns: Int
    let streaming: Bool

    var body: some View {
        Text(streaming ? "\(turns) beskeder · Modtager svar" : "\(turns) beskeder")
            .font(.caption)
    }
}

private struct ChatTranscriptView: View {
    let reply: String

    var body: some View {
        let blocks = reply.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                if index.isMultiple(of: 2) {
                    if let formatted = try? AttributedString(markdown: blocks[index],
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(formatted)
                    } else { Text(blocks[index]) }
                } else {
                    let lines = blocks[index].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    ScrollView(.horizontal) {
                        Text(highlight(lines.count == 2 ? String(lines[1]) : blocks[index]))
                            .font(.system(.body, design: .monospaced)).padding(8)
                    }.background(.secondary.opacity(0.10))
                }
            }
        }.textSelection(.enabled)
    }

    private func highlight(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        let words = ["let", "var", "func", "return", "if", "else", "for", "import", "class", "def", "async", "await"]
        for word in words {
            var cursor = code.startIndex
            while let match = code.range(of: "\\b" + word + "\\b", options: .regularExpression,
                                         range: cursor..<code.endIndex),
                  let range = Range(match, in: result) {
                result[range].foregroundColor = .purple
                cursor = match.upperBound
            }
        }
        return result
    }
}


@MainActor @Observable private final class ChatDictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var sessionActive = false
    private var runID = UUID()
    private(set) var active = false
    private(set) var problem: String?

    func start(update: @escaping (String) -> Void) async {
        guard !active else { return }
        let id = UUID()
        runID = id
        active = true
        problem = nil
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard runID == id else { return }
        guard speechAllowed, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "da-DK")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("Dansk diktering på telefonen er ikke tilgængelig. Tjek talegenkendelse i Indstillinger.")
            return
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard runID == id else { return }
        guard micAllowed else {
            fail("Giv FadedAI adgang til mikrofonen i Indstillinger.")
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            sessionActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            self.recognizer = recognizer
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                fail("Mikrofonen er ikke klar.")
                return
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let done = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
                    if let text { update(text) }
                    if done { self.stop() }
                    else if failed { self.fail("Dikteringen stoppede. Du kan prøve igen.") }
                }
            }
            try engine.start()
        } catch { fail("Mikrofonen kunne ikke startes.") }
    }

    func stop() {
        runID = UUID()
        active = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }
}

private struct SavedAgentSession: Codable {
    let id: UUID
    let turns: [ChatTurn]
    let toolSteps: [String]
    let pending: Bool
}

private enum ChatArchive {
    static let key = "spaces.chat.archive.v1"

    static func append(_ session: SavedAgentSession) {
        guard !session.turns.isEmpty else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedAgentSession].self, from: $0) } ?? []
        let updated = [session] + saved.filter { $0.id != session.id }
        if let data = try? JSONEncoder().encode(Array(updated.prefix(100))) { defaults.set(data, forKey: key) }
    }

    static func turns() -> [ChatTurn] {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var found = defaults.data(forKey: key).flatMap { try? decoder.decode([SavedAgentSession].self, from: $0) }?.flatMap(\.turns) ?? []
        for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix("spaces.chat.") && name != key {
            guard let data = value as? Data else { continue }
            if let session = try? decoder.decode(SavedAgentSession.self, from: data) { found += session.turns }
            else if let legacy = try? decoder.decode([ChatTurn].self, from: data) { found += legacy }
        }
        var seen = Set<UUID>()
        return found.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .filter { seen.insert($0.id).inserted }
    }
}

private struct AgentToolWave: View {
    let status: String
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("qol.reduceMotion") private var calmMotion = false

    var body: some View {
        let paused = reduceMotion || calmMotion || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
            let time = paused ? 0 : context.date.timeIntervalSinceReferenceDate * 6
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule().fill(palette.lime).frame(width: 3, height: 6 + CGFloat(abs(sin(time + Double(index) * 0.8))) * 12)
                }
            }.frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
    }
}

private struct ModuleTabView: View {
    let tab: ModuleTab
    let api: LiveAPI
    let onBack: () -> Void
    @State private var cards: [ModuleCards.Card] = []
    @State private var information: String?
    @State private var importing = false
    @State private var confirmImport = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                if let notice { Text(notice) }
                if busy { ProgressView("Opdaterer") }
                if tab.kind == "cards" {
                    Button("Importér Kortscanner-fil", systemImage: "square.and.arrow.down") {
                        confirmImport = true
                    }.frame(minHeight: 44).disabled(busy)
                    if cards.isEmpty && !busy { Text("Ingen kort endnu.") }
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.headline)
                            Text([card.set, card.number, card.language].filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                            if let price = card.price { Text(price, format: .currency(code: "DKK")) }
                        }
                    }
                } else if let information {
                    Text(verbatim: information)
                }
                if notice != nil {
                    Button("Prøv igen") { Task { await load() } }.frame(minHeight: 44).disabled(busy)
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle(tab.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog("Erstat samlingen på PC’en?", isPresented: $confirmImport) {
                Button("Vælg JSON-fil") { importing = true }
            } message: { Text("Den valgte fil sendes til din FadedAI-PC og erstatter den tidligere import.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case let .success(url) = result else { return }
                Task { await load(file: url) }
            }
        }
    }

    private func load(file: URL? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let file {
                let granted = file.startAccessingSecurityScopedResource()
                defer { if granted { file.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_000_001) ?? Data()
                guard !data.isEmpty && data.count <= 1_000_000 else { throw APIError.input }
                cards = try await api.moduleCards(tab.id, upload: data).cards
            } else if tab.kind == "cards" {
                cards = try await api.moduleCards(tab.id).cards
            } else {
                information = try await api.moduleInformation(tab.id).text
            }
            notice = nil
        } catch {
            notice = file == nil ? "Fanen kunne ikke hentes fra PC’en." : "Importen mislykkedes. Vælg en gyldig Kortscanner-fil på højst 1 MB."
        }
    }
}

private struct BatchReviewView: View {
    let api: LiveAPI
    @State private var jobs: [CodeBatchList.Job] = []
    @State private var repo = ""
    @State private var goal = ""
    @State private var paths = ""
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Ny opgave") {
                TextField("Repo (ejer/projekt)", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Klon GitHub-repo til PC’en") { Task { await clone() } }
                    .disabled(busy || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                TextField("Hvad skal ændres?", text: $goal, axis: .vertical)
                TextField("Op til fem filstier, én pr. linje", text: $paths, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                FadedPrimaryButton("Sæt i kø", icon: "terminal") { Task { await enqueue() } }
                    .disabled(busy || repo.isEmpty || goal.isEmpty || paths.isEmpty)
                if busy || repo.isEmpty || goal.isEmpty || paths.isEmpty {
                    Text(busy ? "Vent på PC’en." : "Udfyld repo, opgave og filstier.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Kodejob") {
                if let failure { Text(failure) }
                Button("Opdatér liste") { Task { await reload() } }
                ForEach(jobs) { job in
                    NavigationLink {
                        BatchProposalView(api: api, id: job.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.goal)
                            Text(batchStatus(job.status)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Forslag til flere filer")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do { jobs = try await api.codeBatches().jobs; failure = nil }
        catch { failure = pcBusyMessage(error) ?? "Kodekøen kunne ikke hentes. Kontrollér forbindelsen til PC’en." }
    }

    private func enqueue() async {
        busy = true
        defer { busy = false }
        let files = paths.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try await api.enqueueCodeBatch(repo: repo.trimmingCharacters(in: .whitespaces), goal: goal, files: files)
            goal = ""
            await reload()
        } catch { failure = pcBusyMessage(error) ?? "Opgaven kunne ikke sættes i kø. Tjek repo og filstier." }
    }

    private func clone() async {
        busy = true
        defer { busy = false }
        do {
            try await api.cloneCodeRepository(repo.trimmingCharacters(in: .whitespaces))
            failure = nil
        } catch { failure = pcBusyMessage(error) ?? "Repoet kunne ikke klones. Tjek navnet og PC’ens adgang til GitHub." }
    }
}

private func batchStatus(_ status: String) -> String {
    switch status {
    case "queued": "I kø"
    case "running": "Arbejder"
    case "review": "Afventer godkendelse"
    case "applied": "Gemt på lokal gren"
    case "declined": "Intet forslag"
    default: "Jobbet stoppede"
    }
}

private struct BatchProposalView: View {
    let api: LiveAPI
    let id: String
    @State private var detail: CodeBatchDetail?
    @State private var confirm = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        List {
            if let detail { Text(batchStatus(detail.status)) }
            if let notice { Text(notice) }
            if let reason = detail?.result?.reason { Text(verbatim: reason) }
            if let diff = detail?.result?.diff {
                Section("Ændringer") {
                    FadedDiff(diff: diff)
                }
            }
            if let tests = detail?.result?.tests {
                Section("Testplan") {
                    ForEach(Array(tests.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let checks = detail?.result?.checks, !checks.isEmpty {
                Section("Kontroller kørt på PC’en") {
                    ForEach(Array(checks.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let branch = detail?.result?.branch { Text(verbatim: branch).textSelection(.enabled) }
            if detail?.status == "review" {
                FadedPrimaryButton("Godkend ændringer", icon: "checkmark") { confirm = true }.disabled(busy)
                if busy { Text("Vent på PC’en.").font(.caption).foregroundStyle(.secondary) }
            }
            Button("Opdatér") { Task { await reload() } }.disabled(busy)
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Gennemgå forslag")
        .task { await reload() }
        .confirmationDialog("Godkend ændringerne?", isPresented: $confirm) {
            Button("Opret lokal Git-gren") { Task { await approve() } }
        } message: { Text("Forslaget gemmes på en separat gren i Agent Workspace på PC’en.") }
    }

    private func reload() async {
        do { detail = try await api.codeBatch(id); notice = nil }
        catch { notice = "Forslaget kunne ikke hentes." }
    }

    private func approve() async {
        busy = true
        defer { busy = false }
        do {
            let applied = try await api.approveCodeBatch(id)
            await reload()
            if let branch = applied.branch { notice = "Ændringerne er gemt på \(branch)." }
        } catch { notice = "PC’en kunne ikke bekræfte godkendelsen. Opdatér for at se den aktuelle status." }
    }
}

private struct CodeWorkspaceView: View {
    @Environment(\.fadedPalette) private var palette

    private struct FeatureDraft: Decodable {
        let feasible: Bool
        let reason: String
        let diff: String?
        let tests: [String]
    }
    private struct GeneratedProposal {
        let original: String?
        let revised: String
    }
    @MainActor private final class DraftStream {
        var text = ""
        var overflowed = false

        func append(_ part: String) {
            guard !overflowed else { return }
            if text.utf8.count + part.utf8.count > 64_000 {
                overflowed = true
                text = ""
            } else {
                text += part
            }
        }
    }
    private enum Autonomy: String, CaseIterable {
        case strict = "Strict"
        case guided = "Guided"
        case autonomous = "Autonomous"

        var explanation: String {
            switch self {
            case .strict: "Code Bot må kun forberede ændringer. Du godkender hver fil."
            case .guided: "Code Bot må planlægge flere trin. Hver filskrivning kræver stadig godkendelse."
            case .autonomous: "Code Bot må arbejde videre selv. Sikkerhedsgodkendelse før filskrivning er stadig aktiv."
            }
        }
    }

    let api: LiveAPI?
    let onBack: () -> Void
    @AppStorage("code.autonomy") private var autonomy = Autonomy.strict.rawValue
    @State private var files: [V2CodeWorkspace.File] = []
    @State private var selected = Set<String>()
    @State private var path = "notes/plan.md"
    @State private var content = ""
    @State private var proposal: V2CodeProposal?
    @State private var loading = false
    @State private var message: String?
    @State private var approval = false
    @State private var featureRequest = ""
    @State private var firstEditLine = "1"
    @State private var generatedProposal: GeneratedProposal?
    @State private var codeStatus = ""
    @State private var testPlan: [String] = []

    var body: some View {
        NavigationStack {
            codeContent
                .background(FadedBackground(variant: .terminal))
                .navigationTitle("Code Bot")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left", action: onBack)
                    }
                }
                .refreshable { await load() }
                .task { restoreContext(); await load() }
                .confirmationDialog("Godkend filændringen?", isPresented: $approval, presenting: proposal) { item in
                    Button("Skriv filen", role: .destructive) { Task { await apply(item) } }
                } message: { item in
                    Text("Kun \(item.path) i Agent Workspace bliver ændret.")
                }
        }
    }

    private var codeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                Text("Din makker på PC’en. Se ændringen, før den skrives.")
                    .font(FadedTypography.body).foregroundStyle(palette.secondary)
                autonomyCard
                fileCards
                featureCard
                manualCard
                if let proposal { proposalCard(proposal) }
                if let message {
                    FadedCard(accent: palette.cyan) { Text(message).font(FadedTypography.body) }
                }
            }.padding(FadedSpacing.edge).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
    }

    private var autonomyCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Autonomi")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { autonomyChoices }
                    VStack(alignment: .leading, spacing: 4) { autonomyChoices }
                }
                Text(Autonomy(rawValue: autonomy)?.explanation ?? Autonomy.strict.explanation)
                    .font(.callout).foregroundStyle(palette.secondary)
            }
        }
    }

    @ViewBuilder private var autonomyChoices: some View {
        ForEach(Autonomy.allCases, id: \.rawValue) { choice in
            FadedChip(choice.rawValue, accent: palette.lime, selected: autonomy == choice.rawValue) {
                autonomy = choice.rawValue
            }
        }
    }

    @ViewBuilder private var fileCards: some View {
        FadedSectionLabel("Aktive filer")
        if loading { ProgressView("Henter fra PC’en…") }
        if files.isEmpty && !loading {
            FadedEmptyState(icon: "folder", title: "Ingen filer her endnu", detail: "Tilføj en tekstfil i Agent Workspace på PC’en.")
        }
        ForEach(files) { file in
            let isSelected = selected.contains(file.path)
            Button {
                guard !loading else { return }
                if isSelected { selected.remove(file.path) }
                else { selected.insert(file.path) }
                persistContext()
                Task { await open(file.path) }
            } label: {
                FadedCard(accent: isSelected ? palette.lime : nil) {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected && palette.isDark ? palette.lime : palette.secondary)
                        VStack(alignment: .leading) {
                            Text(file.path).font(FadedTypography.code).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44)
                }
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: FadedRadius.card).strokeBorder(palette.lime, lineWidth: 2).allowsHitTesting(false) }
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel(file.path)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var featureBlocker: String? {
        if api == nil { return "Forbind til PC’en først." }
        if loading { return "Vent på PC’en." }
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Vælg en fil." }
        if featureRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Beskriv ændringen først." }
        return nil
    }

    private var featureCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                if let api {
                    NavigationLink("Forslag til flere filer") { BatchReviewView(api: api) }
                        .buttonStyle(FadedButtonStyle(kind: .secondary))
                }
                FadedSectionLabel("Byg en funktion")
                Text("Vælg en fil og beskriv én ændring. Brug startlinjen, hvis filen er lang.")
                    .font(.callout).foregroundStyle(palette.secondary)
                TextField("Hvad skal ændres?", text: $featureRequest, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder).disabled(loading)
                LabeledContent("Startlinje i filen") {
                    TextField("Startlinje", text: $firstEditLine).keyboardType(.numberPad)
                        .font(FadedTypography.number).multilineTextAlignment(.trailing).frame(minHeight: 44).disabled(loading)
                }
                Button { Task { await generateFeature() } } label: {
                    Label("Forbered forslag", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .buttonStyle(FadedButtonStyle(kind: proposal == nil ? .primary : .secondary))
                .disabled(featureBlocker != nil)
                if let featureBlocker { Text(featureBlocker).font(.caption).foregroundStyle(palette.secondary) }
                if !codeStatus.isEmpty { Text(codeStatus).font(.caption).foregroundStyle(palette.secondary) }
            }
        }
    }

    private var manualCard: some View {
        FadedCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Relativ filsti", text: $path).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().textFieldStyle(.roundedBorder).disabled(loading)
                    TextEditor(text: $content).font(FadedTypography.code).frame(minHeight: 180)
                        .overlay { RoundedRectangle(cornerRadius: FadedRadius.small).strokeBorder(palette.border) }
                        .accessibilityLabel("Nyt filindhold").disabled(loading)
                    FadedSecondaryButton("Forbered manuel ændring") { Task { await prepare() } }
                        .disabled(api == nil || loading || path.isEmpty)
                }.padding(.top, 10)
            } label: { FadedSectionLabel("Ret fil manuelt") }
        }
    }

    private func proposalCard(_ proposal: V2CodeProposal) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Dit tjek. Din godkendelse.", systemImage: "lock.shield").font(FadedTypography.action)
                FadedDiff(diff: proposal.diff)
                if !testPlan.isEmpty {
                    FadedSectionLabel("Testplan")
                    ForEach(Array(testPlan.enumerated()), id: \.offset) { item in Text("\(item.offset + 1). \(item.element)") }
                }
                FadedPrimaryButton("Godkend ændring", icon: "checkmark") { approval = true }.disabled(loading)
                if loading { Text("Vent på PC’en.").font(.caption).foregroundStyle(palette.secondary) }
                FadedSecondaryButton("Afvis") { Task { await reject(proposal) } }.disabled(loading)
            }
        }
    }

    private func load() async {
        guard let api else { message = "Forbind til PC’en for at åbne Agent Workspace."; return }
        guard !loading else { return }
        loading = true; defer { loading = false }
        do { try await reloadFiles(api); message = nil }
        catch { message = "Agent Workspace kunne ikke hentes. Tryk og prøv igen." }
    }

    private func reloadFiles(_ api: LiveAPI) async throws {
        files = try await api.v2CodeWorkspace().files
    }

    private func open(_ file: String) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let found = try await api.v2CodeFile(path: file)
            path = found.path
            content = found.content
            firstEditLine = "1"
        }
        catch { message = "Filen kunne ikke åbnes sikkert." }
    }

    private func prepare() async {
        guard let api, !loading else { return }
        proposal = nil
        generatedProposal = nil
        testPlan = []
        codeStatus = ""
        loading = true; defer { loading = false }
        do { proposal = try await api.v2CodeProposal(path: path, content: content); message = nil }
        catch { message = "Ændringen kunne ikke forberedes. Tjek filstien og prøv igen." }
    }

    private func generateFeature() async {
        guard let api, !loading else { return }
        let brief = featureRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, !target.isEmpty else { return }
        guard let firstLine = Int(firstEditLine.trimmingCharacters(in: .whitespacesAndNewlines)), firstLine > 0 else {
            codeStatus = "Indtast en gyldig startlinje."
            return
        }
        proposal = nil
        generatedProposal = nil
        testPlan = []
        loading = true; codeStatus = "Henter den aktuelle fil fra PC’en…"
        defer { loading = false }
        do {
            let original = try await workspaceSource(api, path: target)
            let source = original ?? ""
            let context = try WorkspacePatch.context(goal: brief, path: target, source: source, firstLine: firstLine)
            let request = try V2ChatRequest(message: context.prompt)
            codeStatus = context.lines.isEmpty ? "PC-modellen forbereder en ny fil…"
                : "PC-modellen gennemgår linje \(firstLine)–\(context.lines.upperBound)…"
            let stream = DraftStream()
            try await api.v2Chat(request) { event in
                await MainActor.run {
                    if event.type == .text { stream.append(event.content) }
                    if event.type == .tool_status { codeStatus = codeStatusText(event.content, api: api) }
                }
            }
            guard !stream.overflowed else { throw WorkspacePatch.Failure.invalidDiff }
            let result = try JSONDecoder().decode(FeatureDraft.self, from: ModelJSON.payload(stream.text))
            guard result.feasible else {
                codeStatus = codeStatusText(result.reason, api: api)
                return
            }
            let plan = result.tests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let diff = result.diff,
                  (1...6).contains(plan.count), plan.allSatisfy({ !$0.isEmpty && $0.count <= 300 })
            else { throw WorkspacePatch.Failure.invalidDiff }
            let revised = try WorkspacePatch.applying(diff, to: source, path: target, within: context.lines)
            try await checkSource(api, path: target, original: original)
            let prepared = try await api.v2CodeProposal(path: target, content: revised)
            guard prepared.requires_approval, prepared.path == target, !prepared.diff.isEmpty else {
                throw V2Failure.invalidResponse
            }
            try await checkSource(api, path: target, original: original)
            generatedProposal = GeneratedProposal(original: original, revised: revised)
            proposal = prepared
            testPlan = plan.map { codeStatusText($0, api: api) }
            codeStatus = "Forslaget er klar. Gennemgå diff og testplan."
        } catch {
            codeStatus = (error as? WorkspacePatch.Failure)?.message
                ?? pcBusyMessage(error) ?? "Code Bot kunne ikke forberede ændringen. Ingen fil blev skrevet."
        }
    }

    private func codeStatusText(_ text: String, api: LiveAPI) -> String {
        let safe = api.redactChat(text, complete: true).trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.contains("Traceback (most recent call last)") { return "PC’en sendte en intern fejl." }
        return String(safe.prefix(300)).replacingOccurrences(of: #"(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n`\"<>]+"#,
                                                              with: "[filsti skjult]", options: .regularExpression)
    }

    private func workspaceSource(_ api: LiveAPI, path: String) async throws -> String? {
        do {
            let file = try await api.v2CodeFile(path: path)
            guard file.path == path else { throw WorkspacePatch.Failure.stale }
            return file.content
        } catch V2Failure.http(status: 404, code: _, message: _) {
            return nil
        }
    }

    private func checkSource(_ api: LiveAPI, path: String, original: String?) async throws {
        let current = try await workspaceSource(api, path: path)
        if let original, let current, original.utf8.elementsEqual(current.utf8) { return }
        guard original == nil && current == nil else { throw WorkspacePatch.Failure.stale }
    }

    private func reject(_ item: V2CodeProposal) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do { _ = try await api.v2ApplyCodeProposal(item.change_id, approved: false) }
        catch { /* A rejection is confirmed by the server's NOT_READY response. */ }
        proposal = nil
        generatedProposal = nil
        codeStatus = ""
        message = "Ændringen blev afvist. Intet blev skrevet."
    }

    private func apply(_ item: V2CodeProposal) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do {
            if let generatedProposal {
                try await checkSource(api, path: item.path, original: generatedProposal.original)
            }
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: true)
            proposal = nil
            if result.applied, item.path == path, let generatedProposal { content = generatedProposal.revised }
            generatedProposal = nil
            codeStatus = ""
            message = result.applied ? "Ændringen er skrevet til \(result.path)." : "Intet blev ændret."
            try? await reloadFiles(api)
        } catch let failure as WorkspacePatch.Failure {
            proposal = nil
            generatedProposal = nil
            codeStatus = failure.message
        } catch { message = "PC’en bekræftede ikke ændringen. Intet nyt forsøg blev sendt." }
    }

    private func persistContext() {
        UserDefaults.standard.set(Array(selected).sorted(), forKey: "code.active.context")
    }

    private func restoreContext() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "code.active.context") ?? [])
    }
}

private struct CloudModelSettings: View {
    @State private var draft = ""
    @State private var hasKey = CloudModelKey.exists()
    @State private var notice: String?

    var body: some View {
        DisclosureGroup("Valgfri xAI-nøgle") {
            Text("Nøglen gemmes i iPhones Keychain. Vælg Grok i chatten for at sende til xAI. Forbruget kan koste penge.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("xAI API-nøgle", text: $draft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Gem nøgle") {
                do {
                    try CloudModelKey.save(draft)
                    draft = ""
                    notice = "Nøglen er gemt på telefonen."
                } catch { notice = "Nøglen kunne ikke gemmes." }
            }.disabled(draft.isEmpty)
            if hasKey {
                Button("Fjern nøgle", role: .destructive) {
                    CloudModelKey.remove()
                    notice = CloudModelKey.exists() ? "Nøglen kunne ikke fjernes." : "Nøglen er fjernet."
                }
            }
            if let notice { Text(notice).font(.caption) }
        }
        .onAppear { hasKey = CloudModelKey.exists() }
        .onReceive(NotificationCenter.default.publisher(for: CloudModelKey.didChange)) { _ in
            hasKey = CloudModelKey.exists()
        }
    }
}

private struct ChatView: View {
    private enum ReplySource: String, CaseIterable {
        case phone = "Telefon"
        case pc = "PC"
        case grok = "Grok"

        var icon: String {
            switch self {
            case .phone: "iphone"
            case .pc: "desktopcomputer"
            case .grok: "cloud"
            }
        }
    }

    @Environment(\.fadedPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let api: (any ChatAPI)?
    let demo: Bool
    let initialDraft: String
    let connection: String
    let storageKey: String
    let onBack: (() -> Void)?
    let openImageStudio: ((String) -> Void)?
    @State private var sessionID = UUID()
    @State private var draft = ""
    @AppStorage private var savedDraft: String
    @State private var turns: [ChatTurn] = []
    @State private var status: String?
    @State private var streamedText = ""
    @State private var task: Task<Void, Never>?
    @State private var searchSteps: [String] = []
    @State private var loaded = false
    @AppStorage("spaces.notes") private var notes = ""
    @State private var sourceExcerpt: String?
    @State private var models: [V2Models.Entry] = []
    @State private var selectedModel = ""
    @State private var cloudKeyAvailable = CloudModelKey.exists()
    @State private var replySource = ReplySource.phone
    @State private var modelsLoading = true
    @State private var modelsError: String?
    @State private var legacyChat = false
    @State private var completedReplies = 0
    @AppStorage(PhoneModels.selectionKey) private var phoneModel = "apple"
    @State private var phoneBatteryLevel = UIDevice.current.batteryLevel
    @State private var dictation = ChatDictation()
    @State private var speech = AVSpeechSynthesizer()
    @AppStorage("chat.voiceMode") private var voiceMode = false
    @AppStorage("chat.voiceBot") private var voiceBotID = ""
    @AppStorage("chat.voice.language") private var preferredVoiceLanguage = "da-DK"
    @AppStorage("chat.voice.identifier") private var preferredVoiceID = ""
    @AppStorage("village.bots") private var voiceBotData = Data()
    @FocusState private var composerFocused: Bool
    @State private var chatSearch = ""
    @State private var archivedTurns: [ChatTurn] = []
    @State private var favoritesOnly = false
    @State private var scrollRequest = 0
    @State private var showComposerTools = false
    @State private var choosingNote = false
    @State private var newNote = ""
    @State private var attachedNote: String?
    @State private var imageHandoff: String?
    @AppStorage("ai.tone") private var aiTone = "Naturlig"
    @AppStorage("ai.length") private var aiLength = "Kort"
    @AppStorage("ai.language") private var aiLanguage = "Dansk"
    @AppStorage("ai.creativity") private var aiCreativity = "Balanceret"
    @AppStorage("ai.bullets") private var aiBullets = false
    @AppStorage("ai.examples") private var aiExamples = false
    @AppStorage("ai.summary") private var aiSummary = false
    @AppStorage("ai.actions") private var aiActions = false
    @AppStorage("ai.clarify") private var aiClarify = true
    @AppStorage("ai.simple") private var aiSimple = true
    @AppStorage("ai.noJargon") private var aiNoJargon = true
    @AppStorage("ai.steps") private var aiSteps = false
    @AppStorage("ai.tables") private var aiTables = false
    @AppStorage("ai.uncertainty") private var aiUncertainty = true
    @AppStorage("ai.counterpoint") private var aiCounterpoint = false
    @AppStorage("ai.assumptions") private var aiAssumptions = false
    @AppStorage("ai.sources") private var aiSources = false
    @AppStorage("ai.codeComments") private var aiCodeComments = true
    @AppStorage("ai.preserveNames") private var aiPreserveNames = true
    @AppStorage("ai.emojis") private var aiEmojis = false
    @AppStorage("ai.headings") private var aiHeadings = true
    @AppStorage("ai.recapQuestion") private var aiRecapQuestion = false
    @AppStorage("ai.suggestions") private var aiSuggestions = true
    @AppStorage("ai.risks") private var aiRisks = false
    @AppStorage("ai.prosCons") private var aiProsCons = false
    @AppStorage("ai.checklist") private var aiChecklist = false
    @AppStorage("ai.private") private var aiPrivateSession = false
    @AppStorage("ai.timestamps") private var aiTimestamps = false
    @AppStorage("ai.wordCount") private var aiWordCount = false
    @AppStorage("ai.showTools") private var aiShowTools = true
    @AppStorage("qol.reduceMotion") private var calmMotion = false

    init(api: (any ChatAPI)?, demo: Bool, initialDraft: String, connection: String, storageKey: String,
         onBack: (() -> Void)? = nil, openImageStudio: ((String) -> Void)? = nil) {
        self.api = api
        self.demo = demo
        self.initialDraft = initialDraft
        self.connection = connection
        self.storageKey = storageKey
        self.onBack = onBack
        self.openImageStudio = openImageStudio
        _savedDraft = AppStorage(wrappedValue: "", storageKey + ".draft")
    }

    private var voiceBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: voiceBotData)) ?? []
    }

    private var voiceControls: some View {
        DisclosureGroup("Oplæsning på telefonen") {
            Toggle("Læs færdige svar op", isOn: $voiceMode)
            if !voiceBots.isEmpty {
                Picker("Botstemme", selection: $voiceBotID) {
                    Text("Valgt telefonstemme").tag("")
                    ForEach(voiceBots) { bot in Text(bot.name).tag(bot.id.uuidString) }
                }
            }
            if voiceBots.first(where: { $0.id.uuidString == voiceBotID }) == nil {
                Picker("Oplæsningssprog", selection: $preferredVoiceLanguage) {
                    Text("Dansk").tag("da-DK")
                    Text("Engelsk").tag("en-US")
                }
                .onChange(of: preferredVoiceLanguage) { preferredVoiceID = "" }
                let voices = LocalSpeechVoice.options(language: preferredVoiceLanguage)
                Picker("Telefonstemme", selection: $preferredVoiceID) {
                    Text("Bedste tilgængelige").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(LocalSpeechVoice.label(voice)).tag(voice.identifier)
                    }
                }
            }
            Button("Stop oplæsning") { speech.stopSpeaking(at: .immediate) }
                .frame(minHeight: 44)
        }
    }

    private func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let bot = voiceBots.first { $0.id.uuidString == voiceBotID }
        utterance.voice = LocalSpeechVoice.resolve(identifier: bot?.voice ?? preferredVoiceID,
                                                   language: bot?.language ?? preferredVoiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(bot?.voiceRate ?? 1)
        speech.speak(utterance)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                chatContent(userBubbleWidth: max(1, (geometry.size.width - 32) * 0.8))
            }
            .background { FadedBackground(variant: aiPrivateSession ? .privateChat : .standard) }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(palette.isDark ? palette.lime : palette.text)
    }

    private func chatContent(userBubbleWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            chatHeading
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        TextField(aiPrivateSession ? "Søg i privat samtale" : "Søg i alle samtaler", text: $chatSearch)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: chatSearch) { old, new in
                                if old.isEmpty && !new.isEmpty && !aiPrivateSession { archivedTurns = ChatArchive.turns() }
                                if new.isEmpty { archivedTurns = [] }
                            }
                        DisclosureGroup("Chatindstillinger") {
                            VStack(alignment: .leading, spacing: 12) {
                                StatsBar(turns: turns.count, streaming: task != nil)
                                if replySource == .pc { modelControls }
                                if replySource == .grok && !demo && !aiPrivateSession { CloudModelSettings() }
                                voiceControls
                                aiBoostControls
                                if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                                Text("Researcher bruger internettet, når en websøgning er nødvendig.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Toggle("Vis kun favoritter", isOn: $favoritesOnly)
                                ShareLink(item: conversationText) {
                                    Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                                        .frame(minHeight: 44)
                                }.disabled(turns.isEmpty)
                            }.padding(.top, 8)
                        }
                        if chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if turns.isEmpty && task == nil {
                                FadedEmptyState(icon: "bubble.left", title: "Start en samtale", detail: "Vælg en kilde, og skriv din besked.")
                            }
                            transcriptRows(userBubbleWidth: userBubbleWidth)
                        } else { globalSearchRows }
                        if aiShowTools && !searchSteps.isEmpty {
                            DisclosureGroup("Agentaktivitet · \(searchSteps.count) trin") {
                                ForEach(searchSteps.indices, id: \.self) { index in
                                    Label(searchSteps[index], systemImage: index + 1 == searchSteps.count ? "circle.fill" : "arrow.down.circle")
                                }
                            }
                        }
                        if let status, task != nil { AgentToolWave(status: status) }
                        if task != nil && streamedText.isEmpty { LoadingSkeleton(label: "Venter på AI…") }
                        if let sourceExcerpt {
                            DisclosureGroup("Lokal reference · Notes") {
                                Text(sourceExcerpt)
                                Text("Fundet på telefonen. Referencen blev ikke sendt til PC’en.")
                                    .font(.caption)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { scrollChat(proxy) }
                .onChange(of: streamedText) { scrollChat(proxy) }
                .onChange(of: scrollRequest) { scrollChat(proxy) }
                .onChange(of: replySource) { attachedNote = nil }
                .onChange(of: draft) { _, value in
                    if loaded && !aiPrivateSession { savedDraft = value }
                }
                .onChange(of: aiPrivateSession) { _, isPrivate in
                    stop()
                    if isPrivate && replySource == .grok { replySource = .phone }
                    turns = []
                    searchSteps = []
                    sourceExcerpt = nil
                    attachedNote = nil
                    sessionID = UUID()
                    archivedTurns = []
                    chatSearch = ""
                    draft = isPrivate ? "" : savedDraft
                    if !isPrivate { loadHistory() }
                }
                .safeAreaInset(edge: .bottom) { composer }
                .onAppear {
                    phoneBatteryLevel = UIDevice.current.batteryLevel
                    cloudKeyAvailable = CloudModelKey.exists()
                    guard !loaded else { return }
                    loaded = true
                    let localModelID = PhoneModels.effectiveModelID(phoneModel)
                    let localReady = localModelID == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(localModelID) != nil
                    if api != nil && !localReady && !demo { replySource = .pc }
                    loadHistory()
                    draft = initialDraft.isEmpty && !aiPrivateSession ? savedDraft : initialDraft
                    scrollChat(proxy)
                }
                .onDisappear { stop(); dictation.stop(); speech.stopSpeaking(at: .immediate) }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                    phoneBatteryLevel = UIDevice.current.batteryLevel
                }
                .onReceive(NotificationCenter.default.publisher(for: CloudModelKey.didChange)) { _ in
                    cloudKeyAvailable = CloudModelKey.exists()
                }
                .task { await loadModels() }
                .sensoryFeedback(.success, trigger: completedReplies)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Tilbage", systemImage: "chevron.left", action: goBack)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ny samtale", systemImage: "square.and.pencil") { newConversation() }
                    .disabled(task != nil)
            }
        }
        .sheet(isPresented: $showComposerTools, onDismiss: finishComposerTools) { composerToolsSheet }
    }

    private var chatHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI-chat").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                quickModelPicker
            }
            Text(connection).font(.subheadline).foregroundStyle(palette.secondary)
            if !demo { sourcePicker }
            if aiPrivateSession {
                Label("Privat samtale · Ingen lokal historik", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? palette.purple : palette.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .foregroundStyle(palette.text)
    }

    @ViewBuilder private var quickModelPicker: some View {
        if replySource == .pc && !models.isEmpty {
            Menu {
                ForEach(models) { entry in
                    Button(entry.label) { selectedModel = entry.id }
                }
            } label: {
                Label(models.first(where: { $0.id == selectedModel })?.label ?? "Model", systemImage: "chevron.down")
                    .font(.caption.bold()).lineLimit(1)
            }
            .disabled(task != nil)
            .accessibilityLabel("Skift PC-model")
        }
    }

    private func goBack() {
        composerFocused = false
        stop()
        if let onBack { onBack() }
        else { dismiss() }
    }

    private var sourcePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { sourceChips }
            VStack(alignment: .leading, spacing: 6) { sourceChips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Svar fra")
        .disabled(task != nil)
    }

    private var sourceChips: some View {
        ForEach(ReplySource.allCases.filter { !aiPrivateSession || $0 != .grok }, id: \.self) { source in
            FadedChip(source.rawValue, accent: sourceColor(source), selected: replySource == source, icon: source.icon) {
                replySource = source
            }
        }
    }

    private func sourceColor(_ source: ReplySource) -> Color {
        switch source {
        case .phone: palette.green
        case .pc: palette.cyan
        case .grok: palette.purple
        }
    }

    private var sourceNote: String? {
        guard !demo else { return nil }
        return switch replySource {
        case .phone: nil
        case .pc: api == nil ? "Forbind til PC’en for at sende." : nil
        case .grok: cloudKeyAvailable
            ? "Beskeden og de seneste Grok-udvekslinger sendes til xAI. Forbrug kan koste penge."
            : "Gem en xAI-nøgle under Chatindstillinger for at sende til Grok."
        }
    }

    private var canSendToSource: Bool {
        if demo { return true }
        return switch replySource {
        case .phone: true
        case .pc: api != nil && !modelsLoading
        case .grok: cloudKeyAvailable && !aiPrivateSession
        }
    }

    private func scrollChat(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                if let attachedNote {
                    HStack {
                        Label("Note: \(String(attachedNote.prefix(80)))", systemImage: "note.text")
                            .lineLimit(1)
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button("Fjern note", systemImage: "xmark") { self.attachedNote = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Button("Flere handlinger", systemImage: "plus") {
                        composerFocused = false
                        choosingNote = false
                        newNote = ""
                        showComposerTools = true
                    }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(task != nil)
                    TextField("Skriv en besked…", text: $draft, axis: .vertical)
                        .lineLimit(1...4).frame(minHeight: 44).focused($composerFocused)
                    dictationAction.disabled(task != nil)
                    sendControl
                }
                if let problem = dictation.problem { Text(problem).font(.caption).foregroundStyle(palette.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(aiPrivateSession ? palette.purple : palette.border) }

            HStack(alignment: .firstTextBaseline) {
                Label("Sendes til: \(demo ? "Demo" : replySource.rawValue)", systemImage: demo ? "testtube.2" : replySource.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(demo || !palette.isDark ? palette.secondary : sourceColor(replySource))
                if replySource == .phone, phoneBatteryLevel >= 0, phoneBatteryLevel < 0.20, PhoneModels.liteModeActive(for: phoneModel) {
                    Label("Lite Mode", systemImage: "battery.25percent").font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Text("\(transportMessage.unicodeScalars.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(transportMessage.unicodeScalars.count > 2000 ? palette.coralText : palette.secondary)
            }
            if let sourceNote { Text(sourceNote).font(.caption).foregroundStyle(palette.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var sendControl: some View {
        let sending = task != nil
        let allowed = sending || (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transportMessage.unicodeScalars.count <= 2000 && canSendToSource)
        return Button {
            if sending { stop() }
            else { send() }
        } label: {
            Image(systemName: sending ? "stop.fill" : "arrow.up")
                .font(.body.weight(.bold)).foregroundStyle(Color.black)
                .frame(width: 40, height: 40).background(palette.lime.opacity(allowed ? 1 : 0.45), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sending ? "Stop modtagelse" : (demo ? "Send testbesked" : "Send til \(replySource.rawValue)"))
        .disabled(!allowed)
    }

    private var composerToolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if choosingNote {
                        noteChoices
                    } else {
                        if openImageStudio != nil && !aiPrivateSession {
                            FadedSecondaryButton("Lav billede", icon: "photo") {
                                imageHandoff = draft
                                showComposerTools = false
                            }
                        }
                        FadedSecondaryButton(aiPrivateSession ? "Slå privat fra" : "Slå privat til", icon: "lock") {
                            aiPrivateSession.toggle()
                            showComposerTools = false
                        }
                        FadedSecondaryButton("Vedhæft note", icon: "note.text") { choosingNote = true }
                            .disabled(demo)
                        DisclosureGroup("Flere chatværktøjer") {
                            promptTemplates
                            Button("Vis nyeste besked", systemImage: "arrow.down") {
                                scrollRequest += 1
                                showComposerTools = false
                            }.frame(minHeight: 44)
                            Button("Ryd kladde", role: .destructive) {
                                draft = ""
                                attachedNote = nil
                                showComposerTools = false
                            }.frame(minHeight: 44).disabled(draft.isEmpty && attachedNote == nil)
                        }
                    }
                }.padding(20)
            }
            .background { FadedBackground(variant: aiPrivateSession ? .privateChat : .standard) }
            .navigationTitle(choosingNote ? "Vedhæft note" : "Chatværktøjer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { showComposerTools = false } }
        }
        .presentationDetents(choosingNote ? [.large] : [.medium, .large])
    }

    private var noteChoices: some View {
        let excerpts = notes.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Vælg et uddrag. Det følger næste besked til \(replySource.rawValue).").foregroundStyle(palette.secondary)
            if excerpts.isEmpty {
                FadedEmptyState(icon: "note.text", title: "Ingen noter", detail: "Tilføj en note i appen, og prøv igen.")
            } else {
                ForEach(Array(excerpts.prefix(30).enumerated()), id: \.offset) { item in
                    let excerpt = String(item.element.prefix(600))
                    Button {
                        attachedNote = excerpt
                        showComposerTools = false
                    } label: {
                        Text(verbatim: excerpt).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(FadedButtonStyle(kind: .secondary))
                }
            }
            if !aiPrivateSession {
                DisclosureGroup("Tilføj en lokal note") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Skriv en kort note…", text: $newNote, axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder)
                        Button("Gem note på telefonen", action: saveNote)
                            .frame(minHeight: 44)
                            .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newNote.count > 600)
                    }.padding(.top, 6)
                }
            }
        }
    }

    private func saveNote() {
        let clean = newNote.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aiPrivateSession, !clean.isEmpty, clean.count <= 600 else { return }
        notes = notes.isEmpty ? clean : clean + "\n" + notes
        newNote = ""
    }

    private func finishComposerTools() {
        newNote = ""
        guard let imageHandoff else { return }
        self.imageHandoff = nil
        dictation.stop()
        openImageStudio?(imageHandoff)
    }

    private var promptTemplates: some View {
        Menu("Skabeloner") {
            ForEach(PromptExample.examples) { example in
                Button(example.text) {
                    draft = example.text
                    showComposerTools = false
                }
            }
        }.frame(minHeight: 44)
    }

    private var dictationAction: some View {
        Button {
            if dictation.active { dictation.stop() }
            else {
                let prefix = draft.isEmpty ? "" : draft + " "
                Task { await dictation.start { draft = prefix + $0 } }
            }
        } label: {
            Image(systemName: dictation.active ? "stop.circle" : "mic")
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
    }

    @ViewBuilder private var modelControls: some View {
        if modelsLoading { LoadingSkeleton(label: "Henter modeller…") }
        if let modelsError { RetryNotice(message: modelsError) { Task { await loadModels() } } }
        if legacyChat { Text("Chat bruger PC’ens standardmodel via v1.").font(.caption) }
        if !models.isEmpty {
            Picker("AI-model", selection: $selectedModel) {
                ForEach(models) { model in
                    Text(model.label).tag(model.id)
                }
            }.disabled(task != nil || modelsLoading).frame(minHeight: 48)
        }
    }

    private var aiBoostControls: some View {
        DisclosureGroup("AI Boost · 30 forbedringer") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Tone", selection: $aiTone) {
                    ForEach(["Naturlig", "Varm", "Professionel", "Direkte", "Legende"], id: \.self) { Text($0) }
                }
                Picker("Svarlængde", selection: $aiLength) {
                    ForEach(["Meget kort", "Kort", "Mellem", "Grundig"], id: \.self) { Text($0) }
                }
                Picker("Sprog", selection: $aiLanguage) {
                    ForEach(["Dansk", "Engelsk", "Følg beskeden"], id: \.self) { Text($0) }
                }
                Picker("Kreativitet", selection: $aiCreativity) {
                    ForEach(["Præcis", "Balanceret", "Kreativ"], id: \.self) { Text($0) }
                }
                Toggle("Brug punktform", isOn: $aiBullets)
                Toggle("Giv eksempler", isOn: $aiExamples)
                Toggle("Start med et resumé", isOn: $aiSummary)
                Toggle("Slut med næste handling", isOn: $aiActions)
                Toggle("Spørg ved uklarhed", isOn: $aiClarify)
                Toggle("Brug enkelt sprog", isOn: $aiSimple)
                Toggle("Undgå fagsprog", isOn: $aiNoJargon)
                Toggle("Vis trin for trin", isOn: $aiSteps)
                Toggle("Brug tabel ved sammenligning", isOn: $aiTables)
                Toggle("Fortæl når noget er usikkert", isOn: $aiUncertainty)
                Toggle("Nævn et modargument", isOn: $aiCounterpoint)
                Toggle("Vis antagelser", isOn: $aiAssumptions)
                Toggle("Bed om kilder ved research", isOn: $aiSources)
                Toggle("Korte kodekommentarer", isOn: $aiCodeComments)
                Toggle("Bevar præcise navne", isOn: $aiPreserveNames)
                Toggle("Tillad få emojis", isOn: $aiEmojis)
                Toggle("Brug korte overskrifter", isOn: $aiHeadings)
                Toggle("Slut med kontrolspørgsmål", isOn: $aiRecapQuestion)
                Toggle("Foreslå relevante genveje", isOn: $aiSuggestions)
                Toggle("Fremhæv risici", isOn: $aiRisks)
                Toggle("Vis fordele og ulemper", isOn: $aiProsCons)
                Toggle("Lav tjekliste ved opgaver", isOn: $aiChecklist)
                Toggle("Privat session uden historik", isOn: $aiPrivateSession).disabled(task != nil)
                Toggle("Vis klokkeslæt", isOn: $aiTimestamps)
                Toggle("Vis antal ord", isOn: $aiWordCount)
                Toggle("Vis værktøjsaktivitet", isOn: $aiShowTools)
            }.padding(.top, 8)
        }
    }

    private func loadModels() async {
        modelsLoading = true
        defer { modelsLoading = false }
        modelsError = nil
        legacyChat = false
        guard let live = api as? LiveAPI else {
            if !demo { modelsError = "Forbind til din PC i Indstillinger." }
            return
        }
        do {
            let catalog = try await live.v2Models()
            let available = catalog.models.filter { $0.available && $0.capabilities.contains("chat") }
            models = available
            if !available.contains(where: { $0.id == selectedModel }) {
                selectedModel = available.first(where: { $0.id == catalog.default_model_id })?.id
                    ?? available.first?.id ?? ""
            }
            if available.isEmpty { modelsError = "PC’en har ingen tilgængelige chatmodeller." }
        } catch V2Failure.http(status: 404, code: _, message: _) {
            models = []; selectedModel = ""; legacyChat = true
        } catch {
            if !Task.isCancelled {
                models = []; selectedModel = ""
                modelsError = error is V2Failure ? v2Message(error) : "Kunne ikke hente modeller. Tjek forbindelsen til PC’en."
            }
        }
    }

    private func transcriptRows(userBubbleWidth: CGFloat) -> some View {
        ForEach(filteredTurns) { turn in
            let accent = replyColor(turn.source)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer(minLength: 0)
                    Text(turn.prompt)
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(palette.lime, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: userBubbleWidth, alignment: .trailing)
                }
                if !turn.reply.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(turn.source ?? "AI", systemImage: sourceIcon(turn.source))
                            .font(.caption.bold()).foregroundStyle(palette.isDark ? accent : palette.text)
                        if aiTimestamps, let date = turn.createdAt {
                            Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(palette.secondary)
                        }
                        ChatTranscriptView(reply: turn.reply)
                        if aiWordCount {
                            Text("\(turn.reply.split(whereSeparator: \.isWhitespace).count) ord")
                                .font(.caption).foregroundStyle(palette.secondary)
                        }
                        replyActions(turn)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(palette.text)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .leading) {
                        Capsule().fill(accent).frame(width: 4).padding(.vertical, 8).accessibilityHidden(true)
                    }
                }
                if let notice = turn.notice {
                    RetryNotice(message: notice) { draft = turn.prompt }.disabled(task != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Kopiér prompt") { UIPasteboard.general.string = turn.prompt }
                Button("Kopiér svar") { UIPasteboard.general.string = turn.reply }
                Button("Prøv igen") { draft = turn.prompt }.disabled(task != nil)
                Button("Start ny gren") { newConversation(); draft = turn.prompt }.disabled(task != nil)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("Kopiér") { UIPasteboard.general.string = turn.reply }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Prøv igen") { draft = turn.prompt }.disabled(task != nil)
                Button("Ny gren") { newConversation(); draft = turn.prompt }.disabled(task != nil)
            }
            .id(turn.id)
        }
    }

    private func replyColor(_ source: String?) -> Color {
        switch source ?? "" {
        case "Telefon": palette.green
        case "PC": palette.cyan
        case GrokAPI.sourceLabel: palette.purple
        default: palette.lime
        }
    }

    private func replyActions(_ turn: ChatTurn) -> some View {
        HStack(spacing: 4) {
            Button("Læs svaret op", systemImage: "speaker.wave.2") { speak(turn.reply) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Menu {
                Button(turn.favorite == true ? "Fjern favorit" : "Favorit",
                       systemImage: turn.favorite == true ? "star.fill" : "star") { toggleFavorite(turn.id) }
                Button("Godt svar", systemImage: turn.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    setFeedback(turn.id, value: 1)
                }
                Button("Dårligt svar", systemImage: turn.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                    setFeedback(turn.id, value: -1)
                }
                Button("Slet", systemImage: "trash", role: .destructive) { deleteTurn(turn.id) }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Flere handlinger for svar")
        }
    }

    private var filteredTurns: [ChatTurn] {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return turns.filter { turn in
            (!favoritesOnly || turn.favorite == true) &&
            (query.isEmpty || turn.prompt.localizedCaseInsensitiveContains(query) || turn.reply.localizedCaseInsensitiveContains(query))
        }
    }

    @ViewBuilder private var globalSearchRows: some View {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = Set(turns.map(\.id))
        let source = aiPrivateSession ? turns : turns + archivedTurns.filter { !currentIDs.contains($0.id) }
        let hits = source.filter {
            (!favoritesOnly || $0.favorite == true) &&
            ($0.prompt.localizedCaseInsensitiveContains(query) || $0.reply.localizedCaseInsensitiveContains(query))
        }
        if hits.isEmpty { Text("Ingen samtaler matcher søgningen.").foregroundStyle(.secondary) }
        ForEach(hits.prefix(80)) { turn in
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.prompt).font(.headline).textSelection(.enabled)
                if let date = turn.createdAt { Text(date, format: .dateTime.day().month().year()).font(.caption) }
                if !turn.reply.isEmpty { Text(turn.reply).lineLimit(5).textSelection(.enabled) }
            }
            .contextMenu {
                Button("Kopiér prompt") { UIPasteboard.general.string = turn.prompt }
                Button("Brug prompt") { draft = turn.prompt; chatSearch = "" }.disabled(task != nil)
            }
        }
    }

    private var conversationText: String {
        turns.map { "Dig: \($0.prompt)\n\($0.source ?? "AI"): \($0.reply)" }.joined(separator: "\n\n")
    }

    private func toggleFavorite(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].favorite = turns[index].favorite != true
        save()
    }

    private func deleteTurn(_ id: UUID) {
        turns.removeAll { $0.id == id }
        save()
    }

    private func setFeedback(_ id: UUID, value: Int) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].feedback = turns[index].feedback == value ? nil : value
        save()
    }

    private func enhancedPrompt(_ message: String) -> String {
        var rules = ["tone=\(aiTone)", "længde=\(aiLength)", "sprog=\(aiLanguage)", "kreativitet=\(aiCreativity)"]
        let flags: [(Bool, String)] = [
            (aiBullets, "punktform"), (aiExamples, "eksempler"), (aiSummary, "kort resumé først"),
            (aiActions, "næste handling til sidst"), (aiClarify, "spørg ved uklarhed"),
            (aiSimple, "enkelt sprog"), (aiNoJargon, "intet unødigt fagsprog"), (aiSteps, "trin for trin"),
            (aiTables, "tabel ved sammenligning"), (aiUncertainty, "markér usikkerhed"),
            (aiCounterpoint, "ét modargument"), (aiAssumptions, "vis antagelser"),
            (aiSources, "kilder ved research"), (aiCodeComments, "korte kodekommentarer"),
            (aiPreserveNames, "bevar præcise navne"), (aiEmojis, "få emojis"),
            (aiHeadings, "korte overskrifter"), (aiRecapQuestion, "kontrolspørgsmål til sidst"),
            (aiSuggestions, "relevante genveje"), (aiRisks, "fremhæv risici"),
            (aiProsCons, "fordele og ulemper"), (aiChecklist, "tjekliste ved opgaver")
        ]
        rules.append(contentsOf: flags.filter { $0.0 }.map { $0.1 })
        let prefix = "\n\n[Svarpræferencer: "
        let suffix = "]"
        let available = 2000 - message.unicodeScalars.count - prefix.unicodeScalars.count - suffix.unicodeScalars.count
        guard available > 0 else { return message }
        let preferences = rules.joined(separator: "; ").unicodeScalars.prefix(available)
        return message + prefix + String(preferences) + suffix
    }

    private var transportMessage: String {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let attachedNote else { return message }
        return message + "\n\nVedhæftet note til kontekst:\n" + attachedNote
    }

    private func send() {
        dictation.stop()
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = transportMessage
        guard task == nil, !message.isEmpty, outgoing.unicodeScalars.count <= 2000, canSendToSource else { return }
        let source = replySource
        let routeGrok = source == .grok && !demo
        let cloudMessages = routeGrok ? grokMessages(endingWith: outgoing) : []
        sourceExcerpt = routeGrok || attachedNote != nil ? nil : localReference(for: message)
        attachedNote = nil
        draft = ""
        if !aiPrivateSession { savedDraft = "" }
        searchSteps = []
        streamedText = ""
        turns.append(ChatTurn(prompt: message, createdAt: .now))
        let index = turns.count - 1
        let turnID = turns[index].id
        let history = turns.dropLast().suffix(6).filter { !$0.reply.isEmpty }
            .map { "Bruger: \($0.prompt)\nSvar: \($0.reply)" }.joined(separator: "\n")
        let collectionQuestion = message.lowercased().hasPrefix("kortsamling:")
        let modelMessage = routeGrok || collectionQuestion ? outgoing : enhancedPrompt(outgoing)
        let context = String(history.suffix(max(0, 3000 - modelMessage.count)))
        status = "Venter på svar…"
        let input = ChatRequest(message: modelMessage, session_id: aiPrivateSession ? nil : sessionID)
        save(pending: true)
        task = Task {
            defer { status = nil; task = nil; save() }
            do {
                if demo {
                    status = "Demo · Finder et testklip…"
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply = "Jeg fandt et testklip. "
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply += "Demoen starter ikke et video-job."
                } else {
                    switch source {
                    case .phone: try await answerOnPhone(modelMessage, context: context, index: index, turnID: turnID)
                    case .pc: try await answerOnPC(input, index: index, turnID: turnID)
                    case .grok: try await answerOnGrok(cloudMessages, index: index, turnID: turnID)
                    }
                }
                if turns.indices.contains(index), turns[index].id == turnID, turns[index].notice == nil {
                    completedReplies += 1
                    if voiceMode && !turns[index].reply.isEmpty && !dictation.active {
                        speak(turns[index].reply)
                    }
                }
            } catch is CancellationError {
                if turns.indices.contains(index), turns[index].id == turnID {
                    turns[index].notice = "Modtagelsen er stoppet."
                }
            } catch {
                if turns.indices.contains(index), turns[index].id == turnID {
                    if source == .phone && !demo {
                        turns[index].notice = phoneError(error, hasPartial: !turns[index].reply.isEmpty)
                    } else {
                        turns[index].notice = (error as? GrokFailure)?.message ?? pcBusyMessage(error)
                            ?? (error is V2Failure ? v2Message(error)
                                : (error as? APIError)?.title ?? (error as? ChatFailure ?? .interrupted).message)
                    }
                }
            }
        }
    }

    private func sourceIcon(_ source: String?) -> String {
        switch source ?? "" {
        case "Telefon": "iphone"
        case GrokAPI.sourceLabel: "cloud"
        default: "desktopcomputer"
        }
    }

    private func grokMessages(endingWith message: String) -> [GrokAPI.Message] {
        let history = turns.filter { $0.source == GrokAPI.sourceLabel && $0.notice == nil && !$0.reply.isEmpty }
            .suffix(4).flatMap { turn in
                [GrokAPI.Message(role: .user, content: String(turn.prompt.prefix(2000))),
                 GrokAPI.Message(role: .assistant, content: String(turn.reply.prefix(4000)))]
            }
        return (history + [GrokAPI.Message(role: .user, content: message)]).map {
            GrokAPI.Message(role: $0.role, content: (api as? LiveAPI)?.redactChat($0.content, complete: true) ?? $0.content)
        }
    }

    private func answerOnGrok(_ messages: [GrokAPI.Message], index: Int, turnID: UUID) async throws {
        turns[index].source = GrokAPI.sourceLabel
        status = "Grok · Venter på svar…"
        try await GrokAPI.reply(input: messages) { output in
            await MainActor.run {
                guard !Task.isCancelled, turns.indices.contains(index), turns[index].id == turnID else { return }
                streamedText = output
                turns[index].reply = safeText(output, complete: true)
            }
        }
    }

    private func answerOnPhone(_ message: String, context: String, index: Int, turnID: UUID) async throws {
        turns[index].source = "Telefon"
        status = "Telefon · Forbereder svar…"
        let prompt = context.isEmpty ? message : "\(context)\nBruger: \(message)"
        try await PhoneModels.reply(modelID: PhoneModels.effectiveModelID(phoneModel), prompt: prompt,
                                    instructions: "Svar på brugerens sprog. Du kan bruge teksten i chatten og udfører ingen opgaver på PC’en.") { answer in
            guard !Task.isCancelled, turns.indices.contains(index), turns[index].id == turnID else { return }
            turns[index].reply = safeText(answer)
            streamedText = answer
        }
        try Task.checkCancellation()
        if turns.indices.contains(index), turns[index].id == turnID {
            turns[index].reply = safeText(streamedText, complete: true)
        }
    }

    private func phoneError(_ error: Error, hasPartial: Bool) -> String {
        if hasPartial { return "Telefonsvaret blev afbrudt." }
        if case .busy? = error as? LocalComputeError { return "Telefonen arbejder allerede. Prøv igen om lidt." }
        if case .lowMemory? = error as? LocalComputeError { return "Telefonen har for lidt ledig hukommelse til modellen." }
        if case .unavailable? = error as? PhoneModelError { return "Vælg en klar model under Lokale modeller, eller skift til PC." }
        return "Telefonmodellen kunne ikke svare. Prøv igen, eller vælg en anden kilde."
    }

    private func answerOnPC(_ input: ChatRequest, index: Int, turnID: UUID) async throws {
        guard let api else {
            turns[index].notice = "Denne besked kræver en model, der er klar. Forbind til PC’en, eller vælg en lokal model i Indstillinger."
            return
        }
        turns[index].source = "PC"
        status = "PC · Venter på svar…"
        if let live = api as? LiveAPI, !legacyChat {
            let request = try V2ChatRequest(message: input.message, sessionID: input.session_id?.uuidString,
                                            modelID: selectedModel.isEmpty ? nil : selectedModel)
            try await live.v2Chat(request) { event in
                await MainActor.run {
                    guard !Task.isCancelled, turns.indices.contains(index), turns[index].id == turnID else { return }
                    receive(type: event.type.rawValue, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
        } else {
            await run(api, input: input, index: index, turnID: turnID)
        }
    }

    private func run(_ api: any ChatAPI, input: ChatRequest, index: Int, turnID: UUID) async {
        do {
            try await api.chat(input) { event in
                await MainActor.run {
                    guard !Task.isCancelled, turns.indices.contains(index), turns[index].id == turnID else { return }
                    receive(type: event.type, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
        } catch {
            guard turns.indices.contains(index), turns[index].id == turnID else { return }
            turns[index].notice = Task.isCancelled ? "Modtagelsen er stoppet. Et job kan stadig køre."
                : pcBusyMessage(error) ?? (error as? APIError)?.title ?? (error as? ChatFailure ?? .interrupted).message
        }
    }

    private func receive(type: String, content: String, index: Int) {
        switch type {
        case "tool_status":
            let step = safeText(content)
            status = step
            if !step.isEmpty && searchSteps.last != step {
                searchSteps.append(step)
                if searchSteps.count > 30 { searchSteps.removeFirst() }
                save(pending: true)
            }
        case "text":
            streamedText += content
            turns[index].reply = safeText(streamedText)
        case "done":
            turns[index].reply = safeText(streamedText, complete: true)
        default: break
        }
    }

    private func v2Message(_ error: Error) -> String {
        switch error as? V2Failure {
        case .http(status: 401, code: _, message: _): "PC’en afviste tokenet. Tjek det under Indstillinger."
        case .http(status: 404, code: _, message: _): "PC’en kunne ikke finde modellen eller funktionen."
        case .http(status: 409, code: _, message: _): "Beskeden er allerede sendt."
        case .http(status: 503, code: _, message: _): "PC’en har travlt, eller modellen er utilgængelig. Prøv igen om lidt."
        case .invalidInput, .http(status: 422, code: _, message: _): "Skriv en besked på mellem 1 og 2.000 tegn."
        default: "Svaret blev afbrudt. Tjek forbindelsen til PC’en."
        }
    }

    private func safeText(_ text: String, complete: Bool = false) -> String {
        let safe = (api as? LiveAPI)?.redactChat(text, complete: complete) ?? text
        if safe.contains("Traceback (most recent call last)") { return "PC’en sendte en intern fejl." }
        return safe.replacingOccurrences(of: #"(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n`"<>]+"#,
                                         with: "[filsti skjult]", options: .regularExpression)
    }

    private func stop() { task?.cancel() }

    private func newConversation() {
        if !aiPrivateSession && !turns.isEmpty {
            ChatArchive.append(SavedAgentSession(id: sessionID, turns: turns, toolSteps: searchSteps, pending: false))
        }
        turns = []
        draft = ""
        if !aiPrivateSession { savedDraft = "" }
        searchSteps = []
        sourceExcerpt = nil
        attachedNote = nil
        sessionID = UUID()
        save()
    }

    private func localReference(for message: String) -> String? {
        let words = Set(message.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 5 })
        guard !words.isEmpty else { return nil }
        return notes.split(whereSeparator: \.isNewline).first { line in
            let candidates = line.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            return !words.isDisjoint(with: candidates)
        }.map { String($0.prefix(240)) }
    }

    private func save(pending: Bool = false) {
        guard !aiPrivateSession else { return }
        let session = SavedAgentSession(id: sessionID, turns: turns, toolSteps: searchSteps, pending: pending)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadHistory() {
        guard !aiPrivateSession else { turns = []; return }
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        if let session = try? decoder.decode(SavedAgentSession.self, from: data) {
            sessionID = session.id
            turns = session.turns
            searchSteps = session.toolSteps
            if session.pending && !turns.isEmpty {
                turns[turns.count - 1].notice = "Forbindelsen blev afbrudt, før svaret var færdigt."
                save()
            }
        } else if let saved = try? decoder.decode([ChatTurn].self, from: data) {
            turns = saved
        }
    }
}
