import AVKit
import UniformTypeIdentifiers
import PhotosUI
import ImageIO
import Speech
import Observation
import AppIntents
import SwiftUI

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

struct SweatCasterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSweatCasterChat(), phrases: ["Åbn chat i \(.applicationName)"],
                    shortTitle: "Åbn chat", systemImageName: "bubble.left")
        AppShortcut(intent: OpenSweatCasterVideo(), phrases: ["Vælg klip i \(.applicationName)"],
                    shortTitle: "Vælg klip", systemImageName: "film")
    }
}

private struct PromptExample: Identifiable {
    let category: String
    let text: String
    var id: String { text }
    static let examples = [
        Self(category: "Video", text: "Lav et hype-klip af den nyeste fil."),
        Self(category: "Analyse", text: "Analyser denne tekst:"),
        Self(category: "Video", text: "Foreslå en kort titel til mit næste klip."),
        Self(category: "Planlægning", text: "Lav en tjekliste til min næste optagelse."),
        Self(category: "Idéer", text: "Giv mig tre idéer til et sjovt gamingklip.")
    ]
}

@main struct SweatCasterApp: App {
    @AppStorage("app.text.scale") private var textScale = 0.0
    @Environment(\.dynamicTypeSize) private var systemTextSize
    var body: some Scene {
        WindowGroup {
            Home().dynamicTypeSize(textScale == 0 ? systemTextSize :
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

struct Home: View {
    private enum Space: String, CaseIterable, Identifiable {
        case brain = "Brain", notes = "Notes", gallery = "Gallery", tasks = "Tasks", library = "Library"
        var id: Self { self }
    }

    @Environment(\.scenePhase) private var phase
    @State private var model = Model()
    @State private var setup = true
    @State private var address = ""
    @State private var token = ""
    @State private var editedProfile: ConnectionProfile = .home
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
    @State private var showAgentHub = false
    @State private var showCodeWorkspace = false
    @State private var showPhoneModels = false
    @State private var showOfflineStudio = false
    @State private var nsfwSessionUnlocked = false
    @State private var showSavedVideos = false
    @State private var savedVideos: [URL] = []
    @State private var pendingLocalDeletion: URL?
    @State private var localDeletionError = false
    @State private var pcDeletion: (id: String, api: LiveAPI)?
    @State private var failedJobDeletion: (id: String, api: LiveAPI)?
    @State private var deletingPCVideo = false
    @AppStorage("app.text.scale") private var textScale = 0.0
    @State private var clipGame = ""
    @State private var shortClips = false
    @State private var recentJobsFirst = false
    @State private var clipDateRange = 0
    @State private var selectedGameFolder = "Alle"
    @State private var clipRoots: [V2ClipRoots.Root] = []
    @State private var folderClips: [Clip] = []
    @State private var folderNotice: String?
    @State private var saveVideoNotice: String?
    @State private var confirmClear = false
    @State private var hiddenJobs = Set<String>()
    @AppStorage("spaces.notes") private var notes = ""
    @AppStorage("spaces.onboarded") private var onboarded = false
    @AppStorage("spaces.theme") private var theme = "OLED Sort"
    @AppStorage("spaces.font") private var font = "Standard"
    @AppStorage("spaces.motion") private var motion = false
    @AppStorage("spaces.shortcut") private var shortcut = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backgroundPhase = false
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
    @State private var cloudKeyDraft = ""
    @State private var cloudKeySaved = CloudModelKey.exists()
    @State private var cloudKeyNotice: String?

    private var visibleJobs: [Job] {
        model.jobs.filter { job in
            !hiddenJobs.contains(job.id) &&
            (jobFilter == 0 || (jobFilter == 1 && job.status.active) ||
             (jobFilter == 2 && job.status == .completed) || (jobFilter == 3 && job.status == .failed))
        }
    }
    private var pendingJobs: Int { model.jobs.filter { $0.status.active }.count }

    private var homeContent: some View {
        TabView(selection: Binding(get: { selectedModuleTab ?? space.rawValue }, set: { value in
            if let fixed = Space(rawValue: value) {
                selectedModuleTab = nil
                space = fixed
            } else {
                selectedModuleTab = value
            }
        })) {
            NavigationStack { tabPage("Hjem") { header; connectionSettings; loadingStatus; appearanceSettings } }
                .tabItem { Label("Hjem", systemImage: "house.fill") }.tag(Space.brain.rawValue)
            ChatView(api: model.api as? any ChatAPI, demo: model.isDemo, initialDraft: "",
                     connection: model.isDemo ? "Demo · Testdata" : "\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                     storageKey: "spaces.chat." + (model.isDemo ? "demo" : model.address))
                .tabItem { Label("Chat", systemImage: "bubble.left.fill") }.tag(Space.notes.rawValue)
            NavigationStack { tabPage("Video Studio") { videoStudioHeader; clipSection; moodSection; advanced(Binding(get: { model.options }, set: { model.options = $0 })); jobSection } }
                .tabItem { Label("Video", systemImage: "film.fill") }.tag(Space.gallery.rawValue)
            AgentHub(api: model.api as? LiveAPI)
                .tabItem { Label("Landsby", systemImage: "house.lodge.fill") }.tag(Space.tasks.rawValue)
            CodeWorkspaceView(api: model.api as? LiveAPI)
                .tabItem { Label("Code Bot", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(Space.library.rawValue)
            if moduleAddress == model.address, let api = model.api as? LiveAPI {
                ForEach(moduleTabs) { tab in
                    ModuleTabView(tab: tab, api: api)
                        .id(model.address + ":" + tab.id)
                        .tabItem { Label(tab.title, systemImage: tab.kind == "cards" ? "rectangle.on.rectangle" : "info.circle") }
                        .tag("module:" + tab.id)
                }
            }
        }
        .onChange(of: showJobs) { selectedModuleTab = nil; space = .gallery; jobsFocus = true }
        .onChange(of: showClips) { selectedModuleTab = nil; space = .gallery }
        .task(id: "\(model.isDemo):\(model.address):\(phase == .active)") {
            if phase == .active { await loadModuleTabs() }
        }
        .task(id: space) {
            if space == .gallery && !model.isDemo { await loadGameFolders() }
        }
        .onChange(of: space) { _, value in
            selectedModuleTab = nil
            if rememberLastSpace { lastSpace = value.rawValue }
            if autoRefreshTabs && !model.isDemo { Task { await model.refresh() } }
        }
        .onChange(of: keepScreenAwake) { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }
        .onAppear {
            if rememberLastSpace, let saved = Space(rawValue: lastSpace) { space = saved }
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
            VStack(alignment: .leading, spacing: 20, content: content)
                .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .refreshable { await model.refresh(); await loadModuleTabs() }
    }

    private var chatTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Samtal med dit AI-hold").font(.title2.bold())
            action("Åbn chat") { showChat = true }
            action("Privat bot og billeder") { showOfflineStudio = true }
            action("Lokale modeller") { showPhoneModels = true }
        }
    }

    private var villageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Følg dine agenter og deres hverdag").font(.title2.bold())
            action("Åbn landsbyen") { showAgentHub = true }
        }
    }

    private var codeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Beskriv en forbedring, og godkend ændringen").font(.title2.bold())
            action("Åbn Code Bot") { showCodeWorkspace = true }
        }
    }

    private var spacesBar: some View {
        HStack(spacing: 2) {
            ForEach(Space.allCases) { item in
                Button {
                    space = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: spaceIcon(item)).font(.title3)
                        Text(spaceTitle(item)).font(.caption2.bold()).lineLimit(1)
                    }
                    .foregroundStyle(space == item ? Color.cyan : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Åbn " + spaceTitle(item))
                .accessibilityAddTraits(space == item ? .isSelected : [])
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.20)))
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func spaceTitle(_ item: Space) -> String {
        switch item {
        case .brain: "Hjem"
        case .notes: "Noter"
        case .gallery: "Video"
        case .tasks: "Opgaver"
        case .library: "Bibliotek"
        }
    }

    private func spaceIcon(_ item: Space) -> String {
        switch item {
        case .brain: "house.fill"
        case .notes: "note.text"
        case .gallery: "play.rectangle.fill"
        case .tasks: "checklist"
        case .library: "books.vertical.fill"
        }
    }

    @ViewBuilder private var homeBackground: some View {
        if theme == "OLED Sort" {
            Color.black.ignoresSafeArea()
        } else if motion && !reduceMotion && !calmMotion {
            LinearGradient(colors: [.blue.opacity(0.12), .clear],
                           startPoint: backgroundPhase ? .topLeading : .bottomTrailing, endPoint: .center)
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                        backgroundPhase.toggle()
                    }
                }
        }
    }

