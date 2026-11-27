import SwiftUI
import UniformTypeIdentifiers

@MainActor struct SongStudioView: View {
    let api: LiveAPI?
    init(api: LiveAPI?, initial: SongDraft? = nil) {
        self.api = api
        _draft = State(initialValue: initial ?? SongDraft())
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var phone = PhoneSongStudio.shared
    @State private var onPhone = true
    @State private var draft = SongDraft()
    @State private var previous: SongDraft?
    @State private var catalog: SongStudioCatalog?
    @State private var favoriteID = ""
    @State private var sourceName = ""
    @State private var voiceName = ""
    @State private var phoneMusicURL: URL?
    @State private var phoneVoiceURL: URL?
    @State private var phoneMusicName = ""
    @State private var phoneVoiceName = ""
    @State private var picking = false
    @State private var pickingVoice = false
    @State private var busy = false
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    @State private var referenceSources: [AgentWebSources.Source] = []
    private var currentProblem: String? {
        var value = draft
        if onPhone {
            value.source = phoneMusicURL.map { _ in Data([0]) }
            value.voice = phoneVoiceURL.map { _ in Data([0]) }
        }
        return value.problem
    }
    @State private var catalogRevision = 0
    @State private var lastPCUpdate: Date?
    @State private var pcStatusUnavailable = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Musik, du selv er med til at skabe").font(.title2.bold())
                    Text("Lav en ny sang, brug en favorit som inspiration, eller giv en lydfil en ny stil. Originalen bliver bevaret.").foregroundStyle(.secondary)
                    Picker("Skab sangen på", selection: $onPhone) {
                        Label("iPhone", systemImage: "iphone").tag(true)
                        Label("PC", systemImage: "desktopcomputer").tag(false)
                    }.pickerStyle(.segmented).disabled(busy || phone.busy || phone.referenceBusy)
                    if !onPhone { activePCSongs }
                    if onPhone {
                        Label("ACE-Step 1.5 · musik med vokal · uden PC efter hentning", systemImage: "iphone")
                        Text("Første prøve kræver en rigtig iPhone. Bliv i appen, mens sangen skabes; den første klargøring kan tage ekstra tid. Start med 30 sekunder.").font(.caption).foregroundStyle(.secondary)
                        if !phone.installed {
                            FadedSecondaryButton("Hent ACE-Step · ca. 10 GB", icon: "arrow.down.circle") { phone.download() }.disabled(busy || phone.busy || phone.referenceBusy)
                            Text("ACE-Step 1.5 2B · MIT · iPhone-port af Yu Yao-Hsing. Modellen hentes én gang og fylder cirka 10 GB udpakket.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Slet sangmodellen fra iPhone", systemImage: "trash", role: .destructive) { phone.removeModel() }.disabled(busy || phone.busy || phone.referenceBusy)
                            if phone.referenceBusy {
                                ProgressView(phone.deletingReferenceModel ? "Sletter modeldele…" : phone.referenceProgress)
                                if !phone.deletingReferenceModel {
                                    Button("Stop klargøring", systemImage: "stop.circle") { phone.cancelReferenceModel() }.frame(minHeight: 44)
                                }
                            } else if phone.referenceReady {
                                Label("Modeldele til lydreference er hentet", systemImage: "checkmark.circle")
                                Button("Slet modeldelene til lydreference", systemImage: "trash", role: .destructive) { phone.removeReferenceModel() }.disabled(busy || phone.busy)
                            } else {
                                FadedSecondaryButton("Hent lydreference · ca. 380 MB", icon: "arrow.down.circle") { phone.downloadReferenceModel() }.disabled(busy || phone.busy)
                                Text("Bruges til remix og stemmeprøve. Klargøringen kræver ca. 1,5 GB ledig plads. Første prøve skal testes på iPhone.").font(.caption).foregroundStyle(.secondary)
                                Button("Slet delvist hentede modeldele", systemImage: "trash", role: .destructive) { phone.removeReferenceModel() }.disabled(busy || phone.busy)
                            }
                        }
                        if phone.busy {
                            if let fraction = phone.downloadFraction {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProgressView(value: fraction)
                                    Text(phone.progress).font(.subheadline)
                                    if !phone.downloadSize.isEmpty {
                                        Text(phone.downloadSize + " · \(Int(fraction * 100)) %")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }.accessibilityElement(children: .combine)
                            } else {
                                ProgressView(phone.deletingModel ? "Sletter sangmodellen…" : phone.progress)
                            }
                            if !phone.deletingModel {
                                Button(phone.downloadFraction == nil ? "Stop forsøget" : "Stop hentning", systemImage: "stop.circle") { phone.cancel() }.frame(minHeight: 44)
                            }
                        }
                        if let notice = phone.notice { Text(notice).foregroundStyle(.secondary) }
                    } else if api == nil {
                        Label("Forbind PC’en for at skabe musik. Dine færdige sange kan afspilles uden PC.", systemImage: "desktopcomputer")
                    } else if catalog?.ready != true {
                        Label("Musikmotoren skal være klar på PC’en. Din beskrivelse kan skrives imens.", systemImage: "music.note")
                    }
                    FadedCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Hvad vil du lave?", selection: $draft.mode) {
                                ForEach(SongMode.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            TextField("Sangens titel", text: $draft.title)
                                .textFieldStyle(.plain).foregroundStyle(palette.text).padding(12).frame(minHeight: 48)
                                .background(palette.raised, in: .rect(cornerRadius: FadedRadius.small))
                            TextField("Fx mørk house, varm vokal og et stort omkvæd", text: $draft.prompt, axis: .vertical)
                                .textFieldStyle(.plain).foregroundStyle(palette.text).lineLimit(3...7).padding(12)
                                .background(palette.raised, in: .rect(cornerRadius: FadedRadius.small))
                            Toggle("Giv min beskrivelse flere musikdetaljer", isOn: $draft.enhancePrompt)
                            if draft.enhancePrompt && !draft.prompt.isEmpty {
                                DisclosureGroup("Se beskrivelsen, motoren får") {
                                    Text(SongPrompt.expanded(draft.prompt, instrumental: draft.instrumental)).font(.caption).textSelection(.enabled)
                                }
                            }
                            if !library.saved.favorites.isEmpty {
                                Picker("Vælg fra favoritter", selection: $favoriteID) {
                                    Text("Ingen favorit valgt").tag("")
                                    ForEach(library.saved.favorites) { Text($0.title + " · " + $0.artist).tag($0.id) }
                                }.onChange(of: favoriteID) { _, _ in chooseFavorite() }
                            }
                            if !draft.favorite.isEmpty {
                                Text("Valgt favorit: " + draft.favorite).font(.caption).foregroundStyle(.secondary)
                                Text((onPhone ? phoneMusicName : sourceName).isEmpty
                                    ? "Kun navn og kunstner er valgt. Beskriv, hvad du kan lide ved musikken, eller tilføj en lydreference."
                                    : onPhone ? "Den lokale lydfil bruges som reference på iPhone." : "Op til tre minutter af lydfilen bruges som reference.").font(.caption).foregroundStyle(.secondary)
                                Button("Find stilen i min favorit", systemImage: "sparkle.magnifyingglass") { suggest(style: true) }.frame(minHeight: 44)
                                if !referenceSources.isEmpty {
                                    DisclosureGroup("Kilder til musikstilen") {
                                        ForEach(referenceSources, id: \.url) { Link($0.title, destination: $0.url).font(.caption) }
                                    }
                                }
                            }
                            if draft.mode != .new {
                                let musicName = onPhone ? phoneMusicName : sourceName
                                Button(musicName.isEmpty ? "Vælg lydfil" : "Skift lydfil · " + musicName, systemImage: "waveform") {
                                    pickingVoice = false; picking = true
                                }.frame(minHeight: 44)
                                if draft.mode == .remix {
                                    Text("Vælg en lydfil, der varer mindst så længe som dit remix. De første tre minutter kan bruges.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if onPhone ? phoneMusicURL != nil : draft.source != nil {
                                    Button("Fjern musikreference", role: .destructive) {
                                        if onPhone { phoneMusicURL = nil; phoneMusicName = "" }
                                        else { draft.source = nil; sourceName = "" }
                                    }
                                }
                            }
                            Toggle("Instrumental · uden sang", isOn: $draft.instrumental)
                            if !draft.instrumental {
                                Picker("Sangsprog", selection: $draft.language) {
                                    Text("Dansk").tag("da"); Text("Engelsk").tag("en")
                                }
                                TextField("Sangtekst · tomt felt giver en ny tekst", text: $draft.lyrics, axis: .vertical).lineLimit(4...12)
                                Button("Skriv et nyt tekstforslag", systemImage: "pencil.and.sparkles") { suggest(style: false) }.frame(minHeight: 44)
                                DisclosureGroup("Prøv med din egen sangstemme") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Vælg en ren optagelse af dig selv. Det første forsøg er et kort omkvæd; resultatet er en stemmereference og kan afvige fra din rigtige stemme.").font(.subheadline)
                                        let name = onPhone ? phoneVoiceName : voiceName
                                        Button(name.isEmpty ? "Vælg min egen optagelse" : "Skift optagelse · " + name, systemImage: "mic") {
                                            pickingVoice = true; picking = true
                                        }.frame(minHeight: 44)
                                        if onPhone ? phoneVoiceURL != nil : draft.voice != nil {
                                            Button("Fjern stemmereference", role: .destructive) {
                                                if onPhone { phoneVoiceURL = nil; phoneVoiceName = "" }
                                                else { draft.voice = nil; voiceName = "" }
                                            }
                                        }
                                        Text("Din personlige iPhone-stemme til oplæsning bliver bevaret. Sangprøven bruger optagelsen, du vælger her.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            HStack {
                                Text("Længde")
                                Slider(value: $draft.seconds, in: 10...180, step: 10).disabled(onPhone ? phoneVoiceURL != nil : draft.voice != nil)
                                Text("\(Int(draft.seconds)) sek.").font(.caption.monospacedDigit())
                            }
                            if busy { ProgressView("Arbejder…") }
                            if let notice { Text(notice).foregroundStyle(.secondary) }
                            if let problem = currentProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                            if onPhone && (phoneMusicURL != nil || phoneVoiceURL != nil) && !phone.referenceReady {
                                Text("Hent først modeldelene til lydreference ovenfor.").font(.caption).foregroundStyle(.secondary)
                            }
                            FadedPrimaryButton(onPhone ? "Skab sang på iPhone" : draft.voice == nil ? "Skab sang på PC" : "Lav kort stemmeprøve", icon: "music.note") { create() }
                                .disabled(busy || phone.busy || phone.referenceBusy || currentProblem != nil ||
                                    (onPhone ? !phone.installed || ((phoneMusicURL != nil || phoneVoiceURL != nil) && !phone.referenceReady) : api == nil || catalog?.ready != true))
                        }.disabled(busy || phone.busy || phone.referenceBusy)
                    }
                    let jobs = phone.songs + (catalog?.jobs ?? [])
                    if !jobs.isEmpty {
                        Text("Dine sange og forsøg").font(.title3.bold())
                        ForEach(jobs.filter { $0.state != "removed" && (onPhone || $0.finished) }) { job in
                            FadedCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(job.title).font(.headline)
                                    Text(job.notice).font(.subheadline).foregroundStyle(.secondary)
                                    if job.state == "completed" {
                                        HStack {
                                            if !phone.songs.contains(where: { $0.id == job.id }) {
                                                Button("Hent til Musik", systemImage: "arrow.down.circle") { download(job) }
                                            }
                                            if let file = SongLibrary().localURL(SongLibrary.trackID(job.id)) {
                                                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                                                Button("Afspil", systemImage: "play.fill") {
                                                    MusicPlayer.shared.play(.init(id: SongLibrary.trackID(job.id), title: job.title, artist: "Skabt i FadedAI", duration: job.seconds))
                                                }
                                            }
                                        }.buttonStyle(.bordered)
                                    }
                                    Button("Slet sang og forsøg", systemImage: "trash", role: .destructive) { remove(job) }.frame(minHeight: 44)
                                }.disabled(busy || phone.busy || phone.referenceBusy)
                            }
                        }
                    }
                }.padding()
            }.background { MusicBackdrop() }.navigationTitle("Sangstudie")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Opdatér", systemImage: "arrow.clockwise") { refresh() }.disabled(busy) }
                }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.audio]) { result in
                    switch result { case .success(let url):
                        if onPhone {
                            if pickingVoice { phoneVoiceURL = url; phoneVoiceName = url.lastPathComponent; draft.seconds = 30 }
                            else { phoneMusicURL = url; phoneMusicName = url.lastPathComponent }
                        } else { importAudio(url, voice: pickingVoice) }
                    case .failure: notice = "Lydfilen kunne ikke vælges." }
                }
                .onChange(of: draft.instrumental) { _, value in
                    if value { draft.voice = nil; voiceName = ""; phoneVoiceURL = nil; phoneVoiceName = "" }
                }
                .onChange(of: draft.mode) { _, value in
                    if value == .new { draft.source = nil; sourceName = ""; phoneMusicURL = nil; phoneMusicName = "" }
                }
                .onChange(of: onPhone) { _, value in
                    if (value && phoneVoiceURL != nil) || (!value && draft.voice != nil) { draft.seconds = 30 }
                    if !value { refresh() }
                }
                .onChange(of: phase) { _, value in PhoneSongStudio.changePhase(value) }
                .task { refresh(); await phone.refreshReferenceModel() }
                .task(id: onPhone) { await refreshActivePCSongs() }
                .onDisappear { task?.cancel(); phone.cancel() }
        }
    }
    private var activePCSongs: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach((catalog?.jobs ?? []).filter { !$0.finished }) { job in
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(palette.cyan)
                            Text(job.title).font(.headline)
                            Spacer()
                            ProgressView().accessibilityLabel(job.progressTitle)
                        }
                        Text(job.progressTitle).font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach(0..<4) { step in
                                Capsule().fill(step <= job.progressStep ? palette.cyan : palette.border)
                                    .frame(height: 4)
                            }
                        }.accessibilityLabel("Trin \(min(4, job.progressStep + 1)) af 4. Ingen tidsprognose.")
                        Text(job.notice).font(.subheadline).foregroundStyle(palette.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince1970 - job.created))
                            Text("Tid siden bestilling · \(elapsed / 60) min \(elapsed % 60) sek")
                                .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                        }
                        if pcStatusUnavailable {
                            Label("Status kunne ikke opdateres. Jeg prøver igen; sangen sendes ikke en gang til.", systemImage: "wifi.exclamationmark")
                                .font(.caption).foregroundStyle(palette.secondary)
                        }
                        if let lastPCUpdate {
                            Text("Senest kontakt med PC · " + lastPCUpdate.formatted(date: .omitted, time: .standard))
                                .font(.caption).foregroundStyle(palette.secondary)
                        }
                        Button("Slet forsøg", systemImage: "trash", role: .destructive) { remove(job) }
                            .frame(minHeight: 44).disabled(busy)
                    }
                }
            }
        }
    }

    private func chooseFavorite() {
        referenceSources = []
        guard let track = library.saved.favorites.first(where: { $0.id == favoriteID }) else {
            draft.favorite = ""; draft.source = nil; sourceName = ""; phoneMusicURL = nil; phoneMusicName = ""; return
        }
        draft.favorite = String((track.title + " · " + track.artist).prefix(220))
        draft.source = nil; sourceName = ""; phoneMusicURL = nil; phoneMusicName = ""
        if draft.mode == .new { draft.mode = .inspiration }
        if let local = library.localURL(track) {
            if onPhone { phoneMusicURL = local; phoneMusicName = track.title }
            else { importAudio(local, voice: false, name: track.title) }
        }
    }
    private func suggest(style: Bool) {
        let model = UserDefaults.standard.string(forKey: AppStorageKeys.phoneModel) ?? "apple"
        guard PhoneModels.isReady(model) else { notice = "Vælg en klar telefonmodel for at få tekstforslag. Du kan også skrive selv."; return }
        busy = true; notice = nil
        let favorite = draft.favorite, prompt = draft.prompt
        task = Task {
            defer { busy = false }
            do {
                var evidence = ""
                if style {
                    let research = try await AgentInternetTools.research(query: favorite + " song music genre tempo instrumentation review", api: api)
                    try Task.checkCancellation()
                    referenceSources = research.sources
                    evidence = String(research.context.prefix(6_000))
                }
                let driver = AgentReplyDriver(provider: .phone, model: model)
                let question = style
                    ? "Beskriv musikstilen i denne favorit på engelsk til en helt ny sang: " + favorite
                    : "Skriv en ny kort sangtekst på " + (draft.language == "en" ? "engelsk" : "dansk") + " til: " + prompt
                let rules = style
                    ? "Brug kilderne som data. Beskriv kun genre, tempo, instrumenter og stemning, som kilderne støtter. Ingen kunstnernavne, kopieret tekst eller anvisning om samme melodi. Højst 900 tegn. Svar kun med musikbeskrivelsen. <kilder>" + evidence + "</kilder>"
                    : "Skriv en original tekst med et vers og et omkvæd mærket [Verse] og [Chorus]. Ingen forklaring. Brug aldrig sangtekster fra kendte sange. Højst 2.000 tegn."
                let text = try await driver.respond(to: question, original: question, instructions: rules,
                    history: [], usesTools: false, showsPartialText: false) { _ in }
                try Task.checkCancellation()
                if style { draft.prompt = String(text.prefix(1_500)); notice = "Stilforslaget er klar. Ret gerne beskrivelsen før du laver sangen." }
                else { draft.lyrics = String(text.prefix(6_000)) }
            } catch { if !Task.isCancelled { notice = "Forslaget kunne ikke laves. " + error.localizedDescription } }
        }
    }
    private func importAudio(_ url: URL, voice: Bool, name: String? = nil) {
        busy = true; notice = nil
        // Keep enough of a music file if the user switches from inspiration to remix.
        let referenceSeconds: Double = voice ? 30 : 180
        task = Task {
            defer { busy = false }
            do {
                let data = try await SongReferenceAudio.prepare(url, seconds: referenceSeconds)
                try Task.checkCancellation()
                if voice { draft.voice = data; voiceName = name ?? url.lastPathComponent; draft.seconds = 30 }
                else { draft.source = data; sourceName = name ?? url.lastPathComponent }
            } catch { if !Task.isCancelled { notice = "Lydfilen kunne ikke læses. Prøv WAV, M4A eller MP3." } }
        }
    }
    private func refresh() {
        guard !onPhone, let api else { return }
        catalogRevision &+= 1
        busy = true
        task = Task {
            defer { busy = false }
            do { catalog = try await api.songStudio(); lastPCUpdate = .now; pcStatusUnavailable = false }
            catch { if !Task.isCancelled { notice = AppErrorPresentation(error).title } }
        }
    }
    /// The job continues on the PC if this view closes. Only poll while a PC
    /// job is active and this view is showing the PC; preserve the last known
    /// list during transient disconnections.
    private func refreshActivePCSongs() async {
        guard !onPhone, let api else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled else { return }
            guard phase == .active else { continue }
            guard !busy, catalog?.hasActiveJobs == true else { continue }
            do {
                let revision = catalogRevision
                let updated = try await api.songStudio()
                guard !Task.isCancelled else { return }
                if !busy && catalogRevision == revision {
                    catalog = updated; lastPCUpdate = .now; pcStatusUnavailable = false
                }
            } catch {
                if !Task.isCancelled { pcStatusUnavailable = true }
            }
        }
    }
    private func create() {
        if phone.songs.contains(where: { $0.id == draft.id }) ||
            catalog?.jobs.contains(where: { $0.id == draft.id && $0.state == "completed" }) == true {
            draft.id = UUID(); previous = nil
        }
        guard currentProblem == nil, !busy, !phone.busy else { return }
        catalogRevision &+= 1
        busy = true; notice = nil
        task = Task {
            defer { busy = false }
            do {
                if !draft.instrumental, draft.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notice = "Skriver en ny sangtekst på telefonen…"
                    let model = UserDefaults.standard.string(forKey: AppStorageKeys.phoneModel) ?? "apple"
                    guard PhoneModels.isReady(model) else {
                        notice = "Skriv en sangtekst, vælg Instrumental eller gør en telefonmodel klar til tekstforslaget."; return
                    }
                    let driver = AgentReplyDriver(provider: .phone, model: model)
                    let question = "Skriv en ny kort sangtekst på " + (draft.language == "en" ? "engelsk" : "dansk") + " til: " + draft.prompt
                    let text = try await driver.respond(to: question, original: question,
                        instructions: "Skriv en original sangtekst med [Verse] og [Chorus]. Kun teksten, højst 2.000 tegn. Ingen kendte sangtekster.",
                        history: [], usesTools: false, showsPartialText: false) { _ in }
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        notice = "Tekstforslaget var tomt. Skriv selv en tekst eller vælg Instrumental."; return
                    }
                    draft.lyrics = String(text.prefix(6_000))
                }
                if onPhone {
                    if catalog?.jobs.contains(where: { $0.id == draft.id }) == true { draft.id = UUID(); previous = nil }
                    phone.create(draft, musicReference: phoneMusicURL, voiceReference: phoneVoiceURL); return
                }
                guard let api else { return }
                if let previous {
                    var comparison = draft; comparison.id = previous.id
                    if comparison != previous { draft.id = UUID() }
                }
                previous = draft; let input = draft
                notice = "Sender din sang til PC’en…"
                let result = try await api.createSong(input)
                // Keep the accepted job even if the following catalog request fails.
                catalog = SongStudioCatalog(ready: true, voiceReference: catalog?.voiceReference ?? true,
                    jobs: [result] + (catalog?.jobs ?? []).filter { $0.id != result.id })
                lastPCUpdate = .now; pcStatusUnavailable = false
                notice = result.notice
                do { catalog = try await api.songStudio(); lastPCUpdate = .now }
                catch { pcStatusUnavailable = true }
            } catch {
                if !Task.isCancelled {
                    if let failure = error as? APIError, case let .http(422, problem) = failure,
                       let message = problem?.message, !message.isEmpty {
                        notice = message
                    } else {
                        notice = "Tjek sanglisten med Opdatér, før du prøver igen. " + AppErrorPresentation(error).title
                    }
                }
            }
        }
    }
    private func download(_ job: SongJob) {
        guard let api else { return }
        busy = true; notice = nil
        task = Task {
            defer { busy = false }
            do {
                let audio = try await api.songAudio(job.id)
                try Task.checkCancellation()
                var track = try SongLibrary().save(audio, job: job)
                // Cover art is optional: never lose a successfully saved song if rendering fails.
                track.artwork = try? SongCover.save(title: job.title, id: job.id)
                library.addGenerated(track); notice = "Sangen ligger nu i Mit bibliotek og kan afspilles uden PC."
            } catch { if !Task.isCancelled { notice = "Sangen kunne ikke gemmes. " + error.localizedDescription } }
        }
    }
    private func remove(_ job: SongJob) {
        if phone.songs.contains(where: { $0.id == job.id }) { phone.remove(job); return }
        guard let api else { return }
        catalogRevision &+= 1
        busy = true; notice = nil
        task = Task {
            defer { busy = false }
            do {
                let result = try await api.removeSong(job.id)
                let track = MusicTrack(id: SongLibrary.trackID(job.id), title: job.title, artist: "Skabt i FadedAI")
                library.deleteDownload(track)
                let localFilesRemain = SongLibrary().containsStoredFiles(job.id)
                if let old = catalog {
                    catalog = SongStudioCatalog(ready: old.ready, voiceReference: old.voiceReference,
                                                jobs: old.jobs.filter { $0.id != job.id })
                }
                notice = localFilesRemain
                    ? "Sangen blev slettet på PC’en, men kopien på iPhone kunne ikke slettes. Prøv i musikbiblioteket."
                    : "Sangen og forsøget er slettet."
                if result.engineMayContinue ?? true {
                    notice = (notice ?? "") + " PC’ens musikmotor kan fortsætte med at arbejde, indtil det aktive forsøg er færdigt."
                }
                if result.cleanupPending == true {
                    notice = (notice ?? "") + " PC’en prøver at fjerne de sidste filer, når de ikke længere er i brug."
                }
                do { catalog = try await api.songStudio() }
                catch { notice = (notice ?? "") + " Sanglisten kunne ikke opdateres; prøv Opdatér senere." }
            } catch { notice = "Sangen kunne ikke slettes. " + error.localizedDescription }
        }
    }
}

@MainActor enum SongCover {
    static func save(title: String, id: UUID) throws -> URL? {
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.16, blue: 0.22), FadedBrand.blue, FadedBrand.mint],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().stroke(.white.opacity(0.2), lineWidth: 36).frame(width: 330).offset(x: 100, y: -100)
            VStack(alignment: .leading) {
                Text("FADED · ORIGINAL").font(.system(size: 18, weight: .bold, design: .monospaced)).tracking(3)
                Spacer()
                Image(systemName: "waveform").font(.system(size: 80))
                Text(title).font(.system(size: 42, weight: .bold)).lineLimit(4)
            }.padding(40).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
        }.frame(width: 512, height: 512)
        guard let image = ImageRenderer(content: view).uiImage, let data = image.pngData() else { return nil }
        let file = SongLibrary().root.appendingPathComponent(id.uuidString.lowercased() + ".png")
        try data.write(to: file, options: .atomic); return file
    }
}
