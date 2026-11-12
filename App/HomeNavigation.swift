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
        Menu {
            Section("Skab og saml") {
                Button("Billeder", systemImage: "photo") { openStudio(.images) }
                Button("Privat Studio", systemImage: "lock.shield") { openStudio(.chat) }
                Button("Noter", systemImage: "note.text") { showNotes = true }
                Button("Gemte videoer", systemImage: "film.stack") { reloadSavedVideos(); showSavedVideos = true }
            }
            Section("Gør det til dit") {
                Button("Holdet", systemImage: "person.2", action: openTeam)
                Button("Lokale modeller", systemImage: "iphone") { showPhoneModels = true }
                Button("Indstillinger", systemImage: "gearshape") { showSettings = true }
            }
            Section("Overblik og kontrol") {
                Button("Forbindelser", systemImage: "link") { showConnections = true }
                Button("PC-status", systemImage: "stethoscope") { showPCStatus = true }
                Button("Søg i FadedAI", systemImage: "magnifyingglass", action: openSearch)
            }
            if visibleModuleTarget != nil, !moduleTabs.isEmpty {
                Section("Udvidelser") {
                    ForEach(moduleTabs) { tab in
                        Button(tab.title) { selectModule("module:" + tab.id) }
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis").font(.body)
                Text("Mere").font(.caption2.bold())
            }
            .frame(minWidth: 44, minHeight: 48)
            .foregroundStyle(selectedModuleTab != nil ? (palette.isDark ? FadedBrand.mint : palette.text) : palette.secondary)
            .background(selectedModuleTab != nil ? FadedBrand.mint.opacity(palette.isDark ? 0.14 : 0.24) : Color.clear,
                        in: RoundedRectangle(cornerRadius: FadedRadius.medium))
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
