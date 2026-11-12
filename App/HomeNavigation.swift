import SwiftUI
import UIKit

extension Home {
    var v0LookPreset: V0LookPreset? {
        V0LookPreset.all.first { $0.id == v0LookPresetID }
    }

    private var lookPresetBinding: Binding<V0LookPreset?> {
        Binding(get: { v0LookPreset }, set: { v0LookPresetID = $0?.id ?? "" })
    }

    var spacesBar: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons
            ScrollView(.horizontal) { tabButtons }.scrollIndicators(.hidden)
        }
        .padding(6)
        .fadedGlassSurface(radius: FadedRadius.media, tint: v0LookPreset?.cardColor(in: palette),
                           border: v0LookPreset?.borderColor(in: palette))
        .frame(maxWidth: 570)
        .padding(.horizontal, 12).padding(.bottom, 4)
        .sheet(isPresented: $showMoreDestinations, onDismiss: openMoreDestination) {
            FadedMoreScreen(modules: visibleModuleTarget == nil ? [] : moduleTabs, lookPreset: lookPresetBinding) { destination in
                pendingMoreDestination = destination
                showMoreDestinations = false
            }
        }
    }

    private var tabButtons: some View {
        HStack(spacing: 2) {
            ForEach(Space.allCases) { item in
                let selected = selectedModuleTab == nil && space == item
                Button {
                    if reduceMotion { selectTab(item) }
                    else { withAnimation(.spring(response: calmMotion ? 0.70 : 0.35, dampingFraction: 0.8)) { selectTab(item) } }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: spaceIcon(item)).font(.body)
                        Text(spaceTitle(item)).font(.caption2.bold()).fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 4)
                    .foregroundStyle(selected ? (palette.isDark ? FadedBrand.mint : palette.text) : palette.secondary)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 48)
                    .background(selected ? FadedBrand.mint.opacity(palette.isDark ? 0.14 : 0.24) : Color.clear,
                                in: RoundedRectangle(cornerRadius: FadedRadius.medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Åbn " + spaceTitle(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            moreDestinations
        }
    }

    private var moreDestinations: some View {
        Button { showMoreDestinations = true } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis").font(.body)
                Text("Mere").font(.caption2.bold())
            }
            .frame(minWidth: 44, minHeight: 48)
            .foregroundStyle(selectedModuleTab != nil && palette.isDark ? FadedBrand.mint : palette.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mere")
    }

    private func openMoreDestination() {
        guard let destination = pendingMoreDestination else { return }
        pendingMoreDestination = nil
        switch destination {
        case .chat: selectSpace(.notes)
        case .code: selectSpace(.library)
        case .village: selectSpace(.tasks)
        case .video: openVideoClips()
        case .images: openStudio(.images)
        case .imageBrief(let prompt): openStudio(.images, prompt: prompt)
        case .holdchat: showHoldchatFromMore = true
        case .activity:
            selectSpace(.brain)
            openDashboardActivity()
        case .privateStudio: openStudio(.chat)
        case .notes: showNotes = true
        case .projects: showProjects = true
        case .backup: showBackupFromMore = true
        case .savedVideos: reloadSavedVideos(); showSavedVideos = true
        case .team: openTeam()
        case .models:
            settingsPath = [.models]
            showSettings = true
        case .settings: showSettings = true
        case .connections: showConnections = true
        case .pcStatus: showPCStatus = true
        case .search: openSearch()
        case .module(let id): selectModule("module:" + id)
        }
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
}

// Keep tab content out of the root's SwiftUI type until its screen is requested.
struct DeferredHomeTab: View {
    let isSelected: Bool
    let keepAlive: Bool
    let content: () -> AnyView
    @State private var hasOpened = false

    init(isSelected: Bool, keepAlive: Bool = true, content: @escaping () -> AnyView) {
        self.isSelected = isSelected
        self.keepAlive = keepAlive
        self.content = content
    }

    var body: some View {
        Group {
            if isSelected || (keepAlive && hasOpened) {
                content()
            } else {
                Color.clear
            }
        }
        .onChange(of: isSelected, initial: true) {
            if isSelected && keepAlive { hasOpened = true }
        }
    }
}


enum FadedMoreDestination {
    case chat, code, village
    case holdchat, activity
    case imageBrief(String)
    case video, images, privateStudio, notes, projects, backup, savedVideos, team, models, settings, connections, pcStatus, search
    case module(String)
}

@MainActor enum FadedMoreScreenData {
    static var bots: [VillageBot] {
        VillageBot.list(from: MigratedAppData.shared.villageBots)
    }
}

private struct FadedMoreScreen: View {
    private enum Page: Hashable { case lookbook, emby, powerHub, atlas, help, creativeStudio, memory, safety }

    let modules: [ModuleTab]
    @Binding var lookPreset: V0LookPreset?
    let open: (FadedMoreDestination) -> Void
    @State private var path = NavigationPath()
    @State private var projectExport: FadedProjectExport?
    @State private var exportingProjects = false
    @State private var shortcutError: String?
    @State private var copiedOverview = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette

    init(modules: [ModuleTab], lookPreset: Binding<V0LookPreset?>, open: @escaping (FadedMoreDestination) -> Void) {
        self.modules = modules
        _lookPreset = lookPreset
        self.open = open
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: FadedSpacing.s) { highlightCards }
                        VStack(spacing: FadedSpacing.s) { highlightCards }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("Hurtigt fra Mere") {
                    row("Eksport", "Gem en sikkerhedskopi af dine data", "square.and.arrow.up", .backup)
                    Button {
                        copyOverview()
                    } label: {
                        rowLabel("Kopiér overblik", "Kopiér antal lokale projekter og bots", "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(lookPreset?.cardColor(in: palette) ?? palette.card)
                    if copiedOverview {
                        FadedDetailText("Overblik kopieret.")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    row("Søg med det samme", "Find et område eller en funktion", "magnifyingglass", .search)
                }
                Section("Skab og saml") {
                    row("Holdchat", "Flere perspektiver i én samtale", "bubble.left.and.bubble.right", .holdchat)
                    link("Kreativt Studio", "Klargør en brief, eller åbn video og billeder", "film", .creativeStudio)
                    row("Privat Studio", "Åbn dit private rum", "lock.shield", .privateStudio)
                    row("Noter", "Skriv og genfind noter", "note.text", .notes)
                    row("Projekter", "Find og redigér dine kladder", "folder", .projects)
                    row("Gemte videoer", "Afspil dine færdige videoer", "film.stack", .savedVideos)
                }
                Section("Gør det til dit") {
                    link("Hukommelse", "Vælg selv, hvad dine bots skal huske", "brain.head.profile", .memory)
                    link("Emby & bibliotek", "Se bibliotekets designvisning", "play.rectangle", .emby)
                    row("Holdet", "Se dine AI’er og deres roller", "person.2", .team)
                    row("Modeller", "Administrér modeller på telefon og PC", "sparkles", .models)
                    link("Lookbook", "Skift baggrund, kort og bundmenu", "paintpalette", .lookbook)
                }
                Section("Overblik og kontrol") {
                    row("Aktivitet", "Se seneste jobs, status og udbakke", "bell", .activity)
                    link("Sikkerhedscentral", "Data, forbindelser og godkendelser", "shield", .safety)
                    row("Indstillinger", "Tilpas ro, tekst og detaljer", "slider.horizontal.3", .settings)
                    row("Forbindelser", "Se dine kilder og forbindelser", "link", .connections)
                    row("PC-status", "Tjek den tilsluttede PC", "stethoscope", .pcStatus)
                }
                Section("Opdag mere") {
                    link("Hvad kan jeg?", "Find din egen vej ind", "questionmark.circle", .help)
                    link("Funktionsatlas", "Krav og idéer fra v0-projektet", "map", .atlas)
                    link("50 + 50 + 50", "Genveje, værktøjer og visuelle valg", "square.grid.2x2", .powerHub)
                }
                if !modules.isEmpty {
                    Section("Udvidelser") {
                        ForEach(modules) { tab in
                            row(tab.title, "Åbn på din tilsluttede PC", "square.grid.2x2", .module(tab.id))
                        }
                    }
                }
                Section {
                    VStack(spacing: FadedSpacing.s) {
                        Text("fadedai").font(FadedTypography.action).foregroundStyle(palette.text)
                        FadedDetailText("Premium Dark · Supreme Sky · UI-preview")
                        if let url = URL(string: "https://ui.aceternity.com/components") {
                            Link(destination: url) {
                                Label("Lys og detaljer med gratis Aceternity UI", systemImage: "arrow.up.right")
                                    .font(.footnote)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle("Mere")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .lookbook: V0LookbookView(selection: $lookPreset)
                case .emby:
                    V0EmbyLibraryView(openNotes: { open(.notes) }, openProjects: { open(.projects) },
                                      openExport: { open(.backup) })
                case .powerHub:
                    V0PowerHubView(actions: powerActions, openLookbook: { path.append(Page.lookbook) },
                       tryAuroraGlass: { lookPreset = .auroraGlass },
                       resetAppearance: { lookPreset = nil },
                       resolveSourceAction: resolvePowerAction)
                case .atlas: V0FeatureAtlasView()
                case .help: V0HelpView()
                case .creativeStudio:
                    V0CreativeStudioView(openVideo: { open(.video) }, openImages: { open(.imageBrief($0)) })
                case .memory: FadedMemoryOverview(bots: FadedMoreScreenData.bots)
                case .safety:
                    FadedSafetyOverview(openMemory: { path.append(Page.memory) }, open: open)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
        .fileExporter(isPresented: $exportingProjects, document: projectExport,
                      contentType: FadedProjectExport.format, defaultFilename: "FadedAI-projekter") { result in
            if case .failure(let error) = result {
                AppDiagnostics.record(error)
                shortcutError = "Projekterne kunne ikke eksporteres."
            }
            projectExport = nil
        }
        .alert("Genvejen kunne ikke gennemføres", isPresented: Binding(
            get: { shortcutError != nil }, set: { if !$0 { shortcutError = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(shortcutError ?? "")
        }
    }

    private func copyOverview() {
        do {
            let count = try FadedProjectStore.load().count
            UIPasteboard.general.string = "FadedAI · \(count) lokale projekter · \(FadedMoreScreenData.bots.count) bots"
            copiedOverview = true
        } catch {
            AppDiagnostics.record(error)
            shortcutError = "Projektoversigten kunne ikke åbnes."
        }
    }

    @ViewBuilder private var highlightCards: some View {
        NavigationLink(value: Page.creativeStudio) {
            highlight("Skab noget", detail: "Dit kreative Studio", icon: "film")
        }
        .buttonStyle(.plain)
        Button { open(.projects) } label: {
            highlight("Saml idéerne", detail: "Dine projektkladder", icon: "folder")
        }
        .buttonStyle(.plain)
    }

    private func highlight(_ title: String, detail: String, icon: String) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Image(systemName: icon).foregroundStyle(palette.isDark ? palette.lime : palette.text)
                    .accessibilityHidden(true)
                Text(title).font(FadedTypography.action)
                FadedDetailText(detail)
            }
            .frame(minHeight: 74, alignment: .leading)
        }
    }

    private func resolvePowerAction(_ id: String) -> (() -> Void)? {
        switch id {
        case "utility-settings": return { open(.settings) }
        case "utility-visuals": return { path.append(Page.lookbook) }
        case "export-projects": return exportProjects
        default: return nil
        }
    }

    private func exportProjects() {
        do {
            let projects = try FadedProjectStore.load()
            guard !projects.isEmpty else {
                shortcutError = "Opret et projekt under Mere → Projekter, og prøv igen."
                return
            }
            projectExport = FadedProjectExport(projects: projects)
            exportingProjects = true
        } catch {
            AppDiagnostics.record(error)
            shortcutError = "Projekterne kunne ikke åbnes."
        }
    }

    private var powerActions: [V0PowerHubView.Action] {
        let destinations: [(String, String, String, FadedMoreDestination)] = [
            ("chat", "AI-chat", "bubble.left", .chat),
            ("code", "Code Bot", "terminal", .code),
            ("village", "Landsbyen", "house.lodge", .village),
            ("video", "Video Studio", "film", .video),
            ("images", "Billeder", "photo", .images),
            ("private", "Privat Studio", "lock.shield", .privateStudio),
            ("team", "Holdet", "person.2", .team),
            ("notes", "Noter", "note.text", .notes),
            ("projects", "Projekter", "folder", .projects),
            ("saved", "Gemte videoer", "film.stack", .savedVideos),
            ("models", "Modeller på telefon og PC", "sparkles", .models),
            ("status", "PC-status", "stethoscope", .pcStatus),
            ("connections", "Forbindelser", "link", .connections),
            ("search", "Søg i FadedAI", "magnifyingglass", .search),
            ("settings", "Indstillinger", "gearshape", .settings),
            ("backup", "Sikkerhedskopi", "square.and.arrow.up", .backup)
        ]
        return destinations.map { id, title, icon, destination in
            .init(id: id, title: title, icon: icon) { open(destination) }
        }
    }

    private func row(_ title: String, _ detail: String, _ icon: String, _ destination: FadedMoreDestination) -> some View {
        Button { open(destination) } label: { rowLabel(title, detail, icon) }
            .buttonStyle(.plain)
            .listRowBackground(lookPreset?.cardColor(in: palette) ?? palette.card)
    }

    private func link(_ title: String, _ detail: String, _ icon: String, _ page: Page) -> some View {
        NavigationLink(value: page) { rowLabel(title, detail, icon, showsChevron: false) }
            .listRowBackground(lookPreset?.cardColor(in: palette) ?? palette.card)
    }

    private func rowLabel(_ title: String, _ detail: String, _ icon: String, showsChevron: Bool = true) -> some View {
        HStack(spacing: FadedSpacing.m) {
                Image(systemName: icon)
                    .foregroundStyle(palette.cyan)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(title).font(.headline).foregroundStyle(palette.text)
                    Text(detail).font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                        .accessibilityHidden(true)
                }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct FadedMemoryOverview: View {
    let bots: [VillageBot]

    var body: some View {
        List {
            Section {
                FadedDetailText("Vælg en bot for at se og redigere de noter, du selv har gemt til den.")
                if bots.isEmpty {
                    FadedDetailText("Opret en bot i Landsbyen for at gemme hukommelse.")
                }
                ForEach(bots) { bot in
                    NavigationLink(value: bot.id) {
                        Label(bot.name, systemImage: "brain.head.profile")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle("Hukommelse")
        .navigationDestination(for: UUID.self) { TeamBotNotebook(botID: $0) }
    }
}

private struct FadedSafetyOverview: View {
    let openMemory: () -> Void
    let open: (FadedMoreDestination) -> Void

    var body: some View {
        List {
            Section("Dine data og godkendelser") {
                FadedDetailText("Kodeforslag kan gennemgås, før du godkender ændringer.")
                FadedDetailText("Privat Studio har sin egen session på telefonen.")
                Button("Hukommelse", systemImage: "brain.head.profile", action: openMemory)
                Button("Åbn Privat Studio", systemImage: "lock.shield") { open(.privateStudio) }
            }
            Section("Administrér") {
                Button("Forbindelser", systemImage: "link") { open(.connections) }
                Button("Sikkerhedskopi og gendannelse", systemImage: "externaldrive") { open(.backup) }
                Button("Indstillinger", systemImage: "gearshape") { open(.settings) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle("Sikkerhedscentral")
    }
}

struct V0HelpView: View {
    private enum Page: Hashable { case atlas }

    private let topics = [
        ("Hvad virker i FadedAI?", "Du kan chatte, arbejde med projekter og bruge dine lokale modeller. PC-funktioner åbnes via QR-login."),
        ("Hvor gemmes mine kladder?", "Projekter gemmes lokalt på din iPhone. Åbn et projekt fra Mere for at redigere det, eller hold fingeren på det for at dele det som tekst."),
        ("Hvordan bruger jeg Code Bot?", "Forbind PC’en, og åbn Code Bot. Gennemgå kodeforslaget, før du godkender ændringer."),
        ("Hvordan installerer jeg på iPhone?", "Installer FadedAI fra den IPA, du bruger til at teste. Åbn QR-login på forsiden for at parre med PC’en."),
        ("Kan jeg bruge iOS Genveje?", "Find FadedAI i appen Genveje for blandt andet at åbne chat, video og billeder."),
        ("Hvor er overleveringen?", "Funktionsatlas viser idéer og krav fra det købte UI. Det viser også, hvilke dele der stadig afventer tilslutning.")
    ]

    var body: some View {
        List {
            Section {
                Text("Find din egen vej ind.")
                    .font(FadedTypography.title)
                    .accessibilityAddTraits(.isHeader)
                ForEach(topics.indices, id: \.self) { index in
                    DisclosureGroup(topics[index].0) { FadedDetailText(topics[index].1) }
                }
                NavigationLink(value: Page.atlas) {
                    Label("Udforsk Funktionsatlas", systemImage: "map")
                }
            } header: {
                Text("En hjælpende hånd")
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle("Hvad kan jeg?")
        .navigationDestination(for: Page.self) { _ in V0FeatureAtlasView() }
    }
}
