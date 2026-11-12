import Foundation
import SwiftUI

struct EmbyLibraryView: View {
    let api: LiveAPI?
    var openNotes: (() -> Void)? = nil
    var openProjects: (() -> Void)? = nil
    var openExport: (() -> Void)? = nil
    var openConnections: (() -> Void)? = nil

    var body: some View {
        EmbyCatalogView(api: api, folder: nil, openConnections: openConnections) {
            if let openNotes, let openProjects, let openExport {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    Text("Resten af dit bibliotek").font(.headline).accessibilityAddTraits(.isHeader)
                    EmbyLibraryShortcut(title: "Noter", icon: "note.text", action: openNotes)
                    EmbyLibraryShortcut(title: "Projekter", icon: "folder", action: openProjects)
                    EmbyLibraryShortcut(title: "Eksport", icon: "square.and.arrow.up", action: openExport)
                }
            }
        }
        .navigationDestination(for: EmbyLibraryPage.Item.self) { item in
            EmbyCatalogView(api: api, folder: item, openConnections: openConnections) { EmptyView() }
                .id(item.id)
        }
    }
}

private struct EmbyCatalogView<Footer: View>: View {
    let api: LiveAPI?
    let folder: EmbyLibraryPage.Item?
    let openConnections: (() -> Void)?
    let footer: Footer

    @Environment(\.fadedPalette) private var palette
    @State private var search = ""
    @State private var items: [EmbyLibraryPage.Item] = []
    @State private var nextOffset: Int?
    @State private var configured: Bool?
    @State private var requestID: UUID?
    @State private var loadedQuery: String?
    @State private var issue: String?

    init(api: LiveAPI?, folder: EmbyLibraryPage.Item?, openConnections: (() -> Void)?,
         @ViewBuilder footer: () -> Footer) {
        self.api = api
        self.folder = folder
        self.openConnections = openConnections
        self.footer = footer()
    }

    private var query: String {
        String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.m) {
                if folder == nil { hero }
                if api == nil {
                    FadedCard {
                        VStack(alignment: .leading, spacing: FadedSpacing.s) {
                            FadedDetailText("Forbind din FadedAI-PC for at åbne Emby.")
                            if let openConnections {
                                Button("Åbn Forbindelser", systemImage: "link", action: openConnections)
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                } else {
                    catalog
                }
                footer
            }
            .foregroundStyle(palette.text)
            .padding(FadedSpacing.l)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(FadedBackground())
        .navigationTitle(folder?.title ?? "Dit bibliotek")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Søg i Emby")
        .task(id: query) {
            let currentQuery = query
            if !currentQuery.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
            }
            await load(query: currentQuery)
        }
        .refreshable { await load(query: query) }
    }

    private var hero: some View {
        let connected = configured == true && issue == nil
        return FadedCard(size: .hero) {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedBadge(connected ? "Emby · Forbundet" : "Emby", tone: connected ? .success : .info)
                Label("DIN EGEN BIOGRAF", systemImage: "play.rectangle")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(palette.secondary)
                Text("Et sted til alt, du elsker at se.")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                FadedDetailText("Find film, serier og musik i dit Emby-bibliotek.")
            }
        }
    }

    @ViewBuilder private var catalog: some View {
        if let issue, loadedQuery == query {
            FadedCard {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    FadedDetailText(issue)
                    Button("Prøv igen", systemImage: "arrow.clockwise") { Task { await load(query: query) } }
                        .frame(minHeight: 44)
                        .disabled(requestID != nil)
                }
            }
        } else if configured == false, loadedQuery == query {
            FadedCard {
                FadedDetailText("Åbn Emby-opsætning på PC’en, og log ind. Træk ned her for at opdatere bagefter.")
            }
        } else if requestID != nil || loadedQuery != query {
            ProgressView("Henter bibliotek")
        } else if items.isEmpty {
            FadedDetailText(query.isEmpty ? "Der er endnu intet at vise her." : "Ingen titler matcher din søgning.")
        }

        if loadedQuery == query {
            ForEach(items) { item in
                EmbyCatalogRow(item: item)
            }
            if let nextOffset {
                Button("Vis flere", systemImage: "chevron.down") {
                    Task { await load(query: query, offset: nextOffset) }
                }
                .frame(minHeight: 44)
                .disabled(requestID != nil)
            }
        }
    }

    @MainActor private func load(query requestedQuery: String, offset: Int = 0) async {
        guard let api, !Task.isCancelled, requestedQuery == query else { return }
        if offset > 0 {
            guard requestID == nil, loadedQuery == requestedQuery, nextOffset == offset else { return }
        } else if loadedQuery != requestedQuery {
            items = []
            nextOffset = nil
        }
        let id = UUID()
        requestID = id
        loadedQuery = requestedQuery
        issue = nil
        defer { if requestID == id { requestID = nil } }
        do {
            let result = try await api.embyLibrary(parent: folder?.id, search: requestedQuery, offset: offset)
            guard !Task.isCancelled, requestID == id, query == requestedQuery else { return }
            configured = result.configured
            var existing = offset == 0 ? [] : items
            var seen = Set(existing.map(\.id))
            if result.configured {
                existing.append(contentsOf: result.items.filter { seen.insert($0.id).inserted })
            }
            items = existing
            nextOffset = result.configured ? result.nextOffset.flatMap { $0 > offset ? $0 : nil } : nil
        } catch {
            guard !Task.isCancelled, requestID == id, query == requestedQuery else { return }
            issue = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? APIError {
        case .http(401, _)?:
            "PC’en afviste forbindelsen. Åbn Forbindelser, og par PC’en igen."
        case .http(404, _)?:
            "FadedAI på PC’en skal opdateres, før du kan bruge Emby."
        case .http(503, _)?:
            "PC’en kunne ikke forbinde til Emby. Tjek Emby på PC’en, og prøv igen."
        case .http(502, _)?:
            "Emby afviste forespørgslen eller gav et uventet svar. Tjek forbindelsen på PC’en."
        default:
            error is URLError
                ? "FadedAI-PC’en kan ikke nås lige nu. Tjek, at PC’en og forbindelsen er tændt."
                : "Biblioteket kunne ikke hentes. Prøv igen."
        }
    }
}

private struct EmbyCatalogRow: View {
    let item: EmbyLibraryPage.Item
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        if item.folder {
            NavigationLink(value: item) { card(arrow: "chevron.right") }.buttonStyle(.plain)
        } else if let url = item.browserURL {
            Link(destination: url) { card(arrow: "arrow.up.right") }
                .buttonStyle(.plain)
                .accessibilityHint("Åbner titlen i Emby")
        } else {
            card(arrow: nil)
        }
    }

    private func card(arrow: String?) -> some View {
        FadedCard(size: .compact) {
            HStack(spacing: FadedSpacing.m) {
                Image(systemName: icon)
                    .frame(width: 30)
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(verbatim: item.title).font(.headline).foregroundStyle(palette.text)
                    if let subtitle = item.subtitle, !subtitle.isEmpty { FadedDetailText(subtitle) }
                }
                Spacer(minLength: FadedSpacing.s)
                if let arrow {
                    Image(systemName: arrow).font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondary).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var icon: String {
        switch item.kind.lowercased() {
        case "movies", "movie": "film"
        case "tvshows", "series", "season", "episode": "tv"
        case "music", "musicalbum", "musicartist", "audio": "music.note"
        default: item.folder ? "folder" : "play.rectangle"
        }
    }
}

private struct EmbyLibraryShortcut: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, FadedSpacing.m)
                .fadedGlassSurface()
        }
        .buttonStyle(.plain)
    }
}
