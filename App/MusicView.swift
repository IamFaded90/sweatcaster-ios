import SwiftUI
import Kingfisher

@MainActor struct MusicView: View {
    private enum Section: String, CaseIterable {
        case home = "Oversigt", search = "Søg", library = "Mit bibliotek"
    }

    let onBack: () -> Void
    let api: LiveAPI?
    init(onBack: @escaping () -> Void, api: LiveAPI? = nil) { self.onBack = onBack; self.api = api }
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var library = MusicLibrary.shared
    @State private var query = ""
    @State private var results: [MusicTrack] = []
    @State private var searched = false
    @State private var searching = false
    @State private var search: Task<Void, Never>?
    @State private var notice: String?
    @State private var section = Section.home
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 144
    @State private var showPlayer = false
    @State private var showMix = false
    @State private var showSongs = false
    @State private var showPlaylistName = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if typeSize.isAccessibilitySize {
                        Picker("Vis i Musik", selection: $section) { sections }
                            .pickerStyle(.menu)
                    } else {
                        Picker("Musik", selection: $section) { sections }
                            .pickerStyle(.segmented)
                    }
                    switch section {
                    case .home: overview
                    case .search: searchContent
                    case .library: libraryContent
                    }
                    if let notice = library.notice { Text(notice).foregroundStyle(palette.secondary) }
                    if let notice = player.notice { Text(notice).foregroundStyle(palette.secondary) }
                }.padding(FadedSpacing.edge)
            }.scrollDismissesKeyboard(.interactively)
                .foregroundStyle(palette.text)
                .background { MusicBackdrop() }
                .navigationTitle("Musik")
                .navigationBarBackButtonHidden(true)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left", action: onBack)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Musikvalg", systemImage: "ellipsis") {
                            Button("Skab en sang", systemImage: "waveform") { showSongs = true }
                            Button("Din musikvært", systemImage: "sparkles") { showMix = true }
                            Button("Ny playliste", systemImage: "text.badge.plus") { showPlaylistName = true }
                            Menu("Sovetimer", systemImage: "moon.zzz") {
                                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                                    Button("\(minutes) minutter") { player.setSleep(minutes: minutes) }
                                }
                                Button("Slå fra") { player.setSleep(minutes: nil) }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { miniPlayer }
                .alert("Ny playliste", isPresented: $showPlaylistName) {
                    TextField("Navn", text: $playlistName)
                    Button("Opret") { library.createPlaylist(playlistName); playlistName = ""; section = .library }
                        .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Annuller", role: .cancel) {}
                }
                .sheet(isPresented: $showPlayer) { MusicPlayingView() }
                .sheet(isPresented: $showMix) { MusicMixView() }
                .sheet(isPresented: $showSongs) { SongStudioView(api: api) }
                .onDisappear { search?.cancel(); searching = false }
        }.tint(MusicEdition.accent(palette))
            .navigationBarBackButtonHidden(true)
    }

    private var sections: some View {
        ForEach(Section.allCases, id: \.self) { page in Text(page.rawValue).tag(page) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            FadedPrimaryButton("Lav et miks til min stemning", icon: "sparkles") { showMix = true }
            FadedSecondaryButton("Skab en sang eller et remix", icon: "waveform") { showSongs = true }
            Button {
                section = .search
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Find din næste sang")
                            .font(.system(.title, design: .serif, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Label("Søg i musik", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(MusicEdition.cream)
                            .background(MusicEdition.ink, in: Capsule())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !typeSize.isAccessibilitySize {
                        VinylArtwork().aspectRatio(1, contentMode: .fit)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                min(94, max(56, width - 252))
                            }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                .foregroundStyle(MusicEdition.ink)
                .background {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [MusicEdition.cream, MusicEdition.apricot],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }.buttonStyle(.plain).accessibilityLabel("Søg efter sang eller kunstner")

            if !library.recent.isEmpty { trackShelf("Sidst afspillet", tracks: library.recent) }
            if !library.saved.favorites.isEmpty { trackShelf("Favoritter", tracks: library.saved.favorites) }
            if !library.saved.playlists.isEmpty { playlistShelf }
            if !library.saved.downloads.isEmpty { trackShelf("Hentet til offline", tracks: library.saved.downloads) }
            exploreShelf
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Søg efter sang eller kunstner", text: $query).submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { performSearch() }
                Button("Søg", systemImage: "magnifyingglass") { performSearch() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 14).fadedGlassSurface(radius: 16, tint: MusicEdition.surface(palette))
            if searching { ProgressView("Finder musik…") }
            if let notice { Text(notice).foregroundStyle(palette.secondary) }
            if !searched { exploreShelf }
            ForEach(results) { track in
                trackRow(track) { player.play(results, at: results.firstIndex(of: track) ?? 0) }
            }
        }
    }

    private func trackShelf(_ title: String, tracks: [MusicTrack]) -> some View {
        shelf(title) {
            ForEach(Array(tracks.prefix(16).enumerated()), id: \.element.id) { index, track in
                Button { player.play(tracks, at: index) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        artwork(track, size: shelfWidth)
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
                    }.frame(width: shelfWidth, alignment: .leading)
                }.buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Afspiller sangen")
            }
        }
    }

    private var playlistShelf: some View {
        shelf("Dine playlister") {
            ForEach(library.saved.playlists) { list in
                Button { player.play(list.tracks) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let first = list.tracks.first { artwork(first, size: shelfWidth) }
                        else {
                            MusicCover(url: nil, symbol: "music.note.list")
                                .frame(width: shelfWidth, height: shelfWidth)
                                .clipShape(.rect(cornerRadius: 16))
                        }
                        Text(list.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(list.tracks.count) sange").font(.caption).foregroundStyle(palette.secondary)
                    }.frame(width: shelfWidth, alignment: .leading)
                }.buttonStyle(.plain)
                    .disabled(list.tracks.isEmpty)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var exploreShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfTitle("Gå på opdagelse")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                genre("Dansk musik", icon: "sparkles", color: MusicEdition.mint)
                genre("Hip-hop", icon: "mic.fill", color: MusicEdition.lilac)
                genre("Pop", icon: "bolt.fill", color: MusicEdition.apricot)
                genre("House", icon: "waveform", color: MusicEdition.sky)
            }
        }
    }

    private func genre(_ title: String, icon: String, color: Color) -> some View {
        Button {
            query = title
            performSearch()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).accessibilityHidden(true)
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .foregroundStyle(MusicEdition.ink)
            .background(color, in: .rect(cornerRadius: 14))
        }.buttonStyle(.plain)
            .accessibilityHint("Søger efter musik i kataloget")
    }

    private var shelfWidth: CGFloat { min(220, coverWidth) }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            shelfTitle(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12, content: content)
                    .scrollTargetLayout()
            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }
    }

    private func shelfTitle(_ title: String) -> some View {
        Text(title).font(.system(.title2, design: .serif, weight: .bold))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var miniPlayer: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Button { showPlayer = true } label: {
                    HStack {
                        artwork(track)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1).font(.subheadline.bold())
                            Text(track.artist).lineLimit(1).font(.caption).foregroundStyle(palette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
                if player.loading { ProgressView() }
                Button(player.canPause ? "Pause" : "Afspil", systemImage: player.canPause ? "pause.fill" : "play.fill") { player.toggle() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                Button("Næste sang", systemImage: "forward.end.fill") { player.next() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.padding(10)
                .foregroundStyle(palette.text)
                .fadedGlassSurface(radius: 18, tint: MusicEdition.surface(palette))
                .overlay(alignment: .bottom) {
                    if player.duration.isFinite, player.duration > 0, player.position.isFinite {
                        ProgressView(value: max(0, min(player.position, player.duration)), total: player.duration)
                            .tint(MusicEdition.accent(palette))
                            .padding(.horizontal, 14)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, FadedSpacing.edge)
        }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup("Favoritter · \(library.saved.favorites.count)") {
                ForEach(library.saved.favorites) { track in
                    trackRow(track) { player.play(library.saved.favorites, at: library.saved.favorites.firstIndex(of: track) ?? 0) }
                }
                if library.saved.favorites.isEmpty {
                    Text("Vælg Gem favorit i en sangs menu for at finde den her.").font(.footnote)
                }
            }.padding(14).fadedGlassSurface(radius: 16, tint: MusicEdition.surface(palette))
            DisclosureGroup("Hentet · \(library.saved.downloads.count)") {
                ForEach(library.saved.downloads) { track in
                    trackRow(track) { player.play(library.saved.downloads, at: library.saved.downloads.firstIndex(of: track) ?? 0) }
                }
                if library.saved.downloads.isEmpty { Text("Hent en sang fra dens menu for at lytte offline.").font(.footnote) }
            }.padding(14).fadedGlassSurface(radius: 16, tint: MusicEdition.surface(palette))
            ForEach(library.saved.playlists) { playlist in
                DisclosureGroup(playlist.name + " · \(playlist.tracks.count)") {
                    Button("Afspil playliste", systemImage: "play.fill") { player.play(playlist.tracks) }
                        .disabled(playlist.tracks.isEmpty).frame(minHeight: 44)
                    ForEach(playlist.tracks) { track in
                        HStack {
                            trackRow(track) { player.play(playlist.tracks, at: playlist.tracks.firstIndex(of: track) ?? 0) }
                            Button("Fjern fra playliste", systemImage: "minus.circle") { library.remove(track, from: playlist.id) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    Button("Slet playliste", systemImage: "trash", role: .destructive) { library.deletePlaylist(playlist.id) }.frame(minHeight: 44)
                }.padding(14).fadedGlassSurface(radius: 16, tint: MusicEdition.surface(palette))
            }
            Button("Opret playliste", systemImage: "text.badge.plus") { showPlaylistName = true }.frame(minHeight: 44)
        }
    }

    private func trackRow(_ track: MusicTrack, play: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 10) {
                    artwork(track)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(track.artist).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
                        if !track.durationLabel.isEmpty { Text(track.durationLabel).font(.caption.monospacedDigit()) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain)
            if library.downloading.contains(track.id) { ProgressView() }
            Menu("Sangvalg", systemImage: "ellipsis") {
                Button("Afspil", systemImage: "play.fill", action: play)
                Button("Føj til kø", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(track) }
                Button(library.saved.favorites.contains(where: { $0.id == track.id }) ? "Fjern favorit" : "Gem favorit",
                       systemImage: "heart") { library.toggleFavorite(track) }
                Menu("Føj til playliste", systemImage: "text.badge.plus") {
                    ForEach(library.saved.playlists) { list in Button(list.name) { library.add(track, to: list.id) } }
                    if library.saved.playlists.isEmpty { Button("Opret først en playliste") { showPlaylistName = true } }
                }
                if library.downloading.contains(track.id) {
                    Button("Stop hentning", systemImage: "stop.circle", role: .destructive) { library.cancelDownload(track) }
                } else if library.localURL(track) != nil {
                    Button("Slet hentet sang", systemImage: "trash", role: .destructive) { library.deleteDownload(track) }
                } else {
                    Button("Hent til offline", systemImage: "arrow.down.circle") { library.startDownload(track) }
                }
            }.frame(minWidth: 44, minHeight: 44)
        }.padding(10).fadedGlassSurface(radius: 14, tint: MusicEdition.surface(palette))
    }

    private func artwork(_ track: MusicTrack, size: CGFloat = 44) -> some View {
        MusicCover(url: track.artwork)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 44 ? 16 : 8))
    }

    private func performSearch() {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        search?.cancel()
        searchFocused = false
        searching = true
        searched = true
        results = []
        notice = nil
        section = .search
        search = Task {
            defer { if !Task.isCancelled { searching = false } }
            do {
                let tracks = try await MusicCatalog.search(input)
                try Task.checkCancellation()
                results = tracks
                if tracks.isEmpty { notice = "Ingen sange fundet. Prøv kunstnerens navn eller en anden titel." }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}

struct MusicCover: View {
    let url: URL?
    var symbol = "music.note"

    var body: some View {
        GeometryReader { geometry in
            KFImage(url)
                .placeholder { placeholder }
                .resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background { placeholder }
                .clipped()
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.26, green: 0.18, blue: 0.52), Color(red: 0.51, green: 0.26, blue: 0.57)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
        }
    }
}

enum MusicEdition {
    static let ink = Color(red: 24 / 255, green: 41 / 255, blue: 48 / 255)
    static let cream = Color(red: 255 / 255, green: 243 / 255, blue: 211 / 255)
    static let apricot = Color(red: 248 / 255, green: 177 / 255, blue: 132 / 255)
    static let mint = Color(red: 158 / 255, green: 228 / 255, blue: 201 / 255)
    static let lilac = Color(red: 201 / 255, green: 186 / 255, blue: 245 / 255)
    static let sky = Color(red: 162 / 255, green: 210 / 255, blue: 243 / 255)

    static func accent(_ palette: FadedPalette) -> Color {
        palette.isDark ? mint : Color(red: 15 / 255, green: 91 / 255, blue: 77 / 255)
    }

    static func surface(_ palette: FadedPalette) -> Color {
        palette.isDark
            ? Color(red: 49 / 255, green: 61 / 255, blue: 65 / 255)
            : Color(red: 255 / 255, green: 251 / 255, blue: 239 / 255)
    }

    static func paper(_ palette: FadedPalette) -> Color {
        switch palette.theme {
        case .day: Color(red: 246 / 255, green: 239 / 255, blue: 224 / 255)
        case .faded: FadedBrand.canvas
        case .oled: .black
        }
    }
}

struct MusicBackdrop: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.fadedLookPreset) private var lookPreset
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            MusicEdition.paper(palette)
            if palette.theme == .faded, let lookPreset {
                lookPreset.background(in: palette)
            } else if palette.theme != .oled && contrast == .standard {
                FadedBlueWallpaper()
                Canvas { context, size in
                    let center = CGPoint(x: size.width * 1.12, y: size.height * 0.78)
                    var grooves = Path()
                    for radius in stride(from: CGFloat(48), through: size.width * 1.4, by: 18) {
                        grooves.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2))
                    }
                    context.stroke(grooves, with: .color(palette.text.opacity(0.045)), lineWidth: 1)
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct VinylArtwork: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let disc = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                              width: side, height: side)
            context.fill(Path(ellipseIn: disc), with: .color(MusicEdition.ink))
            var rings = Path()
            for ring in 1...9 {
                let inset = CGFloat(ring) * side * 0.032
                rings.addEllipse(in: disc.insetBy(dx: inset, dy: inset))
            }
            context.stroke(rings, with: .color(MusicEdition.sky.opacity(0.42)), lineWidth: 0.7)
            let label = disc.insetBy(dx: side * 0.32, dy: side * 0.32)
            context.fill(Path(ellipseIn: label), with: .linearGradient(
                Gradient(colors: [MusicEdition.mint, MusicEdition.lilac]), startPoint: label.origin,
                endPoint: CGPoint(x: label.maxX, y: label.maxY)))
            let hole = disc.insetBy(dx: side * 0.472, dy: side * 0.472)
            context.fill(Path(ellipseIn: hole), with: .color(MusicEdition.ink))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
