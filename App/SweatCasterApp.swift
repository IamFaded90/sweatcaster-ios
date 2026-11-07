import AVKit
import UniformTypeIdentifiers
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
    @State private var showHelp = false
    @State private var showAgentHub = false
    @State private var showPhoneModels = false
    @State private var showOfflineStudio = false
    @State private var showSavedVideos = false
    @State private var savedVideos: [URL] = []
    @AppStorage("app.text.scale") private var textScale = 0.0
    @State private var clipGame = ""
    @State private var shortClips = false
    @State private var recentJobsFirst = false
    @State private var clipDateRange = 0
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

    private var visibleJobs: [Job] { model.jobs.filter { !hiddenJobs.contains($0.id) } }
    private var pendingJobs: Int { model.jobs.filter { $0.status.active }.count }

    private var homeContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                connectionSettings
                loadingStatus
                spaceContent
                appearanceSettings
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.refreshable { await model.refresh() }
        .onChange(of: showJobs) {
            space = .gallery
            proxy.scrollTo("jobs", anchor: .top)
            jobsFocus = true
        }
        .onChange(of: showClips) { proxy.scrollTo("clips", anchor: .top) }
        }
    }

    @ViewBuilder private var homeBackground: some View {
        if theme == "OLED Sort" {
            Color.black.ignoresSafeArea()
        } else if motion && !reduceMotion {
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
            .sensoryFeedback(.selection, trigger: space)
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
        .confirmationDialog("Skjul afsluttede jobs på denne telefon?", isPresented: $confirmClear) {
            Button("Skjul afsluttede jobs", role: .destructive) {
                hiddenJobs.formUnion(model.jobs.filter { !$0.status.active }.map(\.id))
            }
        } message: {
            Text("Videoerne og jobhistorikken bliver liggende på PC’en.")
        }
        .sheet(isPresented: $showAgentHub) {
            AgentHub(api: model.api as? LiveAPI)
        }
        .sheet(isPresented: $showPhoneModels) { PhoneModelsView() }
        .sheet(isPresented: $showOfflineStudio) { OfflineStudio() }
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
        if !model.isDemo {
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
        Menu {
            ForEach(Space.allCases) { item in
                Button(item.rawValue) { space = item }
            }
        } label: {
            Label("Spaces · \(space.rawValue)", systemImage: "square.grid.2x2")
                .frame(minHeight: 48)
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
            clipSection
            moodSection
            advanced($model.options)
        case .notes:
            heading("Noter")
            TextEditor(text: $notes).frame(minHeight: 180)
                .accessibilityLabel("Noter på denne enhed")
        case .gallery:
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
            Button("Ryd afsluttede jobs på denne telefon", role: .destructive) { confirmClear = true }
                .frame(minHeight: 48)
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

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("1. Vælg klip")
            DisclosureGroup("Filtrér klip") {
                TextField("Spil i filnavnet", text: $clipGame).textFieldStyle(.roundedBorder)
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
            if let caps = model.capabilities {
                Text("Valgt: \(model.selected.count) af \(caps.limit)")
            }
            if model.clips.isEmpty { Text("Ingen klip at vise.") }
            if !model.clips.isEmpty && filteredClips.isEmpty { Text("Ingen klip matcher filteret.") }
            ForEach(filteredClips) { clip in
                let selected = model.selected.contains(clip.id)
                Button { model.toggle(clip) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.name).font(.headline)
                            Text("\(clip.duration_seconds.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "da_DK")))) sek.")
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.bordered)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(model.busy || (!selected && model.selected.count >= (model.capabilities?.limit ?? 0)))
            }
            action("Opdater klip") { Task { await model.refresh() } }.disabled(switchDisabled)
        }.id("clips")
    }

    @State private var showClips = 0

    private var filteredClips: [Clip] {
        let query = clipGame.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = Dictionary(model.jobs.map { ($0.clip_id, $0.created_at) }, uniquingKeysWith: max)
        let cutoff = Calendar.current.date(byAdding: .day, value: -clipDateRange, to: .now) ?? .distantPast
        let clips = model.clips.filter {
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

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("2. Vælg stil")
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
                ForEach(Mood.allCases) { mood in
                    if caps.moods.contains(mood) {
                        Button {
                            Task {
                                await model.submit(mood)
                                if model.error == nil || model.uncertain { showJobs += 1 }
                            }
                        } label: {
                            Text(mood.title).font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(Rectangle())
                        }.buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.06, green: 0.31, blue: 0.65))
                            .environment(\.colorScheme, .light)
                            .disabled(!model.canSubmit || !model.cancelling.isEmpty)
                            .accessibilityHint("Starter valgte klip")
                    }
                }
            }
        }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("3. Følg dine videoer").accessibilityFocused($jobsFocus)
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
                    if job.status == .failed {
                        action("Prøv igen") { Task { await model.retry(job) } }
                            .disabled(!model.canRetry(job))
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
                }
            }.navigationTitle("Gemte videoer")
                .toolbar { Button("Luk") { showSavedVideos = false } }
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
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            work()
        } label: {
            Text(title).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.bordered)
    }
}