    private var homeLifecycle: some View {
        homeContent
        .onAppear {
            edit(model.activeProfile)
            setup = model.address.isEmpty || model.isDemo
            prunePreviews()
            openShortcut()
        }
        .onChange(of: shortcut) { openShortcut() }
        .onChange(of: model.error?.title) { _, title in
            errorDetails = false
            if title != nil { errorFocus = true }
        }
        .onChange(of: model.isDemo) { hiddenJobs.removeAll() }
        .onChange(of: model.address) { hiddenJobs.removeAll() }
    }

    private var homeFeedback: some View {
        let completed: [String] = model.jobs.filter { $0.status == .completed }.map(\.id)
        let statuses: [String] = model.jobs.map { $0.id + $0.status.rawValue }
        return homeLifecycle
            .sensoryFeedback(.selection, trigger: appHaptics ? space.rawValue : "")
            .sensoryFeedback(.success, trigger: completed) { old, new in
                new.count > old.count
            }
            .sensoryFeedback(.selection, trigger: statuses) { old, new in
                old.count == new.count && !old.isEmpty
            }
    }

    private var homePresentation: some View {
        let scheme: ColorScheme? = theme == "Lys" ? .light :
            (theme == "Mørk" || theme == "OLED Sort" ? .dark : nil)
        let design: Font.Design = font == "Afrundet" ? .rounded :
            (font == "Monospace" ? .monospaced : .default)
        return ZStack {
            homeBackground
            homeFeedback
        }
        .preferredColorScheme(scheme)
        .fontDesign(design)
    }

