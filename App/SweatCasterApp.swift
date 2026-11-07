import AVKit
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
        Self(category: "Video", text: "Foreslå en kort titel til mit næste klip."),
        Self(category: "Planlægning", text: "Lav en tjekliste til min næste optagelse."),
        Self(category: "Idéer", text: "Giv mig tre idéer til et sjovt gamingklip.")
    ]
}

@main struct SweatCasterApp: App {
    var body: some Scene { WindowGroup { Home() } }
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
    @State private var confirmClear = false
    @State private var hiddenJobs = Set<String>()
    @AppStorage("spaces.notes") private var notes = ""
    @AppStorage("spaces.onboarded") private var onboarded = false
    @AppStorage("spaces.theme") private var theme = "System"
    @AppStorage("spaces.font") private var font = "Standard"
    @AppStorage("spaces.motion") private var motion = false
    @AppStorage("spaces.shortcut") private var shortcut = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backgroundPhase = false

    private var visibleJobs: [Job] { model.jobs.filter { !hiddenJobs.contains($0.id) } }
    private var pendingJobs: Int { model.jobs.filter { $0.status.active }.count }

    var body: some View {
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
        }
        .onAppear {
            edit(model.activeProfile)
            setup = model.address.isEmpty || model.isDemo
            prunePreviews()
            openShortcut()
        }
        .onChange(of: shortcut) { openShortcut() }
        .sensoryFeedback(.selection, trigger: space)
        .sensoryFeedback(.success, trigger: model.jobs.filter { $0.status == .completed }.map(\.id)) { old, new in
            new.count > old.count
        }
        .onChange(of: model.error?.title) { _, title in
            errorDetails = false
            if title != nil { errorFocus = true }
        }
        .onChange(of: model.isDemo) { hiddenJobs.removeAll() }
        .onChange(of: model.address) { hiddenJobs.removeAll() }
        .sensoryFeedback(.selection, trigger: model.jobs.map { $0.id + $0.status.rawValue }) { old, new in
            old.count == new.count && !old.isEmpty
        }
        .preferredColorScheme(theme == "Lys" ? .light : theme == "Mørk" ? .dark : nil)
        .fontDesign(font == "Afrundet" ? .rounded : font == "Monospace" ? .monospaced : .default)
        .background {
            if motion && !reduceMotion {
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
        action("Agent-Hub") { showAgentHub = true }
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
        DisclosureGroup("Visning og jobhistorik") {
            Picker("Tema", selection: $theme) {
                ForEach(["System", "Lys", "Mørk"], id: \.self) { Text($0) }
            }
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
            if let caps = model.capabilities {
                Text("Valgt: \(model.selected.count) af \(caps.limit)")
            }
            if model.clips.isEmpty { Text("Ingen klip at vise.") }
            ForEach(model.clips) { clip in
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
            ForEach(visibleJobs.sorted { $0.created_at > $1.created_at }) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text(job.mood.title + " · " + job.status.title)
                    Text(job.message)
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


private struct AgentHub: View {
    @Environment(\.dismiss) private var dismiss
    let api: LiveAPI?
    @State private var selectedRoom = "research"
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
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .navigationTitle("Agent-Hub")
            .task(id: attempt) { await followHub() }
            .refreshable { attempt += 1 }
            .toolbar { Button("Luk") { dismiss() } }
            .sheet(item: $details) { agent in agentDetails(agent) }
            .sheet(isPresented: $achievements) { achievementPage }
        }
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
            if !Task.isCancelled { failure = "Kunne ikke hente Agent-Hub. Tjek forbindelsen til PC’en." }
        }
    }

    private func apply(_ value: V2Hub) {
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

    var body: some View {
        List {
                Text("Chat med AI-holdet").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Button("Luk") { stop(); dismiss() }.frame(minHeight: 48)
                Text(connection).font(.subheadline)
                Button("Ny samtale") { newConversation() }.frame(minHeight: 48).disabled(task != nil)
                StatsBar(turns: turns.count, streaming: task != nil)
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
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Din besked", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).frame(minHeight: 48)
                if task != nil {
                    Button { stop() } label: { Text("Stop modtagelse").frame(minHeight: 48) }
                        .buttonStyle(.bordered)
                } else {
                    Button { send() } label: { Text("Send besked").frame(minHeight: 48) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  modelsLoading || (!legacyChat && !demo && selectedModel.isEmpty))
                }
            }.padding(12).background(.regularMaterial)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = initialDraft
            loadHistory()
        }
        .onDisappear { stop() }
        .task { await loadModels() }
        .sensoryFeedback(.success, trigger: completedReplies)
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
                if !turn.reply.isEmpty { ChatTranscriptView(reply: turn.reply) }
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
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task == nil, !message.isEmpty else { return }
        draft = ""
        searchSteps = []
        sourceExcerpt = localReference(for: message)
        streamedText = ""
        turns.append(ChatTurn(prompt: message))
        let index = turns.count - 1
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
                } else if let live = api as? LiveAPI, !legacyChat {
                    let request = try V2ChatRequest(message: message, sessionID: sessionID.uuidString,
                                                    modelID: selectedModel)
                    try await live.v2Chat(request) { event in
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            receive(type: event.type.rawValue, content: event.content, index: index)
                        }
                    }
                    try Task.checkCancellation()
                } else {
                    guard let api else { throw ChatFailure.unauthorized }
                    await run(api, input: input, index: index)
                }
                if turns[index].notice == nil { completedReplies += 1 }
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