private struct VillageBot: Codable, Identifiable {
    var id = UUID()
    var name = ""
    var color = "Blå"
    var prompt = ""
    var voice = "da-DK"
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

private struct VillageBotBuilder: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("village.bots") private var savedBots = Data()
    @State private var draft = VillageBot()
    @State private var importing = false
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
            .toolbar { Button("Luk") { dismiss() } }
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
            Picker("Farve", selection: $draft.color) {
                ForEach(["Blå", "Lilla", "Grøn"], id: \.self) { Text($0) }
            }
            TextField("Systemprompt", text: $draft.prompt, axis: .vertical).lineLimit(3...8)
            Picker("Stemme", selection: $draft.voice) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk").tag("en-US")
                ForEach(AVSpeechSynthesisVoice.speechVoices().filter {
                    $0.language == "da-DK" || $0.language == "en-US" || $0.language == "en-GB"
                }, id: \.identifier) { voice in
                    Text(voice.name + " · " + voice.language).tag(voice.identifier)
                }
            }
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
                        for zone in 0..<4 {
                            let center = villagePoint(zone, size: canvas)
                            let w = canvas.width * 0.23
                            let h = canvas.height * 0.15
                            let tile = Path { path in
                                path.move(to: CGPoint(x: center.x, y: center.y - h))
                                path.addLine(to: CGPoint(x: center.x + w, y: center.y))
                                path.addLine(to: CGPoint(x: center.x, y: center.y + h))
                                path.addLine(to: CGPoint(x: center.x - w, y: center.y))
                                path.closeSubpath()
                            }
                            context.fill(tile, with: .color([Color.indigo, .blue, .teal, .purple][zone].opacity(0.62)))
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
                        Text(item.element).font(.caption2.bold())
                            .position(x: point.x, y: point.y + 23)
                    }
                    ForEach(Array((snapshot?.agents ?? []).enumerated()), id: \.element.id) { item in
                        villageAvatar(item.element, index: item.offset, size: size)
                    }
                    ForEach(Array(localVillageBots.enumerated()), id: \.element.id) { item in
                        localVillageAvatar(item.element, index: item.offset, hour: hour, size: size)
                    }
                }
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }.frame(height: 290)
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

    private func localVillageAvatar(_ bot: VillageBot, index: Int, hour: Int, size: CGSize) -> some View {
        let sleeping = villagePause || hour < 7 || hour >= 22
        let routine = (hour + index) % 3
        let zone = sleeping ? 3 : routine
        let center = villagePoint(zone, size: size)
        let activity = sleeping ? "Sover" : ["Læser", "Øver sig", "Holder kaffepause"][routine]
        let color: Color = bot.color == "Grøn" ? .green : bot.color == "Lilla" ? .purple : .cyan
        return Button {
            if !cinematic { localBot = bot }
        } label: {
            Image(systemName: sleeping ? "moon.stars.fill" : "sparkle")
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.name + ", lokal bot, " + activity)
        .position(x: center.x + CGFloat(index % 5 - 2) * 23,
                  y: center.y + 42 + CGFloat(index / 5) * 20)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.75), value: zone)
    }

    private func villagePoint(_ zone: Int, size: CGSize) -> CGPoint {
        let columns = [0.27, 0.73, 0.27, 0.73]
        let rows = [0.28, 0.37, 0.65, 0.74]
        return CGPoint(x: size.width * columns[zone], y: size.height * rows[zone])
    }

    private func villageAvatar(_ agent: V2Hub.Agent, index: Int, size: CGSize) -> some View {
        let sleeping = offline || agent.status == .offline
        let resting = agent.status == .ready
        let zone = sleeping ? 3 : resting ? 2 : agent.room_id.lowercased().contains("video") ? 1 : 0
        let point = villagePoint(zone, size: size)
        let offset = CGFloat(index % 4) * 29 - 43.5
        return Button {
            if !cinematic { details = agent }
        } label: {
            Image(systemName: sleeping ? "moon.zzz.fill" : "person.crop.circle.fill")
                .font(.title2).frame(width: 44, height: 44)
                .modifier(AgentPulse(active: !sleeping && !resting))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name + ", " + (sleeping ? "Hviler" : status(agent.status)))
        .contextMenu {
            if !cinematic {
                Button("Vis historik og hukommelse") { details = agent }
            }
        }
        .position(x: point.x + offset, y: point.y - 5 - CGFloat(index / 4) * 28)
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
        let choice = voiceBots.first { $0.id.uuidString == voiceBotID }?.voice ?? "da-DK"
        utterance.voice = AVSpeechSynthesisVoice(identifier: choice) ??
            AVSpeechSynthesisVoice(language: choice) ?? AVSpeechSynthesisVoice(language: "da-DK")
        speech.speak(utterance)
    }

    var body: some View {
        List {
                Text("Chat med AI-holdet").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Button("Luk") { stop(); dismiss() }.frame(minHeight: 48)
                Text(connection).font(.subheadline)
                Button("Ny samtale") { newConversation() }.frame(minHeight: 48).disabled(task != nil)
                StatsBar(turns: turns.count, streaming: task != nil)
                voiceControls
                Toggle("Brug PC til næste svar", isOn: $usePC).disabled(task != nil)
                Text("Korte svar forsøges på telefonen. Længere spørgsmål og PC-opgaver sendes til din PC.")
                    .font(.caption)
                modelControls
                if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                Text("AI’en arbejder på din PC. Researcher bruger internettet til websøgning.")
                transcriptRows
                if !searchSteps.isEmpty {
                    DisclosureGroup("Deep Search · \(searchSteps.count) trin") {
                        ForEach(searchSteps.indices, id: \.self) { index in
                            Label(searchSteps[index], systemImage: index + 1 == searchSteps.count ? "circle.fill" : "arrow.down.circle")
                        }
                    }
                }
                if let status { Text(status).font(.callout) }
                if task != nil && streamedText.isEmpty { LoadingSkeleton(label: "Venter på AI…") }
                if let sourceExcerpt {
                    DisclosureGroup("Lokal reference · Notes") {
                        Text(sourceExcerpt)
                        Text("Fundet på telefonen. Referencen blev ikke sendt til PC’en.")
                            .font(.caption)
                    }
                }
        }
        .listStyle(.plain)
        .refreshable { if task == nil { loadHistory() } }
        .safeAreaInset(edge: .bottom) { composer }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = initialDraft
            loadHistory()
        }
        .onDisappear { stop(); dictation.stop(); speech.stopSpeaking(at: .immediate) }
        .task { await loadModels() }
        .sensoryFeedback(.success, trigger: completedReplies)
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
            if task != nil {
                Button { stop() } label: { Text("Stop modtagelse").frame(minHeight: 48) }
                    .buttonStyle(.bordered)
            } else {
                Button { send() } label: { Text("Send besked").frame(minHeight: 48) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        ForEach(turns) { turn in
            VStack(alignment: .leading, spacing: 8) {
                Text(turn.prompt).font(.headline)
                if let source = turn.source { Text(source).font(.caption).foregroundStyle(.secondary) }
                if !turn.reply.isEmpty {
                    ChatTranscriptView(reply: turn.reply)
                    Button("Læs svaret op", systemImage: "speaker.wave.2") { speak(turn.reply) }
                        .frame(minHeight: 44)
                }
                    if let notice = turn.notice {
                        RetryNotice(message: notice) { draft = turn.prompt }.disabled(task != nil)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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
        }
    }

    private func send() {
        dictation.stop()
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task == nil, !message.isEmpty else { return }
        draft = ""
        searchSteps = []
        sourceExcerpt = localReference(for: message)
        streamedText = ""
        turns.append(ChatTurn(prompt: message))
        let index = turns.count - 1
        let context = turns.dropLast().suffix(6).filter { !$0.reply.isEmpty }
            .map { "Bruger: \($0.prompt)\nSvar: \($0.reply)" }.joined(separator: "\n")
        let requiresPC = usePC || PhoneModels.prefersPC(message, previousCharacters: context.count)
        status = "Venter på svar…"
        let input = ChatRequest(message: message, session_id: sessionID)
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
                        answered = try await answerOnPhone(message, context: context, index: index)
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
            if searchSteps.last != step { searchSteps.append(step) }
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

    private func save() {
        if let data = try? JSONEncoder().encode(turns) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ChatTurn].self, from: data) {
            turns = saved
        }
    }
}
