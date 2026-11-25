import SwiftUI

@MainActor struct MusicMixView: View {
    @State private var mood = EveningPlan.Mood.calm
    @State private var buildsEnergy = false
    @State private var offline = false
    @State private var tracks: [MusicTrack] = []
    @State private var split = 0
    @State private var notice: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var showVoices = false
    @AppStorage("fadedai.music.host.enabled.v1") private var host = false
    @AppStorage("fadedai.music.host.voice.v1") private var voice = ""
    @ObservedObject private var pack = AgentVoiceDownload.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Musik til din stund").font(.title2.bold())
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Stemning", selection: $mood) { ForEach(EveningPlan.Mood.allCases) { Text($0.rawValue).tag($0) } }
                            Toggle("Byg langsomt mere energi på", isOn: $buildsEnergy)
                            Toggle("Kun hentet musik", isOn: $offline)
                            Toggle("Korte danske værtsindslag", isOn: $host)
                            if host {
                                if !DownloadedAgentVoice.playable.isEmpty {
                                    Picker("Værtens stemme", selection: $voice) {
                                        ForEach(DownloadedAgentVoice.playable) { Text($0.name).tag($0.id) }
                                    }
                                } else { Button("Hent eller hør stemmer") { showVoices = true } }
                            }
                            FadedPrimaryButton("Lav mit miks", icon: "sparkles") { prepare() }.disabled(busy)
                            if busy { ProgressView("Sammensætter din kø…"); Button("Stop") { operation?.cancel() } }
                        }
                    }
                    if !tracks.isEmpty {
                        FadedPrimaryButton("Start hele mikset", icon: "play.fill") { start() }.disabled(host && !AgentVoiceDownload.ready(selection: voice))
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            FadedCard {
                                HStack {
                                    VStack(alignment: .leading) {
                                        if buildsEnergy && index == split { Text("Her stiger energien").font(.caption).foregroundStyle(.mint) }
                                        Text(track.title).font(.headline); Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Fjern", systemImage: "minus.circle") {
                                        tracks.remove(at: index); if index < split { split -= 1 }
                                    }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                                }
                            }
                        }
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding()
            }.background { MusicBackdrop() }.navigationTitle("Din musikvært")
                .toolbar { Button("Luk") { dismiss() } }
                .sheet(isPresented: $showVoices) { NavigationStack { SettingsDownloadedVoices() } }
                .onAppear { if DownloadedAgentVoice.selected(voice) == nil { voice = DownloadedAgentVoice.all[0].id } }
                .onChange(of: mood) { _, _ in invalidate() }
                .onChange(of: buildsEnergy) { _, _ in invalidate() }
                .onChange(of: offline) { _, _ in invalidate() }
                .onDisappear { operation?.cancel() }
        }
    }
    private func invalidate() { operation?.cancel(); tracks = []; split = 0 }
    private func prepare() {
        operation?.cancel(); busy = true; notice = nil; tracks = []
        let selected = mood; let rising = buildsEnergy; let localOnly = offline
        operation = Task {
            defer { busy = false }
            let library = MusicLibrary.shared
            let local = localOnly ? library.saved.downloads : library.saved.favorites + library.saved.downloads + library.recent
            var first = local; var second = local
            if !localOnly {
                do {
                    first += try await MusicCatalog.search(selected.musicQuery)
                    if rising { second += try await MusicCatalog.search(EveningPlan.Mood.fun.musicQuery) }
                } catch { if !Task.isCancelled { notice = "Musiksøgningen svarede ikke. Jeg bruger biblioteket, hvis der er noget gemt." } }
            }
            guard !Task.isCancelled else { return }
            let feedback = MusicMix.feedback()
            let beginning = MusicMix.tracks(first, mood: selected, feedback: feedback, limit: rising ? 5 : 12)
            let ids = Set(beginning.map(\.id))
            let ending = rising ? MusicMix.tracks(second.filter { !ids.contains($0.id) }, mood: .fun, feedback: feedback, limit: 7) : []
            split = beginning.count; tracks = beginning + ending
            if tracks.isEmpty { notice = localOnly ? "Hent musik i biblioteket først, så kan vi lave et miks uden internet." : "Der blev ikke fundet afspilbare valg. Prøv igen eller søg efter en kunstner i Musik." }
        }
    }
    private func start() {
        guard !tracks.isEmpty else { return }
        var messages: [String: String] = [:]
        if host && AgentVoiceDownload.ready(selection: voice) {
            messages[tracks[0].id] = "Her er dit miks. Vi starter med \(tracks[0].title) af \(tracks[0].artist)."
            if buildsEnergy, tracks.indices.contains(split) { messages[tracks[split].id] = "Nu løfter vi energien med \(tracks[split].title)." }
        }
        MusicPlayer.shared.playMix(tracks, announcements: messages, voice: voice)
        dismiss(); FadedHubRoute.open(.music)
    }
}