    var body: some View {
        homePresentation
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
        .sheet(isPresented: $showAgentHub) {
            AgentHub(api: model.api as? LiveAPI)
        }
        .sheet(isPresented: $showCodeWorkspace) {
            CodeWorkspaceView(api: model.api as? LiveAPI)
        }
        .sheet(isPresented: $showPhoneModels) { PhoneModelsView() }
        .sheet(isPresented: $showOfflineStudio) {
            OfflineStudio(api: model.isDemo ? nil : model.api as? LiveAPI,
                          sessionUnlocked: $nsfwSessionUnlocked)
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
        .task(id: phase) {
            if phase == .active { await model.refresh() }
        }
        .task(id: phase == .active && model.hasActive) {
            guard phase == .active && model.hasActive else { return }
            while !Task.isCancelled && model.hasActive {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !Task.isCancelled { await model.poll() }
            }
        }
        .sheet(item: $media) { item in
            Preview(media: item)
        }
        .sheet(isPresented: $showChat, onDismiss: {
            chatDraft = ""
            if !model.isDemo { Task { await model.refresh() } }
        }) {
            ChatView(api: model.api as? any ChatAPI, demo: model.isDemo, initialDraft: chatDraft,
                     connection: model.isDemo ? "Demo · Testdata" : "\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                     storageKey: "spaces.chat." + (model.isDemo ? "demo" : model.address))
        }
    }


    @ViewBuilder private var header: some View {
        Text("FadedAI").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
        if !model.isDemo && showConnectionBanner {
            Label("\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                  systemImage: model.connected ? "checkmark.circle" : "exclamationmark.circle")
                .font(.subheadline)
        }
        if !model.savedAddresses.isEmpty {
            Menu {
                ForEach(ConnectionProfile.allCases) { profile in
                    Button(profile.title) {
                        if model.savedAddresses[profile] == nil {
                            edit(profile)
                            setup = true
                        } else {
                            Task {
                                await model.selectProfile(profile)
                                edit(profile)
                            }
                        }
                    }
                }
            } label: {
                Label("Skift forbindelse", systemImage: "arrow.left.arrow.right")
                    .frame(minHeight: 48)
            }.disabled(switchDisabled)
        }
        action("Chat med AI-holdet") { showChat = true }
            .disabled(model.busy)
        if model.isDemo {
            Text("Demotilstand · Kun testdata").font(.headline)
        }
        action(pendingJobs == 0 ? "Video Studio" : "Video Studio · \(pendingJobs) aktive") { space = .gallery }
        action("Hvad kan jeg?") { showHelp = true }
        action("Landsbyen og Agent-Hub") { showAgentHub = true }
        action("Start video · Vælg klip") { space = .brain; showClips += 1 }
        action("Gemte videoer") { reloadSavedVideos(); showSavedVideos = true }
        if !onboarded {
            VStack(alignment: .leading, spacing: 8) {
                heading("Kom godt i gang")
                Label("1. Forbind til PC", systemImage: "desktopcomputer")
                Label("2. Vælg klip", systemImage: "film")
                Label("3. Chat med din AI", systemImage: "bubble.left")
                action("Forstået") { onboarded = true }
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
                    else { setup = true }
                }.disabled(switchDisabled)
            }
        }
    }

    @ViewBuilder private var connectionSettings: some View {
        DisclosureGroup("Indstillinger · Forbindelse til PC", isExpanded: $setup) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Profil", selection: $editedProfile) {
                    ForEach(ConnectionProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }.disabled(switchDisabled)
                .onChange(of: editedProfile) { _, profile in edit(profile) }
                Text(editedProfile == .home ? "Indtast PC’ens lokale adresse." : "Indtast PC’ens IPv4-adresse fra Tailscale.")
                TextField("Adresse fra PC’en", text: $address)
                    .accessibilityLabel("PC-adresse")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).textFieldStyle(.roundedBorder)
                    .frame(minHeight: 48)
                SecureField("Adgangskode fra PC’en", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).frame(minHeight: 48)
                action("Test og gem profil") {
                    Task {
                        await model.saveProfile(editedProfile, address: address, token: token)
                        if model.error == nil && !model.isDemo { token = ""; setup = false }
                    }
                }.disabled(switchDisabled)
                Text("\(model.activeProfile.route) · \(model.connected ? "Forbundet til PC" : "Ingen forbindelse")")
                    .font(.headline)
                ForEach(ConnectionProfile.allCases) { profile in
                    action("Skift til \(profile.title)") {
                        edit(profile)
                        if model.savedAddresses[profile] != nil {
                            Task { await model.selectProfile(profile) }
                        }
                    }.disabled(switchDisabled)
                }
            }.padding(.top, 12)
        }.font(.body)
    }

    @ViewBuilder private var loadingStatus: some View {
        if model.busy || model.refreshing || model.mediaLoading {
            LoadingSkeleton(label: model.mediaLoading ? "Henter video…" : "Henter klip og job…")
        }
    }

    @ViewBuilder private var spaceContent: some View {
        @Bindable var model = model
        switch space {
        case .brain:
            if let latest = visibleJobs.max(by: { $0.created_at < $1.created_at }) {
                VStack(alignment: .leading, spacing: 4) {
                    heading("Fortsæt hvor du slap")
                    Text(latest.mood.title + " · " + latest.status.title)
                    action("Åbn Video Studio") { space = .gallery }
                }
            }
            action("Åbn Video Studio") { space = .gallery }
            action("Chat med din AI") { showChat = true }
            action("Besøg pixelbyen") { showAgentHub = true }
        case .notes:
            heading("Noter")
            TextEditor(text: $notes).frame(minHeight: 180)
                .accessibilityLabel("Noter på denne enhed")
        case .gallery:
            videoStudioHeader
            clipSection
            moodSection
            advanced($model.options)
            jobSection
        case .tasks:
            heading("Aktive opgaver")
            if pendingJobs == 0 { Text("Ingen aktive videojobs.") }
            ForEach(model.jobs.filter { $0.status.active }) { job in
                Text(job.mood.title + " · " + job.status.title)
            }
        case .library:
            heading("Promptbibliotek")
            ForEach(PromptExample.examples) { example in
                VStack(alignment: .leading) {
                    Text(example.category).font(.headline)
                    action(example.text) {
                        chatDraft = example.text
                        showChat = true
                    }
                }
            }
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        action("Lokale modeller") { showPhoneModels = true }
        action("NSFW / Uncensored") { showOfflineStudio = true }
        action("Code Bot og Agent Workspace") { showCodeWorkspace = true }
        DisclosureGroup("Visning og jobhistorik") {
            Picker("Tema", selection: $theme) {
                ForEach(["System", "Lys", "Mørk", "OLED Sort"], id: \.self) { Text($0) }
            }
            Slider(value: $textScale, in: 0...5, step: 1) { Text("Tekststørrelse") }
                .accessibilityLabel("Tekststørrelse i appen")
            Picker("Skrift", selection: $font) {
                ForEach(["Standard", "Afrundet", "Monospace"], id: \.self) { Text($0) }
            }
            Toggle("Bevægelse i baggrunden", isOn: $motion)
            Toggle("Bekræft før video startes", isOn: $confirmVideoStart)
            Toggle("Kompakte klipkort", isOn: $compactClipCards)
            Toggle("Vis kliplængde", isOn: $showClipDurations)
            Toggle("Vis jobdetaljer", isOn: $showJobDetails)
            Toggle("Hold skærmen vågen", isOn: $keepScreenAwake)
            Toggle("Haptisk feedback", isOn: $appHaptics)
            Toggle("Ekstra rolig bevægelse", isOn: $calmMotion)
            Toggle("Husk seneste fane", isOn: $rememberLastSpace)
            Toggle("Opdatér ved faneskift", isOn: $autoRefreshTabs)
            Toggle("Vis forbindelsesbanner", isOn: $showConnectionBanner)
            Button("Ryd midlertidige previews") {
                prunePreviews(); saveVideoNotice = "Midlertidige previews er ryddet."
            }.frame(minHeight: 48)
            Button("Ryd afsluttede jobs på denne telefon", role: .destructive) { confirmClear = true }
                .frame(minHeight: 48)
        }
        DisclosureGroup("Valgfri xAI-nøgle") {
            Text("Nøglen gemmes kun i iPhones Keychain. Cloud-chat er ikke aktiv, før en særskilt integration er godkendt.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("xAI API-nøgle", text: $cloudKeyDraft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Gem nøgle") {
                do {
                    try CloudModelKey.save(cloudKeyDraft)
                    cloudKeyDraft = ""; cloudKeySaved = true; cloudKeyNotice = "Nøglen er gemt på telefonen."
                } catch { cloudKeyNotice = "Nøglen kunne ikke gemmes." }
            }.disabled(cloudKeyDraft.isEmpty)
            if cloudKeySaved {
                Button("Fjern nøgle", role: .destructive) {
                    CloudModelKey.remove(); cloudKeySaved = false; cloudKeyNotice = "Nøglen er fjernet."
                }
            }
            if let cloudKeyNotice { Text(cloudKeyNotice).font(.caption) }
        }
    }

    @State private var chatDraft = ""

    private func openShortcut() {
        guard !shortcut.isEmpty else { return }
        let destination = shortcut
        shortcut = ""
        space = .brain
        if destination == "chat" { showChat = true }
    }

    private func edit(_ profile: ConnectionProfile) {
        editedProfile = profile
        address = model.savedAddresses[profile] ?? ""
        token = ""
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

    private var videoStudioHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("VIDEO AGENT", systemImage: "circle.fill")
                .font(.caption.bold()).tracking(3).foregroundStyle(.cyan)
            Text("Skab noget, der rammer.")
                .font(.largeTitle.weight(.light)).accessibilityAddTraits(.isHeader)
            Text("Vælg dine klip. Din agent klarer resten.")
                .font(.title3).foregroundStyle(.secondary)
            action("Hent klip fra PC") { Task { await model.refresh() } }
                .disabled(switchDisabled)
        }
    }

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Spilmappe", selection: $selectedGameFolder) {
                Text("Alle").tag("Alle")
                ForEach(clipRoots) { root in Text(root.label).tag(root.label) }
            }.pickerStyle(.segmented)
            if let folderNotice { Text(folderNotice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    heading("Seneste klip")
                    Text("\(model.selected.count) valgt af maks. \(model.capabilities?.limit ?? 10)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Toggle("Under ét minut", isOn: $shortClips)
                    Toggle("Seneste jobdato først", isOn: $recentJobsFirst)
                    Picker("Jobdato", selection: $clipDateRange) {
                        Text("Alle datoer").tag(0)
                        Text("Seneste 7 dage").tag(7)
                        Text("Seneste 30 dage").tag(30)
                    }
                } label: {
                    Label("Filtrér", systemImage: "magnifyingglass")
                        .frame(minHeight: 44)
                }
            }
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
            HStack {
                Button("Vælg synlige") { model.select(filteredClips) }
                    .disabled(model.busy || filteredClips.isEmpty)
                Spacer()
                Button("Ryd valg") { model.clearSelection() }
                    .disabled(model.busy || model.selected.isEmpty)
            }.frame(minHeight: 44)
            if !model.selected.isEmpty {
                let seconds = model.clips.filter { model.selected.contains($0.id) }.reduce(0) { $0 + $1.duration_seconds }
                Text("Valgt spilletid · \(durationLabel(seconds))")
                    .font(.caption.bold()).foregroundStyle(.cyan)
            }
            if model.clips.isEmpty { Text("Ingen klip at vise.") }
            if !model.clips.isEmpty && filteredClips.isEmpty { Text("Ingen klip matcher filteret.") }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 14) {
                ForEach(filteredClips) { clip in
                    let selected = model.selected.contains(clip.id)
                    Button { model.toggle(clip) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topTrailing) {
                                LinearGradient(colors: [clipColor(clip).opacity(0.38), .black.opacity(0.82)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(selected ? .cyan : .white.opacity(0.75)).padding(8)
                                if showClipDurations {
                                    Text(durationLabel(clip.duration_seconds))
                                        .font(.caption.monospacedDigit()).padding(5)
                                        .background(.black.opacity(0.72), in: Capsule()).padding(8)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                }
                            }
                            .frame(height: compactClipCards ? 76 : 105)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(selected ? Color.cyan : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1))
                            Text(clip.name).font(.subheadline.bold()).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(clip.name), \(durationLabel(clip.duration_seconds))")
                    .accessibilityValue(selected ? "Valgt" : "Ikke valgt")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(model.busy || (!selected && model.selected.count >= (model.capabilities?.limit ?? 0)))
                }
            }
        }.id("clips")
            .padding(16)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.cyan.opacity(0.18)))
    }

    private func durationLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func startVideo(_ mood: Mood) {
        Task {
            await model.submit(mood)
            if model.error == nil || model.uncertain { showJobs += 1 }
        }
    }

    private func clipColor(_ clip: Clip) -> Color {
        let colors: [Color] = [.green, .purple, .blue, .orange, .pink, .teal]
        return colors[abs(clip.id.hashValue) % colors.count]
    }

    @State private var showClips = 0

    private var filteredClips: [Clip] {
        let query = clipGame.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = Dictionary(model.jobs.map { ($0.clip_id, $0.created_at) }, uniquingKeysWith: max)
        let cutoff = Calendar.current.date(byAdding: .day, value: -clipDateRange, to: .now) ?? .distantPast
        let source = selectedGameFolder == "Alle" ? model.clips : folderClips
        let clips = source.filter {
            (selectedGameFolder == "Alle" || $0.folderName?.localizedCaseInsensitiveCompare(selectedGameFolder) == .orderedSame) &&
            (!shortClips || $0.duration_seconds < 60) &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) &&
                (clipDateRange == 0 || (dates[$0.id] ?? .distantPast) >= cutoff)
        }
        if selectedGameFolder != "Alle" {
            return Array(clips.prefix(100))
        }
        guard recentJobsFirst else { return clips }
        return clips.sorted {
            let lhs = dates[$0.id] ?? .distantPast
            let rhs = dates[$1.id] ?? .distantPast
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }

    private func loadGameFolders() async {
        guard let api = model.api as? LiveAPI else { return }
        do {
            let roots = try await api.v2ClipRoots().roots
            clipRoots = roots.filter { $0.label.localizedCaseInsensitiveContains("fortnite") ||
                $0.label.localizedCaseInsensitiveContains("finals") }
            folderClips = []
            for root in clipRoots {
                let page = try await api.v2ClipPage(rootID: root.id, limit: 100)
                folderClips += page.clips.map {
                    Clip(id: $0.id, name: $0.name, duration_seconds: $0.duration_seconds,
                         width: $0.width, height: $0.height, folderName: root.label)
                }
            }
            model.includeFolderClips(folderClips)
            folderNotice = clipRoots.isEmpty ? "Ingen Fortnite- eller The Finals-mapper er sat op på PC’en." : nil
        } catch {
            clipRoots = []; folderClips = []
            folderNotice = "Spilmapper kunne ikke hentes. V1-kliplisten vises stadig under Alle."
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OPSKRIFT").font(.caption.bold()).tracking(4).foregroundStyle(.secondary)
            Text("Vælg din energi").font(.title2.weight(.light))
            if let caps = model.capabilities {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Mood.allCases) { mood in
                        if caps.moods.contains(mood) {
                            Button {
                                selectedVideoMood = mood
                            } label: {
                                Text(mood.title).font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(selectedVideoMood == mood ? .cyan : Color.white.opacity(0.08))
                            .accessibilityAddTraits(selectedVideoMood == mood ? .isSelected : [])
                        }
                    }
                }
            }
            if !model.isDemo {
                Toggle("Kommentator", isOn: Binding(
                    get: { model.options.commentary != false },
                    set: { model.options.commentary = $0 ? nil : false }
                ))
                .disabled(model.busy)
                Text(model.options.commentary == false ? "Video uden tale og undertekster" : "Engelsk reaktion med stemme og undertekster")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let caps = model.capabilities {
                if model.blocked { Text("PC’en er ikke klar til at lave videoer.").font(.headline) }
                if !caps.dependencies.isEmpty {
                    DisclosureGroup("Status på PC’en") {
                        ForEach(caps.dependencies, id: \.name) { dependency in
                            Text(dependency.message)
                        }
                    }
                }
                if caps.moods.isEmpty { Text("PC’en tilbyder ingen stilarter lige nu.") }
                ZStack {
                    LinearGradient(colors: [.green.opacity(0.18), .blue.opacity(0.12), .black],
                                   startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 10) {
                        Image(systemName: "play.circle").font(.system(size: 52, weight: .light))
                        Text("9:16 · Auto crop").font(.caption.monospaced())
                    }
                }
                .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 18))
                Button {
                    if confirmVideoStart { pendingVideoMood = selectedVideoMood }
                    else { startVideo(selectedVideoMood) }
                } label: {
                    Label("Start videomagi", systemImage: "sparkles")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(.borderedProminent).tint(.cyan)
                .disabled(!model.canSubmit || !model.cancelling.isEmpty)
                .accessibilityHint("Starter de valgte klip med \(selectedVideoMood.title)")
            }
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.cyan.opacity(0.18)))
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("3. Følg dine videoer").accessibilityFocused($jobsFocus)
            Picker("Vis jobs", selection: $jobFilter) {
                Text("Alle").tag(0)
                Text("Aktive").tag(1)
                Text("Klar").tag(2)
                Text("Fejl").tag(3)
            }.pickerStyle(.segmented)
            if model.uncertain {
                Text("Starten blev ikke bekræftet. Tjek joblisten for at se, om dine klip allerede er i gang.")
                action("Jeg har tjekket listen") {
                    Task { await model.acknowledgeAfterReview() }
                }.disabled(switchDisabled)
            }
            if visibleJobs.isEmpty { Text("Ingen videoer endnu.") }
            if let saveVideoNotice { Text(saveVideoNotice) }
            ForEach(visibleJobs.sorted { $0.created_at > $1.created_at }) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text(job.mood.title + " · " + job.status.title)
                    Text(job.message)
                    if showJobDetails {
                        Text("\(job.id) · \(job.progress.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if job.status == .failed {
                        action("Prøv igen") { Task { await model.retry(job) } }
                            .disabled(!model.canRetry(job))
                        Button("Skjul fejlet job på telefonen", role: .destructive) {
                            hiddenJobs.insert(job.id)
                        }.frame(minHeight: 44)
                        if !model.isDemo, let api = model.api as? LiveAPI {
                            Button("Slet fejlet job fra PC’en", role: .destructive) {
                                failedJobDeletion = (job.id, api)
                            }.frame(minHeight: 44)
                        }
                    }
                    if job.status.active {
                        let progress = min(1, max(0, job.progress))
                        ProgressView(value: progress)
                            .accessibilityLabel("Fremskridt")
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                        if model.waitingForStop.contains(job.id) {
                            Text("Venter på, at jobbet stopper.")
                        } else if model.capabilities?.features.cancel == true {
                            action(model.cancelling.contains(job.id) ? "Beder PC’en stoppe…" : "Stop job") {
                                Task { await model.cancel(job) }
                            }.disabled(model.cancelling.contains(job.id) || model.busy || model.refreshing)
                        }
                    }
                    if job.status == .completed, job.output_url != nil {
                        action(model.isDemo ? "Se testvideo" : "Se video") {
                            Task {
                                let demo = model.isDemo
                                if let url = await model.video(job) { media = Media(url: url, demo: demo) }
                            }
                        }.disabled(model.mediaLoading)
                        if !model.isDemo {
                            action("Gem på telefonen") { Task { await saveVideo(job) } }.disabled(model.mediaLoading)
                        }
                        if !model.isDemo, let api = model.api as? LiveAPI {
                            Button("Slet redigeret video fra PC’en", role: .destructive) {
                                pcDeletion = (job.id, api)
                            }
                            .frame(minHeight: 44)
                            .disabled(deletingPCVideo || model.mediaLoading)
                        }
                        action("Del job-resultat") {
                            Task {
                                if let url = await model.video(job) { shareResult = Media(url: url, demo: model.isDemo) }
                            }
                        }.disabled(model.mediaLoading)
                    }
                    if !job.warnings.isEmpty || job.error != nil {
                        DisclosureGroup("Detaljer om jobbet") {
                            ForEach(Array(job.warnings.enumerated()), id: \.offset) {
                                Text($0.element)
                            }
                            if let problem = job.error { Text(problem.message) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }.id("jobs")
            .sheet(item: $shareResult) { result in
                ShareLink(item: result.url) {
                    Label("Del video", systemImage: "square.and.arrow.up").frame(minHeight: 48)
                }.padding()
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
                Toggle("Fjern støj", isOn: options.denoise).frame(minHeight: 48)
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
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }
    private func action(_ title: String, _ work: @escaping () -> Void) -> some View {
        Button {
            if appHaptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            work()
        } label: {
            Text(title)
                .frame(minHeight: 48)
                .padding(.horizontal, 16)
                .background {
                    if theme == "OLED Sort" {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.thinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15))
                            }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme == "OLED Sort" ? Color.white : Color.accentColor)
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("village.bots") private var savedBots = Data()
    @State private var draft = VillageBot()
    @State private var importing = false
    @State private var selectedSprite: PhotosPickerItem?
    @State private var exporting = false
    @State private var exportFile: VillageBotFile?
    @State private var notice: String?
    @State private var improving = false
    @State private var testing = false
    @State private var testQuestion = ""
    @State private var testReply = ""

    private var bots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: savedBots)) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mine bots · \(bots.count) af 10") {
                    ForEach(bots) { bot in Button(bot.name) { draft = bot } }
                    Button("Ny bot") { draft = VillageBot() }.disabled(bots.count >= 10)
                    Button("Importér JSON") { importing = true }.disabled(bots.count >= 10)
                }
                editor
                localTest
                if let notice { Text(notice) }
            }
            .navigationTitle("Botbygger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Færdig") {
                        if !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save(draft) }
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importBot)
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                          defaultFilename: "FadedAI-bot") { result in
                if case .failure = result { notice = "Botten kunne ikke eksporteres." }
            }
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
            Picker("Stemme", selection: $draft.voice) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk").tag("en-US")
                ForEach(AVSpeechSynthesisVoice.speechVoices().filter {
                    $0.language == "da-DK" || $0.language == "en-US" || $0.language == "en-GB"
                }, id: \.identifier) { voice in
                    Text(voice.name + " · " + voice.language).tag(voice.identifier)
                }
            }
            Picker("Sprog", selection: Binding(
                get: { draft.language ?? "da-DK" }, set: { draft.language = $0 }
            )) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk").tag("en-US")
                Text("Automatisk").tag("auto")
            }
            VStack(alignment: .leading) {
                Text("Talehastighed · \((draft.voiceRate ?? 1).formatted(.number.precision(.fractionLength(1))))x")
                Slider(value: Binding(get: { draft.voiceRate ?? 1 }, set: { draft.voiceRate = $0 }),
                       in: 0.7...1.3, step: 0.1)
            }
            Toggle("Notifikationer fra botten", isOn: Binding(
                get: { draft.notifications ?? true }, set: { draft.notifications = $0 }
            ))
            Button("Forbedr prompt på telefonen") { Task { await improvePrompt() } }
                .disabled(improving || draft.prompt.isEmpty || !PhoneModels.appleAvailable)
            Button("Gem bot") { save(draft) }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if bots.contains(where: { $0.id == draft.id }) {
                Button("Eksportér bot") { exportFile = VillageBotFile(bot: draft); exporting = true }
                Button("Slet lokal bot", role: .destructive) {
                    persist(bots.filter { $0.id != draft.id })
                    draft = VillageBot()
                }
            }
        }
    }

    private func loadSprite(_ item: PhotosPickerItem, botID: UUID) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary),
              let sprite = UIImage(cgImage: thumbnail).pngData(),
              draft.id == botID, selectedSprite == item else { return }
        draft.sprite = sprite
        selectedSprite = nil
    }

    private var localTest: some View {
        Section("Prøv AI på denne iPhone") {
            Text(PhoneModels.appleAvailable ? "Apple Intelligence er klar." : "Apple Intelligence er ikke tilgængelig lige nu.")
            TextField("Besked til botten", text: $testQuestion, axis: .vertical)
            Button(testing ? "Svarer på telefonen…" : "Prøv på telefonen") {
                Task { await testBot() }
            }
            .frame(minHeight: 44)
            .disabled(testing || !PhoneModels.appleAvailable || testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !testReply.isEmpty {
                Label("Telefon", systemImage: "iphone")
                Text(testReply).textSelection(.enabled)
            }
        }
    }

    private func testBot() async {
        guard !testing else { return }
        testing = true
        testReply = ""
        notice = nil
        defer { testing = false }
        do {
            try await PhoneModels.reply(modelID: "apple", prompt: testQuestion,
                                        instructions: draft.prompt) { testReply = $0 }
        } catch {
            notice = "Telefonen kunne ikke svare. Tjek Apple Intelligence, og prøv igen."
        }
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

private struct AgentHub: View {
    @Environment(\.dismiss) private var dismiss
    let api: LiveAPI?
    @State private var selectedRoom = "research"
    @AppStorage("village.bots") private var localBotsData = Data()
    @State private var localBot: VillageBot?
    @State private var villagePause = false
    @State private var cinematic = false
    @State private var villageZoom: CGFloat = 1
    @State private var villageOffset: CGSize = .zero
    @State private var showBuilder = false
    @State private var offline = false
    @State private var completions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    village
                    if !cinematic {
                        Toggle("Lad lokale bots hvile", isOn: $villagePause)
                        Text("Lokale bots følger telefonens ur. PC-agenter følger deres live-status.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if offline { Text("PC’en er offline. Botsene hviler.") }
                    if !cinematic {
                    Button("Botbygger", systemImage: "person.crop.circle.badge.plus") { showBuilder = true }
                        .frame(minHeight: 48)
                    if let failure {
                        RetryNotice(message: failure) { attempt += 1 }
                    }
                    if let snapshot {
                    missionHUD(snapshot.summary)
                    Picker("Rum", selection: $selectedRoom) {
                        ForEach(snapshot.rooms) { room in Text(room.name).tag(room.id) }
                    }.frame(minHeight: 48)
                    ForEach(snapshot.agents.filter { $0.room_id == selectedRoom }) { agent in
                        agentCard(agent)
                    }
                    Button("Achievements", systemImage: "trophy") { achievements = true }
                        .frame(minHeight: 48)
                    } else if failure == nil {
                        LoadingSkeleton(label: "Henter agenter…")
                    }
                    }
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .navigationTitle("Landsbyen")
            .toolbarVisibility(cinematic ? .hidden : .visible, for: .navigationBar)
            .sensoryFeedback(.success, trigger: completions)
            .sheet(isPresented: $showBuilder) { VillageBotBuilder() }
            .sheet(item: $localBot) { bot in
                NavigationStack {
                    List {
                        Text("Lokal bot")
                        if !bot.prompt.isEmpty { Text(bot.prompt) }
                        Button("Åbn Botbygger") {
                            localBot = nil
                            showBuilder = true
                        }
                    }
                    .navigationTitle(bot.name)
                    .toolbar { Button("Luk") { localBot = nil } }
                }
            }
            .task(id: attempt) { await followHub() }
            .refreshable { attempt += 1 }
            .toolbar { Button("Luk") { dismiss() } }
            .sheet(item: $details) { agent in agentDetails(agent) }
            .sheet(isPresented: $achievements) { achievementPage }
        }
    }

    private var village: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 60 : 0.25)) { timeline in
            let hour = Calendar.current.component(.hour, from: timeline.date)
            let night = hour < 7 || hour >= 20
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(night ? Color(red: 0.03, green: 0.06, blue: 0.14) :
                            Color(red: 0.10, green: 0.19, blue: 0.29))
                    Canvas { context, canvas in
                        let pixelRect: (CGRect) -> Path = { frame in Path { $0.addRect(frame) } }
                        let diamond: (CGPoint, CGFloat, CGFloat) -> Path = { center, width, height in
                            Path { path in
                                path.move(to: CGPoint(x: center.x, y: center.y - height / 2))
                                path.addLine(to: CGPoint(x: center.x + width / 2, y: center.y))
                                path.addLine(to: CGPoint(x: center.x, y: center.y + height / 2))
                                path.addLine(to: CGPoint(x: center.x - width / 2, y: center.y))
                                path.closeSubpath()
                            }
                        }
                        let quad: (CGPoint, CGPoint, CGPoint, CGPoint) -> Path = { a, b, c, d in
                            Path { path in
                                path.move(to: a); path.addLine(to: b)
                                path.addLine(to: c); path.addLine(to: d); path.closeSubpath()
                            }
                        }
                        context.fill(pixelRect(CGRect(origin: .zero, size: canvas)),
                                     with: .color(night ? Color(red: 0.04, green: 0.14, blue: 0.15) : Color(red: 0.10, green: 0.34, blue: 0.22)))
                        let tile: CGFloat = 12
                        for row in 0..<Int(canvas.height / tile) {
                            for column in 0..<Int(canvas.width / tile) where (row * 7 + column * 11) % 13 == 0 {
                                context.fill(pixelRect(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                                                         width: 4, height: 4)),
                                             with: .color(.green.opacity(night ? 0.18 : 0.38)))
                            }
                        }
                        context.fill(pixelRect(CGRect(x: canvas.width * 0.46, y: 0, width: 26, height: canvas.height)),
                                     with: .color(Color(red: 0.70, green: 0.59, blue: 0.40).opacity(0.78)))
                        context.fill(pixelRect(CGRect(x: 0, y: canvas.height * 0.48, width: canvas.width, height: 26)),
                                     with: .color(Color(red: 0.70, green: 0.59, blue: 0.40).opacity(0.78)))
                        for zone in 0..<4 {
                            let center = villagePoint(zone, size: canvas)
                            let colors: [Color] = [.indigo, .blue, .orange, .purple]
                            let x = center.x, y = center.y
                            context.fill(diamond(CGPoint(x: x + 10, y: y + 41), 154, 86),
                                         with: .color(.black.opacity(0.34)))
                            context.fill(diamond(CGPoint(x: x, y: y + 22), 148, 80),
                                         with: .color(Color(red: 0.36, green: 0.48, blue: 0.39)))
                            context.fill(quad(CGPoint(x: x - 57, y: y - 28), CGPoint(x: x, y: y + 1),
                                              CGPoint(x: x, y: y + 47), CGPoint(x: x - 57, y: y + 18)),
                                         with: .color(colors[zone].opacity(0.72)))
                            context.fill(quad(CGPoint(x: x, y: y + 1), CGPoint(x: x + 57, y: y - 28),
                                              CGPoint(x: x + 57, y: y + 18), CGPoint(x: x, y: y + 47)),
                                         with: .color(colors[zone].opacity(0.48)))
                            context.fill(diamond(CGPoint(x: x, y: y - 29), 132, 66),
                                         with: .color(colors[zone].opacity(0.96)))
                            context.stroke(diamond(CGPoint(x: x, y: y - 29), 132, 66),
                                           with: .color(.white.opacity(0.38)), lineWidth: 2)
                            context.fill(quad(CGPoint(x: x - 13, y: y + 13), CGPoint(x: x, y: y + 20),
                                              CGPoint(x: x, y: y + 45), CGPoint(x: x - 13, y: y + 38)),
                                         with: .color(.black.opacity(0.56)))
                            context.fill(quad(CGPoint(x: x + 17, y: y + 17), CGPoint(x: x + 34, y: y + 8),
                                              CGPoint(x: x + 34, y: y + 22), CGPoint(x: x + 17, y: y + 31)),
                                         with: .color(night ? .yellow.opacity(0.84) : .cyan.opacity(0.82)))
                        }
                        for tree in 0..<12 {
                            let x = canvas.width * (0.08 + Double((tree * 31) % 83) / 100)
                            let y = canvas.height * (0.11 + Double((tree * 47) % 75) / 100)
                            context.fill(pixelRect(CGRect(x: x + 4, y: y + 6, width: 4, height: 9)), with: .color(.brown))
                            context.fill(pixelRect(CGRect(x: x, y: y, width: 13, height: 10)),
                                         with: .color(Color(red: 0.08, green: 0.52, blue: 0.30)))
                        }
                        if offline {
                            let phase = reduceMotion ? 0 : Int(timeline.date.timeIntervalSince1970 * 24) % 100
                            for drop in 0..<30 {
                                let x = canvas.width * Double((drop * 37) % 100) / 100
                                let y = canvas.height * Double((drop * 61 + phase) % 100) / 100
                                let line = Path { path in
                                    path.move(to: CGPoint(x: x, y: y))
                                    path.addLine(to: CGPoint(x: x - 4, y: y + 10))
                                }
                                context.stroke(line, with: .color(.cyan.opacity(0.45)), lineWidth: 1)
                            }
                        }
                    }.accessibilityHidden(true)
                    ForEach(Array(["Research Lab", "Video Studio", "Kaffeområde", "Sovekrog"].enumerated()), id: \.offset) { item in
                        let point = villagePoint(item.offset, size: size)
                        Label(item.element, systemImage: ["books.vertical.fill", "film.fill", "cup.and.saucer.fill", "moon.stars.fill"][item.offset])
                            .font(.caption2.bold()).labelStyle(.titleAndIcon)
                            .position(x: point.x, y: point.y + 25)
                    }
                    ForEach(Array((snapshot?.agents ?? []).enumerated()), id: \.element.id) { item in
                        villageAvatar(item.element, index: item.offset, time: timeline.date.timeIntervalSinceReferenceDate, size: size)
                    }
                    ForEach(Array(localVillageBots.enumerated()), id: \.element.id) { item in
                        localVillageAvatar(item.element, index: item.offset, hour: hour,
                                           time: timeline.date.timeIntervalSinceReferenceDate, size: size)
                    }
                }
                .scaleEffect(villageZoom)
                .offset(villageOffset)
                .gesture(MagnifyGesture().onChanged { villageZoom = min(2, max(1, $0.magnification)) })
                .simultaneousGesture(DragGesture().onChanged { villageOffset = $0.translation })
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }.frame(height: 420)
        }
        .overlay(alignment: .topTrailing) {
            Button(cinematic ? "Vis menu" : "Filmtilstand", systemImage: cinematic ? "eye" : "video") {
                cinematic.toggle()
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(cinematic ? "Afslut filmtilstand" : "Start filmtilstand")
            .frame(minWidth: 48, minHeight: 48)
            .foregroundStyle(.white)
        }
    }

    private var localVillageBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: localBotsData)) ?? []
    }

    private func localVillageAvatar(_ bot: VillageBot, index: Int, hour: Int, time: TimeInterval, size: CGSize) -> some View {
        let sleeping = offline || villagePause || hour < 7 || hour >= 22
        let routine = (hour + index) % 3
        let zone = sleeping ? 3 : routine
        let center = villagePoint(zone, size: size)
        let personality = bot.personality ?? "Nysgerrig"
        let routines: [String] = switch personality {
        case "Rolig": ["Læser i biblioteket", "Ordner studiet", "Drikker te"]
        case "Sjov": ["Finder på historier", "Øver en scene", "Fortæller jokes"]
        case "Omsorgsfuld": ["Hjælper i laboratoriet", "Hjælper med video", "Laver kaffe til holdet"]
        default: ["Undersøger nye idéer", "Øver sig i studiet", "Holder kaffepause"]
        }
        let activity = sleeping ? "Sover" : routines[routine]
        let color: Color = bot.color == "Grøn" ? .green : bot.color == "Lilla" ? .purple : .cyan
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
                }.frame(width: 38, height: 38).opacity(sleeping ? 0.55 : 1)
                Text(bot.name).font(.caption2.bold()).lineLimit(1)
                if !sleeping { Text(activity).font(.system(size: 8)).lineLimit(1) }
            }.frame(width: 92, height: 66)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.name + ", " + (bot.personality ?? "Nysgerrig") + ", " + activity)
        .position(x: center.x + CGFloat(index % 5 - 2) * 23 + (reduceMotion || sleeping ? 0 : CGFloat(sin(time * 0.7 + Double(index))) * 18),
                  y: center.y + 42 + CGFloat(index / 5) * 20 + (reduceMotion || sleeping ? 0 : CGFloat(cos(time * 0.7 + Double(index))) * 8))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.75), value: zone)
    }

    private func villagePoint(_ zone: Int, size: CGSize) -> CGPoint {
        let columns = [0.27, 0.73, 0.27, 0.73]
        let rows = [0.28, 0.37, 0.65, 0.74]
        return CGPoint(x: size.width * columns[zone], y: size.height * rows[zone])
    }

    private func villageAvatar(_ agent: V2Hub.Agent, index: Int, time: TimeInterval, size: CGSize) -> some View {
        let sleeping = offline || agent.status == .offline
        let resting = agent.status == .ready
        let zone = sleeping ? 3 : resting ? 2 : agent.room_id.lowercased().contains("video") ? 1 : 0
        let point = villagePoint(zone, size: size)
        let offset = CGFloat(index % 4) * 29 - 43.5
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
            .frame(width: 42, height: 42)
            .opacity(sleeping ? 0.55 : 1)
            .modifier(AgentPulse(active: !sleeping && !resting))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name + ", " + (sleeping ? "Hviler" : status(agent.status)))
        .contextMenu {
            if !cinematic {
                Button("Vis historik og hukommelse") { details = agent }
            }
        }
        .position(x: point.x + offset + (reduceMotion || sleeping ? 0 : CGFloat(sin(time * 0.55 + Double(index))) * 16),
                  y: point.y - 5 - CGFloat(index / 4) * 28 + (reduceMotion || sleeping ? 0 : CGFloat(cos(time * 0.55 + Double(index))) * 7))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.75), value: zone)
    }

    private func missionHUD(_ summary: V2Hub.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mission HUD").font(.headline).accessibilityAddTraits(.isHeader)
            Label("Aktive agenter · \(summary.active_agents)", systemImage: "person.2")
            Label("Aktive jobs · \(summary.active_jobs)", systemImage: "film")
            Label("XP i alt · \(summary.total_xp)", systemImage: "bolt")
            Label("Streak · \(summary.streak_days) dage", systemImage: "flame")
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
    }

    private func agentCard(_ agent: V2Hub.Agent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { details = agent } label: {
                Label(agent.name, systemImage: icon(agent.icon)).font(.headline)
                    .frame(minHeight: 48)
            }.buttonStyle(.bordered)
            Text(status(agent.status)).font(.subheadline)
            ProgressView(value: Double(agent.xp_in_level), total: Double(max(1, agent.xp_for_next_level))) {
                Text("Niveau \(agent.level) · \(agent.xp_in_level) / \(agent.xp_for_next_level) XP")
            }
            Text("Quest Log").font(.headline)
            let quests = agent.recent_quests.sorted { $0.updated_at > $1.updated_at }
            if quests.isEmpty { Text("Ingen opgaver endnu.") }
            ForEach(quests.prefix(3)) { quest in
                Text(quest.title + " · " + questStatus(quest.state))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            .modifier(AgentPulse(active: agent.status == .working || agent.status == .thinking))
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
        do {
            while !Task.isCancelled {
                let initial = try await api.v2Hub()
                apply(initial)
                try await api.v2HubEvents(after: initial.revision) { event in
                    guard let updated = try? await api.v2Hub() else { return }
                    await MainActor.run {
                        if !Task.isCancelled, event.type == .resync_required || updated.revision >= (snapshot?.revision ?? 0) {
                            apply(updated)
                        }
                    }
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            if !Task.isCancelled {
                if let networkError = error as? URLError {
                    offline = [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
                               .timedOut, .cannotFindHost].contains(networkError.code)
                }
                failure = "Kunne ikke hente Agent-Hub. Tjek forbindelsen til PC’en."
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline)
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion)) { context in
                let opacity = reduceMotion ? 0.22 : 0.22 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([1.0, 0.72, 0.48], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.secondary.opacity(opacity))
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
            Button(action: retry) { Text("Prøv igen").frame(minHeight: 48) }
                .buttonStyle(.bordered)
        }
    }
}

private struct AgentPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || reduceMotion)) { context in
            let intensity = active && !reduceMotion
                ? 0.18 + 0.12 * sin(context.date.timeIntervalSinceReferenceDate * 2)
                : 0.0
            content.overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.blue.opacity(intensity), lineWidth: 2)
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

