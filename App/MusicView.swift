import SwiftUI
import Kingfisher

@MainActor struct MusicView: View {
    private enum Section: String, CaseIterable {
        case home = "Oversigt", search = "Søg", library = "Mit bibliotek"
    }

    let onBack: () -> Void
    @Environment(\.fadedPalette) private var palette
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
    @State private var showPlaylistName = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Musik", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { page in Text(page.rawValue).tag(page) }
                    }.pickerStyle(.segmented)
                    switch section {
                    case .home: overview
                    case .search: searchContent
                    case .library: libraryContent
                    }
                    if let notice = library.notice { Text(notice).foregroundStyle(palette.secondary) }
                    if let notice = player.notice { Text(notice).foregroundStyle(palette.secondary) }
                }.padding(FadedSpacing.edge)
            }.scrollDismissesKeyboard(.interactively)
                .foregroundStyle(palette.text).background { FadedBackground() }
                .navigationTitle("Musik")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left", action: onBack)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Musikvalg", systemImage: "ellipsis") {
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
                    Button("Annuller", role: .cancel) {}
                }
                .sheet(isPresented: $showPlayer) { MusicPlayingView() }
                .onDisappear { search?.cancel(); searching = false }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button {
                section = .search
            } label: {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Find din næste sang").font(.largeTitle.weight(.heavy))
                        Label("Søg i musik", systemImage: "magnifyingglass").font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 145, alignment: .leading)
                .padding(20)
                .foregroundStyle(.white)
                .background(alignment: .trailing) {
                    Image(systemName: "waveform")
                        .font(.system(size: 128, weight: .black))
                        .foregroundStyle(.white.opacity(0.15))
                        .rotationEffect(.degrees(-18))
                        .offset(x: 14, y: 4)
                        .accessibilityHidden(true)
                }
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.11, blue: 0.44),
                                                     Color(red: 0.50, green: 0.22, blue: 0.48)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }.buttonStyle(.plain)

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
            }.padding(.horizontal, 14).fadedGlassSurface()
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
        shelf("Gå på opdagelse") {
            genre("Dansk musik", icon: "sparkles", hue: 0.95)
            genre("Hip-hop", icon: "mic.fill", hue: 0.66)
            genre("Pop", icon: "bolt.fill", hue: 0.06)
            genre("House", icon: "waveform", hue: 0.49)
        }
    }

    private func genre(_ title: String, icon: String, hue: Double) -> some View {
        Button {
            query = title
            performSearch()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2.bold()).accessibilityHidden(true)
                Text(title).font(.headline).lineLimit(2)
            }.frame(width: min(112, shelfWidth - 24), alignment: .leading)
                .padding(14)
                .foregroundStyle(.white)
                .background(Color(hue: hue, saturation: 0.71, brightness: 0.42), in: .rect(cornerRadius: 16))
        }.buttonStyle(.plain)
            .accessibilityHint("Søger efter musik i kataloget")
    }

    private var shelfWidth: CGFloat { min(220, coverWidth) }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12, content: content)
                    .scrollTargetLayout()
            }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }
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
                else {
                    Button(player.playing ? "Pause" : "Afspil", systemImage: player.playing ? "pause.fill" : "play.fill") { player.toggle() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                Button("Næste sang", systemImage: "forward.end.fill") { player.next() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.padding(10)
                .foregroundStyle(palette.text)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(red: 0.48, green: 0.32, blue: 0.81).opacity(0.16))
                        }
                }
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(palette.secondary.opacity(0.25)) }
                .overlay(alignment: .bottom) {
                    if player.duration.isFinite, player.duration > 0, player.position.isFinite {
                        ProgressView(value: max(0, min(player.position, player.duration)), total: player.duration)
                            .tint(palette.lime)
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
            }
            DisclosureGroup("Hentet · \(library.saved.downloads.count)") {
                ForEach(library.saved.downloads) { track in
                    trackRow(track) { player.play(library.saved.downloads, at: library.saved.downloads.firstIndex(of: track) ?? 0) }
                }
                if library.saved.downloads.isEmpty { Text("Hent en sang fra dens menu for at lytte offline.").font(.footnote) }
            }
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
                }
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
        }.padding(10).fadedGlassSurface()
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
