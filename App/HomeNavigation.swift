import SwiftUI

extension Home {
    var spacesBar: some View {
        ViewThatFits(in: .horizontal) {
            tabButtons
            ScrollView(.horizontal) { tabButtons }.scrollIndicators(.hidden)
        }
        .padding(6)
        .background(palette.card, in: RoundedRectangle(cornerRadius: FadedRadius.media))
        .overlay { RoundedRectangle(cornerRadius: FadedRadius.media).strokeBorder(palette.border).allowsHitTesting(false) }
        .frame(maxWidth: 570)
        .padding(.horizontal, 12).padding(.bottom, 4)
        .sheet(isPresented: $showMoreDestinations, onDismiss: openMoreDestination) {
            FadedMoreScreen(modules: visibleModuleTarget == nil ? [] : moduleTabs) { destination in
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
        case .video: openVideoClips()
        case .images: openStudio(.images)
        case .privateStudio: openStudio(.chat)
        case .notes: showNotes = true
        case .projects: showProjects = true
        case .savedVideos: reloadSavedVideos(); showSavedVideos = true
        case .team: openTeam()
        case .models: showPhoneModels = true
        case .settings: showSettings = true
        case .connections: showConnections = true
        case .pcStatus: showPCStatus = true
        case .search: openSearch()
        case .help: showHelp = true
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
    case video, images, privateStudio, notes, projects, savedVideos, team, models, settings, connections, pcStatus, search, help
    case module(String)
}

private struct FadedMoreScreen: View {
    let modules: [ModuleTab]
    let open: (FadedMoreDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                Section("Skab og saml") {
                    row("Video Studio", "Redigér og kommentér klip", "film", .video)
                    row("Billeder", "Lav billeder på telefonen eller PC’en", "photo", .images)
                    row("Privat Studio", "Åbn dit private rum", "lock.shield", .privateStudio)
                    row("Noter", "Skriv og genfind noter", "note.text", .notes)
                    row("Projekter", "Find og redigér dine kladder", "folder", .projects)
                    row("Gemte videoer", "Afspil dine færdige videoer", "film.stack", .savedVideos)
                }
                Section("Gør det til dit") {
                    row("Holdet", "Se dine AI’er og deres roller", "person.2", .team)
                    row("Lokale modeller", "Hent og administrér modeller til telefonen", "iphone", .models)
                    row("Indstillinger", "Tilpas FadedAI", "gearshape", .settings)
                }
                Section("Overblik og kontrol") {
                    row("Forbindelser", "Se dine kilder og forbindelser", "link", .connections)
                    row("PC-status", "Tjek den tilsluttede PC", "stethoscope", .pcStatus)
                    row("Søg", "Find chats, jobs og bots", "magnifyingglass", .search)
                }
                Section("Opdag mere") {
                    row("Hvad kan jeg?", "Få overblik over appens funktioner", "questionmark.circle", .help)
                }
                if !modules.isEmpty {
                    Section("Udvidelser") {
                        ForEach(modules) { tab in
                            row(tab.title, "Åbn på din tilsluttede PC", "square.grid.2x2", .module(tab.id))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FadedBackground())
            .navigationTitle("Mere")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
    }

    private func row(_ title: String, _ detail: String, _ icon: String, _ destination: FadedMoreDestination) -> some View {
        Button { open(destination) } label: {
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.card)
    }
}
