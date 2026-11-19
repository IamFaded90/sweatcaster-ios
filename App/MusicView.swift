import SwiftUI
import Kingfisher

@MainActor struct MusicView: View {
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
    @State private var section = 0
    @State private var showPlayer = false
    @State private var showPlaylistName = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Søg efter sang eller kunstner", text: $query).submitLabel(.search)
                            .onSubmit { performSearch() }
                        Button("Søg", systemImage: "magnifyingglass") { performSearch() }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.horizontal, 14).fadedGlassSurface()
                    Picker("Musik", selection: $section) {
                        Text("Søg").tag(0)
                        Text("Mit bibliotek").tag(1)
                    }.pickerStyle(.segmented)
                    if section == 0 {
                        if searching { ProgressView("Finder musik…") }
                        if let notice { Text(notice).foregroundStyle(palette.secondary) }
                        if !searched {
                            FadedCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("Din musik", systemImage: "music.note").font(.title2.bold())
                                    Text("Søg, tryk på en sang, og lyt. Musikken kan fortsætte, når du går videre i appen eller låser telefonen.")
                                    Text("Musikkilde · YouTube").font(.caption).foregroundStyle(palette.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(results) { track in trackRow(track) { player.play(results, at: results.firstIndex(of: track) ?? 0) } }
                    } else { libraryContent }
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
                    Button("Opret") { library.createPlaylist(playlistName); playlistName = ""; section = 1 }
                    Button("Annuller", role: .cancel) {}
                }
                .sheet(isPresented: $showPlayer) { MusicPlayingView() }
                .onDisappear { search?.cancel(); searching = false }
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
                            Text(track.artist).lineLimit(1).font(.caption)
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
            }.padding(12).fadedGlassSurface().padding(.horizontal, FadedSpacing.edge)
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

    private func artwork(_ track: MusicTrack) -> some View {
        KFImage(track.artwork)
            .placeholder { Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity) }
            .resizable().scaledToFill()
            .frame(width: 44, height: 44).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func performSearch() {
        search?.cancel()
        let input = query
        searching = true
        searched = true
        results = []
        notice = nil
        section = 0
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