private struct ModuleTabView: View {
    let tab: ModuleTab
    let api: LiveAPI
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
            .navigationTitle(tab.title)
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

private struct CodeWorkspaceView: View {
    private struct FeatureDraft: Decodable {
        let feasible: Bool
        let reason: String
        let content: String?
        let tests: [String]
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
    @Environment(\.dismiss) private var dismiss
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
    @State private var codeStatus = ""
    @State private var testPlan: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Code Bot").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Filer bliver kun læst og skrevet i den sikre Agent Workspace-mappe på PC’en.")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Autonomi").font(.title2.bold())
                        Picker("Code Bot-autonomi", selection: $autonomy) {
                            ForEach(Autonomy.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                        }.pickerStyle(.segmented)
                        Text(Autonomy(rawValue: autonomy)?.explanation ?? Autonomy.strict.explanation)
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Aktive filer og kontekst").font(.title2.bold())
                            Spacer()
                            if loading { ProgressView().accessibilityLabel("Henter Agent Workspace") }
                        }
                        if files.isEmpty && !loading { Text("Ingen tekstfiler i Agent Workspace endnu.") }
                        ForEach(files) { file in
                            Button {
                                if selected.contains(file.path) { selected.remove(file.path) }
                                else { selected.insert(file.path) }
                                persistContext()
                                Task { await open(file.path) }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(file.path).lineLimit(2)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.frame(minHeight: 52)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("\(file.path), \(selected.contains(file.path) ? "valgt som kontekst" : "ikke valgt")")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Byg en lille funktion med PC-modellen").font(.title2.bold())
                        Text("Vælg eller skriv en filsti, beskriv én afgrænset ændring, og gennemgå altid diffen før godkendelse.")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("Beskriv funktionen", text: $featureRequest, axis: .vertical)
                            .lineLimit(2...6).textFieldStyle(.roundedBorder)
                        Button("Lad Code Bot forberede ændringen") { Task { await generateFeature() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(api == nil || loading || path.isEmpty || featureRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !codeStatus.isEmpty { Text(codeStatus).font(.caption).foregroundStyle(.cyan) }
                    }.padding().background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Forbered filændring").font(.title2.bold())
                        TextField("Relativ filsti", text: $path).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Filsti i Agent Workspace")
                        TextEditor(text: $content).frame(minHeight: 180)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.35)))
                            .accessibilityLabel("Nyt filindhold")
                        Button("Forbered ændring") { Task { await prepare() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(api == nil || loading || path.isEmpty)
                    }

                    if let proposal {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Kræver din godkendelse", systemImage: "lock.shield")
                                .font(.headline).foregroundStyle(.orange)
                            ScrollView(.horizontal) {
                                Text(proposal.diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }.frame(maxHeight: 260)
                            if !testPlan.isEmpty {
                                Text("Testplan").font(.headline)
                                ForEach(Array(testPlan.enumerated()), id: \.offset) { item in
                                    Text("\(item.offset + 1). \(item.element)")
                                }
                            }
                            HStack {
                                Button("Afvis", role: .destructive) { Task { await reject(proposal) } }
                                    .buttonStyle(.bordered).controlSize(.large)
                                Button("Godkend ændring") { approval = true }
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                            }
                        }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if let message {
                        Text(message).padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel(message)
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Agent Workspace")
            .toolbar { Button("Luk") { dismiss() }.accessibilityLabel("Luk Agent Workspace") }
            .refreshable { await load() }
            .task { restoreContext(); await load() }
            .confirmationDialog("Godkend filændringen?", isPresented: $approval, presenting: proposal) { item in
                Button("Skriv filen", role: .destructive) { Task { await apply(item) } }
            } message: { item in
                Text("Kun \(item.path) i Agent Workspace bliver ændret.")
            }
        }.preferredColorScheme(.dark)
    }

    private func load() async {
        guard let api else { message = "Forbind til PC’en for at åbne Agent Workspace."; return }
        loading = true; defer { loading = false }
        do { files = try await api.v2CodeWorkspace().files; message = nil }
        catch { message = "Agent Workspace kunne ikke hentes. Tryk og prøv igen." }
    }

    private func open(_ file: String) async {
        guard let api else { return }
        do { let found = try await api.v2CodeFile(path: file); path = found.path; content = found.content }
        catch { message = "Filen kunne ikke åbnes sikkert." }
    }

    private func prepare() async {
        guard let api else { return }
        proposal = nil
        testPlan = []
        loading = true; defer { loading = false }
        do { proposal = try await api.v2CodeProposal(path: path, content: content); message = nil }
        catch { message = "Ændringen kunne ikke forberedes. Tjek filstien og prøv igen." }
    }

    private func generateFeature() async {
        guard let api else { return }
        let brief = featureRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { return }
        guard content.count <= 1_200 else {
            codeStatus = "Filen er for stor til sikker automatisk omskrivning. Vælg en mindre fil eller opret en ny komponentfil."
            return
        }
        proposal = nil
        testPlan = []
        loading = true; codeStatus = "PC-modellen forbereder filen…"
        defer { loading = false }
        do {
            let target = path
            let prompt = "Analysér filen og opgaven. Foreslå kun en direkte anvendelig ændring, der kan laves i denne fil med de viste forudsætninger. Ved manglende kontekst eller afhængigheder: feasible=false og forklar hvorfor. Svar kun JSON med feasible (bool), reason (tekst), content (hele nye filen eller null), tests (liste med konkrete testtrin). Fil: \(target)\nOpgave: \(brief)\nIndhold:\n\(content)"
            let request = try V2ChatRequest(message: prompt, sessionID: UUID().uuidString)
            var generated = ""
            try await api.v2Chat(request) { event in
                await MainActor.run {
                    if event.type == .text { generated += event.content }
                    if event.type == .tool_status { codeStatus = event.content }
                }
            }
            let result = try JSONDecoder().decode(FeatureDraft.self, from: Data(generated.utf8))
            guard result.feasible else {
                codeStatus = String(result.reason.prefix(300))
                return
            }
            let plan = result.tests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let cleaned = result.content, !cleaned.isEmpty, cleaned != content,
                  (1...6).contains(plan.count), plan.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
                  path == target else { throw V2Failure.invalidResponse }
            proposal = try await api.v2CodeProposal(path: target, content: cleaned)
            content = cleaned
            testPlan = plan
            codeStatus = "Forslaget er klar. Gennemgå diff og testplan."
        } catch {
            codeStatus = "Code Bot kunne ikke forberede ændringen. Ingen fil blev skrevet."
        }
    }

    private func reject(_ item: V2CodeProposal) async {
        guard let api else { return }
        do { _ = try await api.v2ApplyCodeProposal(item.change_id, approved: false) }
        catch { /* A rejection is confirmed by the server's NOT_READY response. */ }
        proposal = nil
        message = "Ændringen blev afvist. Intet blev skrevet."
    }

    private func apply(_ item: V2CodeProposal) async {
        guard let api else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: true)
            proposal = nil
            message = result.applied ? "Ændringen er skrevet til \(result.path)." : "Intet blev ændret."
            await load()
        } catch { message = "PC’en bekræftede ikke ændringen. Intet nyt forsøg blev sendt." }
    }

