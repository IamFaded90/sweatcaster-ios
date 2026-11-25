import CastBrowserFeature
import SwiftUI

@MainActor struct EveningPlanView: View {
    var initial = EveningPlan.Request()
    let open: (EveningPlan.Kind) -> Void
    @State private var request = EveningPlan.Request()
    @State private var choices: [EveningPlan.Candidate] = []
    @State private var tracks: [MusicTrack] = []
    @State private var pages: [CastLibraryBridge.Item] = []
    @State private var busy = false
    @State private var notice: String?
    @State private var generation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    init(initial: EveningPlan.Request = .init(), open: @escaping (EveningPlan.Kind) -> Void) {
        self.initial = initial; self.open = open; _request = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Hvad har du lyst til i aften?").font(.title2.bold())
                            Picker("Din tid", selection: $request.minutes) {
                                ForEach([15, 30, 60, 90, 120, 180, 240], id: \.self) { Text("\($0) min").tag($0) }
                            }
                            Picker("Din stemning", selection: $request.mood) {
                                ForEach(EveningPlan.Mood.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Toggle("Kun det, der virker uden internet", isOn: $request.offlineOnly)
                            FadedPrimaryButton("Find mine tre valg", icon: "sparkles") { refresh() }.disabled(busy)
                            if busy { ProgressView("Finder noget til dig…"); Button("Stop") { generation?.cancel() } }
                        }
                    }
                    if let notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(choices) { choice in
                        FadedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(choice.kind == .film ? "Film og serier" : choice.kind == .music ? "Musik" : "Landsbyen",
                                      systemImage: choice.kind == .film ? "play.tv" : choice.kind == .music ? "music.note" : "house.lodge")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(choice.title).font(.title3.bold())
                                Text(choice.detail).foregroundStyle(.secondary)
                                Label(choice.offline ? "Klar uden internet" : "Bruger internet", systemImage: choice.offline ? "iphone" : "globe")
                                    .font(.caption)
                                FadedPrimaryButton(choice.isSource ? "Vælg en film her" : "Start", icon: "play.fill") { start(choice) }
                            }
                        }
                    }
                }.padding()
            }.background { FadedBackground() }
                .navigationTitle("Gør min aften god")
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear { refresh() }
                .onChange(of: request.minutes) { _, _ in generation?.cancel(); choices = [] }
                .onChange(of: request.mood) { _, _ in generation?.cancel(); choices = [] }
                .onChange(of: request.offlineOnly) { _, _ in generation?.cancel(); choices = [] }
                .onDisappear { generation?.cancel() }
        }
    }
    private func refresh() {
        generation?.cancel()
        let selected = request
        busy = true; notice = nil; choices = []
        generation = Task {
            defer { busy = false }
            pages = CastLibraryBridge.items()
            let library = MusicLibrary.shared
            var music = library.saved.downloads + library.saved.favorites + library.recent
            if !selected.offlineOnly {
                do { music += try await MusicCatalog.search(selected.mood.musicQuery) }
                catch { if !Task.isCancelled { notice = "Netsøgningen svarede ikke. Her er det, du allerede har." } }
            }
            guard !Task.isCancelled else { return }
            var ids = Set<String>(); tracks = music.filter { ids.insert($0.id).inserted }
            var pool = pages.map { page in
                EveningPlan.Candidate(id: page.id, kind: .film, title: page.title,
                    detail: page.isSource ? "En af dine gemte filmkilder. Du vælger selve filmen på siden."
                        : "Fra din filmhistorik. Siden åbnes, så du kan vælge afspilning.", seconds: page.seconds, isSource: page.isSource)
            }
            pool += tracks.map { track in
                EveningPlan.Candidate(id: track.id, kind: .music, title: track.title, detail: track.artist,
                    seconds: track.duration, offline: library.localURL(track) != nil)
            }
            pool.append(.init(id: "village", kind: .village, title: "Et besøg hos dine agenter",
                              detail: "Tag en rolig tur i landsbyen, eller start en samtale med en agent.", offline: true))
            choices = EveningPlan.choices(pool, request: selected)
            if selected.offlineOnly && tracks.isEmpty { notice = "Der er ingen hentede sange endnu. Landsbyen er klar uden internet." }
            else if pages.isEmpty && !selected.offlineOnly { notice = "Gem en filmkilde i Underholdning for også at få filmvalg her." }
        }
    }
    private func start(_ item: EveningPlan.Candidate) {
        switch item.kind {
        case .film:
            guard let page = pages.first(where: { $0.id == item.id }) else { return }
            CastLibraryBridge.open(page.page)
        case .music:
            guard let track = tracks.first(where: { $0.id == item.id }) else { return }
            MusicPlayer.shared.play(track)
        case .village: break
        }
        dismiss(); open(item.kind)
    }
}
