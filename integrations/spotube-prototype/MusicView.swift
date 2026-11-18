import SwiftUI

@MainActor struct MusicView: View {
    let api: LiveAPI?
    let onBack: () -> Void
    @Environment(\.fadedPalette) private var palette
    @ObservedObject private var playback = MusicPlayback.shared
    @State private var query = ""
    @State private var results: [MusicTrack] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var section = "Søg"
    @State private var playlistName = ""
    @State private var namingPlaylist = false
    @State private var deletingQueue = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.l) {
                    FadedCard(size: .hero) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Din musik. Din kø.", systemImage: "music.note.list").font(.title2.bold())
                            FadedDetailText("Afspil her, kig til landsbyen, og tag musikken med på låseskærmen.")
                            FadedDetailText("Find musik direkte på iPhone. Du behøver ikke have PC’en tændt.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if playback.queue.current != nil { playerCard }
                    Picker("Musik", selection: $section) {
                        Text("Søg").tag("Søg")
                        Text("Kø · \(playback.queue.entries.count)").tag("Kø")
                        Text("Playlister").tag("Playlister")
                    }.pickerStyle(.segmented)
                    if section == "Søg" { searchContent }
                    else if section == "Kø" { queueContent }
                    else { playlistContent }
                    if let message = notice ?? playback.notice { FadedDetailText(message) }
                    FadedDetailText("Køen er tilpasset fra Spotube. Denne afspiller er en iPhone-tilpasning og åbner ingen anden app.")
                }.padding(FadedSpacing.edge).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .foregroundStyle(palette.text)
            .background { FadedBackground() }
            .navigationTitle("Musik")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Tilbage", systemImage: "chevron.left", action: onBack) }
            }
            .onDisappear { searchTask?.cancel(); searching = false }
            .alert("Gem kø som playliste", isPresented: $namingPlaylist) {
                TextField("Navn", text: $playlistName)
                Button("Gem") { playback.savePlaylist(name: playlistName); playlistName = "" }
                Button("Annullér", role: .cancel) {}
            }
            .confirmationDialog("Tøm hele køen?", isPresented: $deletingQueue, titleVisibility: .visible) {
                Button("Tøm kø og stop musikken", role: .destructive) { playback.clear() }
                Button("Annullér", role: .cancel) {}
            }
        }
    }

    private var playerCard: some View {
        FadedCard(accent: .green) {
            VStack(alignment: .leading, spacing: 12) {
                if let track = playback.queue.current {
                    Text(track.title).font(.headline)
                    Text(track.artist).font(.subheadline).foregroundStyle(palette.secondary)
                }
                Slider(value: Binding(get: { min(playback.elapsed, max(playback.duration, 1)) }, set: playback.seek),
                       in: 0...max(1, playback.duration)).disabled(playback.duration <= 0)
                    .accessibilityLabel("Placering i nummeret")
                HStack {
                    Text(time(playback.elapsed))
                    Spacer()
                    Text(time(playback.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                HStack(spacing: 20) {
                    Button("Forrige", systemImage: "backward.end.fill", action: playback.previous)
                    Spacer()
                    if playback.loading { ProgressView().accessibilityLabel("Finder lydkilden") }
                    Button(playback.playing || playback.loading ? "Pause" : "Afspil",
                           systemImage: playback.playing || playback.loading ? "pause.fill" : "play.fill",
                           action: playback.toggle).font(.title2)
                    Spacer()
                    Button("Næste", systemImage: "forward.end.fill", action: playback.next)
                }.labelStyle(.iconOnly).buttonStyle(.bordered).frame(minHeight: 44)
                Menu {
                    ForEach([15, 30, 60, 90], id: \.self) { minutes in
                        Button("Stop om \(minutes) minutter") { playback.setSleepTimer(minutes: minutes) }
                    }
                    Button("Slå sovetimer fra") { playback.setSleepTimer(minutes: nil) }
                } label: {
                    Label(playback.sleepUntil.map { "Stopper kl. " + $0.formatted(date: .omitted, time: .shortened) }
                          ?? "Sovetimer", systemImage: "moon.zzz").frame(minHeight: 44)
                }
            }
        }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            FadedCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Søg efter sang eller kunstner", text: $query)
                        .textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit(search)
                    FadedPrimaryButton(searching ? "Søger…" : "Find musik", icon: "magnifyingglass", action: search)
                        .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !NativeMusicCatalog.shared.available)
                    if !NativeMusicCatalog.shared.available { FadedDetailText("Musikkilden er ikke installeret på denne iPhone.") }
                }
            }
            if !results.isEmpty {
                FadedSecondaryButton("Afspil alle søgeresultater", icon: "play.fill") { playback.load(results) }
            }
            ForEach(Array(results.enumerated()), id: \.offset) { index, track in
                trackCard(track) { playback.load(results, index: index) }
            }
        }
    }

    private var queueContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if playback.queue.entries.isEmpty { FadedDetailText("Køen er tom. Find en sang under Søg og tryk Afspil eller Læg i kø.") }
            else {
                HStack {
                    Button("Gem playliste", systemImage: "text.badge.plus") { namingPlaylist = true }
                        .disabled(playback.playlists.count >= 25)
                    Spacer()
                    Button("Tøm kø", systemImage: "trash", role: .destructive) { deletingQueue = true }
                }.frame(minHeight: 44)
            }
            ForEach(Array(playback.queue.entries.enumerated()), id: \.offset) { index, track in
                FadedCard(accent: playback.queue.currentIndex == index ? .green : .cyan) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { playback.play(index: index) } label: {
                            Label(track.title, systemImage: playback.queue.currentIndex == index ? "waveform" : "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        Text(track.artist).font(.caption).foregroundStyle(palette.secondary)
                        HStack {
                            Button("Flyt op", systemImage: "arrow.up") { playback.move(from: index, to: index - 1) }.disabled(index == 0)
                            Button("Flyt ned", systemImage: "arrow.down") { playback.move(from: index, to: index + 1) }
                                .disabled(index + 1 == playback.queue.entries.count)
                            Spacer()
                            Button("Fjern", systemImage: "trash", role: .destructive) { playback.remove(at: index) }
                        }.labelStyle(.iconOnly).buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var playlistContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if playback.playlists.isEmpty { FadedDetailText("Gem din kø som en playliste under Kø. Playlister ligger på din iPhone.") }
            ForEach(playback.playlists) { list in
                FadedCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(list.name).font(.headline)
                        FadedDetailText("\(list.tracks.count) numre")
                        HStack {
                            Button("Afspil", systemImage: "play.fill") { playback.load(list.tracks) }
                            Spacer()
                            Button("Slet", systemImage: "trash", role: .destructive) { playback.deletePlaylist(list.id) }
                        }.buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private func trackCard(_ track: MusicTrack, play: @escaping () -> Void) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(track.title).font(.headline)
                Text(track.artist).font(.subheadline).foregroundStyle(palette.secondary)
                HStack {
                    Button("Afspil", systemImage: "play.fill", action: play).buttonStyle(.borderedProminent)
                    Spacer()
                    Menu {
                        Button("Afspil som den næste") { playback.add(track, next: true) }
                        Button("Læg sidst i køen") { playback.add(track) }
                    } label: { Label("Læg i kø", systemImage: "text.badge.plus").frame(minHeight: 44) }
                }
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 160, !searching else { return }
        searching = true; notice = nil; searchTask?.cancel()
        searchTask = Task {
            defer { searching = false }
            do {
                let reply = try await NativeMusicCatalog.shared.search(text)
                try Task.checkCancellation()
                results = reply
                if results.isEmpty { notice = "Ingen musik fundet. Prøv sangens navn eller kunstneren." }
            } catch {
                if !Task.isCancelled { notice = (error as? MusicCatalogError)?.errorDescription ?? "Kunne ikke søge. Tjek internetforbindelsen og prøv igen." }
            }
        }
    }
    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 86_400))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