    private func persistContext() {
        UserDefaults.standard.set(Array(selected).sorted(), forKey: "code.active.context")
    }

    private func restoreContext() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "code.active.context") ?? [])
    }
}

private struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    let api: (any ChatAPI)?
    let demo: Bool
    let initialDraft: String
    let connection: String
    let storageKey: String
    @State private var sessionID = UUID()
    @State private var draft = ""
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
    @State private var modelsLoading = true
    @State private var modelsError: String?
    @State private var legacyChat = false
    @State private var completedReplies = 0
    @AppStorage("phone.model") private var phoneModel = "apple"
    @State private var usePC = false
    @State private var dictation = ChatDictation()
    @State private var speech = AVSpeechSynthesizer()
    @AppStorage("chat.voiceMode") private var voiceMode = false
    @AppStorage("chat.voiceBot") private var voiceBotID = ""
    @AppStorage("village.bots") private var voiceBotData = Data()
    @FocusState private var composerFocused: Bool
    @State private var chatSearch = ""
    @State private var favoritesOnly = false
    @State private var scrollRequest = 0
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

    private var voiceBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: voiceBotData)) ?? []
    }

    private var voiceControls: some View {
        DisclosureGroup("Oplæsning på telefonen") {
            Toggle("Læs færdige svar op", isOn: $voiceMode)
            if !voiceBots.isEmpty {
                Picker("Botstemme", selection: $voiceBotID) {
                    Text("Dansk standard").tag("")
                    ForEach(voiceBots) { bot in Text(bot.name).tag(bot.id.uuidString) }
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
        let choice = bot?.voice ?? bot?.language ?? "da-DK"
        utterance.voice = AVSpeechSynthesisVoice(identifier: choice) ??
            AVSpeechSynthesisVoice(language: choice) ?? AVSpeechSynthesisVoice(language: "da-DK")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(bot?.voiceRate ?? 1)
        speech.speak(utterance)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.cyan.gradient).frame(width: 58, height: 58)
                                .overlay(Image(systemName: "sparkles").font(.title2).foregroundStyle(.black))
                            VStack(alignment: .leading) {
                                Text("Tal med din AI").font(.title.bold()).accessibilityAddTraits(.isHeader)
                                Text(connection).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if !models.isEmpty {
                                Menu {
                                    ForEach(models.filter(\.available), id: \.id) { entry in
                                        Button(entry.label) { selectedModel = entry.id }
                                    }
                                } label: {
                                    Label(models.first(where: { $0.id == selectedModel })?.label ?? "Model",
                                          systemImage: "chevron.down")
                                        .font(.caption.bold()).lineLimit(1)
                                }
                                .disabled(task != nil)
                                .accessibilityLabel("Skift AI-model")
                            }
                        }
                        DisclosureGroup("Chatindstillinger") {
                            VStack(alignment: .leading, spacing: 12) {
                                StatsBar(turns: turns.count, streaming: task != nil)
                                Toggle("Brug PC til næste svar", isOn: $usePC).disabled(task != nil)
                                Text("Korte svar forsøges på telefonen. PC-opgaver sendes til din PC.")
                                    .font(.caption).foregroundStyle(.secondary)
                                modelControls
                                voiceControls
                                aiBoostControls
                                if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                                Text("Researcher bruger internettet, når en websøgning er nødvendig.")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("Søg i samtalen", text: $chatSearch).textFieldStyle(.roundedBorder)
                                Toggle("Vis kun favoritter", isOn: $favoritesOnly)
                                ShareLink(item: conversationText) {
                                    Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                                        .frame(minHeight: 44)
                                }.disabled(turns.isEmpty)
                            }.padding(.top, 8)
                        }
                        transcriptRows
                        if aiShowTools && !searchSteps.isEmpty {
                            DisclosureGroup("Agentaktivitet · \(searchSteps.count) trin") {
                                ForEach(searchSteps.indices, id: \.self) { index in
                                    Label(searchSteps[index], systemImage: index + 1 == searchSteps.count ? "circle.fill" : "arrow.down.circle")
                                }
                            }
                        }
                        if let status { Text(status).font(.callout).foregroundStyle(.cyan) }
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
                .onChange(of: draft) { UserDefaults.standard.set(draft, forKey: storageKey + ".draft") }
                .safeAreaInset(edge: .bottom) { composer }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left") { stop(); dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Ny samtale", systemImage: "square.and.pencil") { newConversation() }
                            .disabled(task != nil)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    draft = initialDraft
                    loadHistory()
                    if draft.isEmpty { draft = UserDefaults.standard.string(forKey: storageKey + ".draft") ?? initialDraft }
                    scrollChat(proxy)
                }
                .onDisappear { stop(); dictation.stop(); speech.stopSpeaking(at: .immediate) }
                .task { await loadModels() }
                .sensoryFeedback(.success, trigger: completedReplies)
            }
        }
    }

    private func scrollChat(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if task == nil {
                HStack {
                    Menu("Skabeloner") {
                        ForEach(PromptExample.examples) { example in
                            Button(example.text) { draft = example.text }
                        }
                    }.frame(minHeight: 44)
                    Spacer()
                    Button {
                        if dictation.active { dictation.stop() }
                        else {
                            let prefix = draft.isEmpty ? "" : draft + " "
                            Task { await dictation.start { draft = prefix + $0 } }
                        }
                    } label: {
                        Image(systemName: dictation.active ? "stop.circle" : "mic")
                            .frame(minWidth: 48, minHeight: 48)
                    }.accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
                }
                if let problem = dictation.problem { Text(problem).font(.caption) }
            }
            TextField("Din besked", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5).frame(minHeight: 48)
                .focused($composerFocused)
            HStack {
                Text("\(draft.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(draft.count > 2000 ? Color.red : Color.secondary)
                Spacer()
                Button("Ryd") { draft = "" }.disabled(draft.isEmpty || task != nil)
                Button("Nyeste", systemImage: "arrow.down") { composerFocused = false; scrollRequest += 1 }
                    .accessibilityHint("Flytter fokus væk fra tastaturet og viser den nyeste besked")
            }.frame(minHeight: 36)
            if task != nil {
                Button { stop() } label: { Text("Stop modtagelse").frame(minHeight: 48) }
                    .buttonStyle(.bordered)
            } else {
                Button { send() } label: { Text("Send besked").frame(minHeight: 48) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 2000)
            }
        }.padding(12).background(.regularMaterial)
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
                Toggle("Privat session uden historik", isOn: $aiPrivateSession)
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

    private var transcriptRows: some View {
        ForEach(filteredTurns) { turn in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 44)
                    Text(turn.prompt)
                        .padding(12)
                        .background(.cyan.opacity(0.20), in: RoundedRectangle(cornerRadius: 17))
                }
                if !turn.reply.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(turn.source ?? "AI", systemImage: turn.source == "Telefon" ? "iphone" : "desktopcomputer")
                            .font(.caption.bold()).foregroundStyle(.cyan)
                        if aiTimestamps, let date = turn.createdAt {
                            Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                        }
                        ChatTranscriptView(reply: turn.reply)
                        if aiWordCount {
                            Text("\(turn.reply.split(whereSeparator: \.isWhitespace).count) ord")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Læs svaret op", systemImage: "speaker.wave.2") { speak(turn.reply) }
                            .frame(minHeight: 44)
                        HStack {
                            Button(turn.favorite == true ? "Fjern favorit" : "Favorit",
                                   systemImage: turn.favorite == true ? "star.fill" : "star") { toggleFavorite(turn.id) }
                            Button("Slet", systemImage: "trash", role: .destructive) { deleteTurn(turn.id) }
                            Button("Godt svar", systemImage: turn.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") {
                                setFeedback(turn.id, value: 1)
                            }.labelStyle(.iconOnly).accessibilityLabel("Markér som godt svar")
                            Button("Dårligt svar", systemImage: turn.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                                setFeedback(turn.id, value: -1)
                            }.labelStyle(.iconOnly).accessibilityLabel("Markér som dårligt svar")
                        }.frame(minHeight: 44)
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }
                if let notice = turn.notice {
                    RetryNotice(message: notice) { draft = turn.prompt }.disabled(task != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
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

    private var filteredTurns: [ChatTurn] {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return turns.filter { turn in
            (!favoritesOnly || turn.favorite == true) &&
            (query.isEmpty || turn.prompt.localizedCaseInsensitiveContains(query) || turn.reply.localizedCaseInsensitiveContains(query))
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
        let available = max(0, 2000 - message.count - prefix.count - suffix.count)
        guard available > 0 else { return String(message.prefix(2000)) }
        return message + prefix + String(rules.joined(separator: "; ").prefix(available)) + suffix
    }

    private func send() {
        dictation.stop()
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task == nil, !message.isEmpty else { return }
        draft = ""
        searchSteps = []
        sourceExcerpt = localReference(for: message)
        streamedText = ""
        turns.append(ChatTurn(prompt: message, createdAt: .now))
        let index = turns.count - 1
        let context = turns.dropLast().suffix(6).filter { !$0.reply.isEmpty }
            .map { "Bruger: \($0.prompt)\nSvar: \($0.reply)" }.joined(separator: "\n")
        let collectionQuestion = message.lowercased().hasPrefix("kortsamling:")
        let modelMessage = collectionQuestion ? message : enhancedPrompt(message)
        let requiresPC = usePC || collectionQuestion ||
            PhoneModels.prefersPC(modelMessage, previousCharacters: context.count)
        status = "Venter på svar…"
        let input = ChatRequest(message: modelMessage, session_id: sessionID)
        save(pending: true)
        task = Task {
            do {
                if demo {
                    status = "Demo · Finder et testklip…"
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply = "Jeg fandt et testklip. "
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply += "Demoen starter ikke et video-job."
                } else {
                    var answered = false
                    if !requiresPC {
                        answered = try await answerOnPhone(modelMessage, context: context, index: index)
                    }
                    if !answered { try await answerOnPC(input, index: index) }
                }
                if turns[index].notice == nil {
                    completedReplies += 1
                    if voiceMode && !turns[index].reply.isEmpty && !dictation.active {
                        speak(turns[index].reply)
                    }
                }
            } catch is CancellationError {
                turns[index].notice = "Modtagelsen er stoppet."
            } catch {
                turns[index].notice = error is V2Failure ? v2Message(error)
                    : (error as? ChatFailure ?? .interrupted).message
            }
            status = nil
            task = nil
            save()
        }
    }

    private func answerOnPhone(_ message: String, context: String, index: Int) async throws -> Bool {
        status = "Telefon · Forbereder svar…"
        let prompt = context.isEmpty ? message : "\(context)\nBruger: \(message)"
        do {
            try await PhoneModels.reply(modelID: phoneModel, prompt: prompt) { answer in
                turns[index].source = "Telefon"
                turns[index].reply = safeText(answer)
                streamedText = answer
            }
            turns[index].reply = safeText(streamedText, complete: true)
            return true
        } catch {
            try Task.checkCancellation()
            if !turns[index].reply.isEmpty {
                turns[index].notice = "Telefonsvaret blev afbrudt."
                return true
            }
            return false
        }
    }

    private func answerOnPC(_ input: ChatRequest, index: Int) async throws {
        guard let api else {
            turns[index].notice = "Denne besked kræver en model, der er klar. Forbind til PC’en, eller vælg en lokal model i Indstillinger."
            return
        }
        turns[index].source = "PC"
        status = "PC · Venter på svar…"
        if let live = api as? LiveAPI, !legacyChat {
            let request = try V2ChatRequest(message: input.message, sessionID: sessionID.uuidString,
                                            modelID: selectedModel.isEmpty ? nil : selectedModel)
            try await live.v2Chat(request) { event in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    receive(type: event.type.rawValue, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
        } else {
            await run(api, input: input, index: index)
        }
    }

    private func run(_ api: any ChatAPI, input: ChatRequest, index: Int) async {
        do {
            try await api.chat(input) { event in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    receive(type: event.type, content: event.content, index: index)
                }
            }
            try Task.checkCancellation()
        } catch {
            turns[index].notice = Task.isCancelled ? "Modtagelsen er stoppet. Et job kan stadig køre."
                : (error as? ChatFailure ?? .interrupted).message
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
        if !turns.isEmpty, let data = try? JSONEncoder().encode(turns) {
            UserDefaults.standard.set(data, forKey: storageKey + ".previous")
        }
        turns = []
        draft = ""
        UserDefaults.standard.removeObject(forKey: storageKey + ".draft")
        searchSteps = []
        sourceExcerpt = nil
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
