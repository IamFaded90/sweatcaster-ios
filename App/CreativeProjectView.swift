import SwiftUI
import UIKit
import AVFAudio

@MainActor struct CreativeProjectView: View {
    let bot: VillageBot
    let model: String
    var initial: CreativeProject?
    @State private var project: CreativeProject
    @State private var projects: [CreativeProject] = []
    @State private var crew: [VillageBot] = []
    @State private var writerID: UUID
    @State private var designerID: UUID
    @State private var voiceID = ""
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var notice: String?
    @State private var showImages = false
    @State private var showVoices = false
    @State private var showRooms = false
    @State private var showLibrary = false
    @State private var confirmDelete = false
    @StateObject private var speech = ChristelPlayer()
    @State private var audio: AVAudioPlayer?
    @Environment(\.dismiss) private var dismiss
    let storage = CreativeProject.Store()
    init(bot: VillageBot, model: String, initial: CreativeProject? = nil) {
        self.bot = bot; self.model = model; self.initial = initial
        _project = State(initialValue: initial ?? .init(botID: bot.id))
        _writerID = State(initialValue: bot.id); _designerID = State(initialValue: bot.id)
    }
    private var writer: VillageBot { crew.first { $0.id == writerID } ?? bot }
    private var designer: VillageBot { crew.first { $0.id == designerID } ?? bot }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Fra idé til noget, du kan bruge").font(.title2.bold())
                    Text("Dit hold arbejder med tekst, billede og stemme i samme forløb. Alt bliver på telefonen, indtil du selv deler det.").font(.subheadline).foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Det vil jeg lave", selection: $project.kind) { ForEach(CreativeProject.Kind.allCases) { Text($0.rawValue).tag($0) } }.disabled(busy)
                            TextField("Beskriv din idé og de vigtige detaljer", text: $project.brief, axis: .vertical).lineLimit(3...8).disabled(busy)
                            Picker("Tekstforfatter", selection: $writerID) { ForEach(crew) { Text($0.name).tag($0.id) } }.disabled(busy)
                            Picker("Billedskaber", selection: $designerID) { ForEach(crew) { Text($0.name).tag($0.id) } }.disabled(busy)
                            FadedPrimaryButton("Lav det første forslag", icon: "sparkles") { draft() }.disabled(busy || project.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tekst og motiv").font(.headline)
                            TextField("Titel", text: $project.title).textFieldStyle(.roundedBorder).disabled(busy)
                            TextEditor(text: $project.text).frame(minHeight: 160).disabled(busy)
                            TextField("Billedbeskrivelse", text: $project.imagePrompt, axis: .vertical).lineLimit(2...6).disabled(busy)
                            Button("Gem tekst og idé", systemImage: "square.and.arrow.down") { save(); saveText() }.frame(minHeight: 44)
                            FadedSecondaryButton(project.imageName == nil ? "Lav billedet" : "Arbejd videre med billedet", icon: "photo.badge.plus") { save(); showImages = true }
                                .disabled(busy || project.imagePrompt.isEmpty || project.imagePrompt.count > 1_000)
                        }
                    }
                    if let name = project.imageName, let url = StudioImageFiles.savedImage(name), let image = UIImage(contentsOfFile: url.path) {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 18))
                                HStack {
                                    ShareLink(item: url) { Label("Del billede", systemImage: "square.and.arrow.up") }
                                    Button("Slet billede", systemImage: "trash", role: .destructive) { deleteImage(url) }
                                }.buttonStyle(.bordered)
                                if project.kind == .room {
                                    FadedPrimaryButton("Gem som illustreret agentrum", icon: "house.lodge") { publishRoom() }.disabled(busy)
                                    if project.publishedRoomID != nil { Button("Åbn mine agentrum") { showRooms = true }.frame(minHeight: 44) }
                                }
                            }
                        }
                    }
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Lydhilsen og færdig fil").font(.headline)
                            if !DownloadedAgentVoice.playable.isEmpty {
                                Picker("Fortællerstemme", selection: $voiceID) { ForEach(DownloadedAgentVoice.playable) { Text($0.name).tag($0.id) } }
                                Button("Lav lydhilsenen", systemImage: "waveform") { makeVoice() }.frame(minHeight: 44).disabled(busy || project.text.isEmpty)
                            } else { Button("Hent eller vælg stemmer") { showVoices = true }.frame(minHeight: 44) }
                            if project.hasVoice, let url = storage.asset(project.id, name: "narration.wav") {
                                HStack {
                                    ShareLink(item: url) { Label("Del lyd", systemImage: "square.and.arrow.up") }
                                    Button("Hør", systemImage: "play.circle") { read() }
                                    Button("Slet lyd", systemImage: "trash", role: .destructive) { deleteAsset("narration.wav") }
                                }.buttonStyle(.bordered)
                            }
                            FadedPrimaryButton("Lav PDF med tekst og billede", icon: "doc.richtext") { exportPDF() }.disabled(busy || project.title.isEmpty || project.text.isEmpty)
                            if project.hasPDF, let url = storage.asset(project.id, name: "project.pdf") {
                                HStack {
                                    ShareLink(item: url) { Label("Del PDF", systemImage: "square.and.arrow.up") }
                                    Button("Slet PDF", systemImage: "trash", role: .destructive) { deleteAsset("project.pdf") }
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if busy { ProgressView("Dit hold arbejder…"); Button("Stop") { operation?.cancel(); speech.stop() } }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Dit kreative hold")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Luk") { save(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Forløb", systemImage: "ellipsis") {
                            Button("Mine kreative forløb") { projects = (try? storage.list(botID: bot.id)) ?? []; showLibrary = true }
                            Button("Nyt forløb") { save(); project = .init(botID: bot.id) }
                            Button("Slet forløbets tekst, lyd og PDF", role: .destructive) { confirmDelete = true }
                        }.disabled(busy)
                    }
                }
                .onAppear {
                    crew = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                    if !crew.contains(where: { $0.id == bot.id }) { crew.insert(bot, at: 0) }
                    if voiceID.isEmpty {
                        voiceID = project.voiceID ?? UserDefaults.standard.string(forKey: PhoneModels.agentVoiceKey(bot.id)) ?? bot.voice
                        if DownloadedAgentVoice.selected(voiceID) == nil { voiceID = DownloadedAgentVoice.playable.first?.id ?? DownloadedAgentVoice.presets[0].id }
                    }
                }
                .onDisappear { operation?.cancel(); speech.stop(); audio?.stop() }
                .sheet(isPresented: $showImages) {
                    AgentImageWorkbench(bot: designer, api: nil, prompt: project.imagePrompt,
                        reference: project.imageName.flatMap(StudioImageFiles.savedImage).flatMap { try? Data(contentsOf: $0) }) { turn in
                        project.imageName = turn.imageName; captureMusic(); save()
                    }
                }
                .sheet(isPresented: $showVoices) { NavigationStack { SettingsDownloadedVoices() } }
                .sheet(isPresented: $showRooms) { NavigationStack { AgentRoomPublishedView(api: nil) } }
                .sheet(isPresented: $showLibrary) {
                    NavigationStack {
                        List(projects) { item in Button(item.title.isEmpty ? item.kind.rawValue : item.title) { save(); project = item; showLibrary = false } }
                            .navigationTitle("Mine kreative forløb").toolbar { Button("Luk") { showLibrary = false } }
                    }
                }
                .confirmationDialog("Slet dette kreative forløb?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Slet tekst, lyd og PDF", role: .destructive) {
                        do { try storage.remove(project.id); project = .init(botID: bot.id) } catch { notice = "Forløbet kunne ikke slettes." }
                    }
                    Button("Behold", role: .cancel) {}
                } message: { Text("Billeder, en tekstkopi i Mine projekter og et gemt agentrum har deres egne sletknapper.") }
        }
    }
    private func save() {
        if !voiceID.isEmpty { project.voiceID = voiceID }
        project.updated = .now
        do { try storage.save(project) } catch { notice = error.localizedDescription }
    }
    private func captureMusic() {
        if MusicPlayer.shared.playing, let track = MusicPlayer.shared.current {
            project.musicID = track.id; project.musicTitle = track.title; project.musicArtist = track.artist
        }
    }
    private func draft() {
        guard !busy, PhoneModels.isReady(model), project.brief.count <= 2_000 else { notice = "Vælg en klar telefonmodel, og hold beskrivelsen under 2.000 tegn."; return }
        busy = true; notice = nil; let brief = project.brief; let kind = project.kind
        operation = Task {
            defer { busy = false }
            do {
                let identity = AgentPersonality.instructions(name: writer.name, personality: writer.personality, traits: writer.traits, settings: AgentPersonality.load(writer.id))
                let driver = AgentReplyDriver(provider: .phone, model: model)
                let response = try await driver.respond(to: brief, original: brief,
                    instructions: identity + "\nLav et forslag til \(kind.rawValue). Svar kun med JSON {\"title\":\"kort titel\",\"text\":\"færdig dansk tekst\",\"imagePrompt\":\"engelsk motivbeskrivelse højst 800 tegn\"}. Brug de oplyste detaljer. Opfind ikke dato, adresse eller fakta om brugeren. Manglende detaljer skrives [udfyld]. Ved agentrum: beskriv et illustreret isometrisk rum uden personer og med gulvplads til figurer foran.",
                    history: [], usesTools: false, showsPartialText: false) { _ in }
                try Task.checkCancellation(); let draft = try CreativeProject.draft(response)
                project.title = draft.title; project.text = draft.text; project.imagePrompt = draft.imagePrompt; captureMusic(); save()
                if designer.id != writer.id {
                    do {
                        let visualIdentity = AgentPersonality.instructions(name: designer.name, personality: designer.personality, traits: designer.traits, settings: AgentPersonality.load(designer.id))
                        let refinement = try await driver.respond(to: "Brugerens idé: " + brief + "\nFørste billedidé: " + draft.imagePrompt, original: brief,
                            instructions: visualIdentity + "\nDu har billedopgaven i holdet. Lever kun en engelsk billedbeskrivelse på højst 800 tegn. Bevar brugerens detaljer. Ved agentrum: isometrisk illustreret rum uden personer, med ledig gulvplads foran. Ingen JSON eller indledning.", history: [], usesTools: false, showsPartialText: false) { _ in }
                        try Task.checkCancellation()
                        if !refinement.isEmpty, refinement.count <= 1_000 { project.imagePrompt = refinement; save() }
                    } catch { if Task.isCancelled { return }; notice = "Teksten er gemt. Billedskaberens ekstra forslag blev ikke klar; du kan fortsætte med den første billedidé."; return }
                }
                notice = "Teksten og billedidéen er klar. Ret gerne detaljerne, og lav billedet, når du er tilfreds."
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func saveText() {
        do {
            var values = try FadedProjectStore.load(); values.removeAll { $0.id == project.id }
            values.append(.init(id: project.id, title: project.title, content: project.text, updatedAt: project.updated)); try FadedProjectStore.save(values)
            notice = "Teksten er også gemt i Mine projekter."
        } catch { notice = "Teksten kunne ikke gemmes i Mine projekter." }
    }
    private func makeVoice() {
        guard !busy, let voice = DownloadedAgentVoice.selected(voiceID) else { return }
        guard project.text.count <= 1_500 else { notice = "Forkort lydhilsenen til 1.500 tegn. Den fulde tekst kan stadig komme i PDF’en."; return }
        busy = true; notice = nil; speech.stop(); MusicPlayer.shared.pause(); save()
        operation = Task {
            defer { busy = false }
            do {
                let bytes = try await AgentVoiceDownload.audio(project.text, voice: voice, language: "da-DK", rate: 1)
                try Task.checkCancellation()
                guard let file = storage.asset(project.id, name: "narration.wav") else { throw CreativeProject.Failure.invalid }
                try bytes.write(to: file, options: .atomic); project.hasVoice = true; save(); notice = "Lydhilsenen er klar til deling."
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func read() {
        guard let file = storage.asset(project.id, name: "narration.wav") else { return }
        do {
            audio?.stop(); MusicPlayer.shared.pause()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            audio = try AVAudioPlayer(contentsOf: file); audio?.play()
        } catch { notice = "Lydhilsenen kunne ikke afspilles." }
    }
    private func exportPDF() {
        do { _ = try CreativeProjectExport.pdf(project, store: storage); project.hasPDF = true; save(); notice = "PDF’en er klar til deling." }
        catch { notice = "PDF’en kunne ikke laves. " + error.localizedDescription }
    }
    private func deleteAsset(_ name: String) {
        guard let url = storage.asset(project.id, name: name) else { return }
        do { speech.stop(); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; if name == "project.pdf" { project.hasPDF = false } else { project.hasVoice = false }; save() }
        catch { notice = "Filen kunne ikke slettes." }
    }
    private func deleteImage(_ url: URL) {
        do {
            let removed = MigratedAppData.shared.regularStudioTurns().filter { $0.imageName == project.imageName }
            try StudioImageFiles.deleteSavedImage(url)
            try MigratedAppData.shared.saveRegularStudioTurns(MigratedAppData.shared.regularStudioTurns().filter { $0.imageName != project.imageName })
            for turn in removed { try PersonalMediaLink.Store().remove(turn.id) }
            project.imageName = nil; save()
        } catch { notice = "Billedet kunne ikke slettes helt." }
    }
    private func publishRoom() {
        do { project.publishedRoomID = try CreativeProjectExport.publishRoom(project, bot: designer); save(); notice = "Det illustrerede rum er gemt i Mine agentrum på telefonen." }
        catch { notice = "Rummet kunne ikke gemmes. " + error.localizedDescription }
    }
}
