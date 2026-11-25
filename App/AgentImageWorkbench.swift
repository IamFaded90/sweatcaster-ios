import SwiftUI
import UIKit

@MainActor struct AgentImageWorkbench: View {
    let bot: VillageBot
    let api: LiveAPI?
    let created: (PrivateChatTurn) -> Void
    @State private var prompt: String
    @State private var first: Data?
    @State private var second: Data?
    @State private var firstLoading = false
    @State private var secondLoading = false
    @State private var model = StudioImageModel.fluxKlein
    @State private var onPC = false
    @State private var downloads = false
    @State private var task: Task<Void, Never>?
    @State private var progress = ""
    @State private var notice: String?
    @State private var results: [PrivateChatTurn] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    init(bot: VillageBot, api: LiveAPI?, prompt: String = "", reference: Data? = nil,
         created: @escaping (PrivateChatTurn) -> Void) {
        self.bot = bot; self.api = api; self.created = created
        _prompt = State(initialValue: prompt); _first = State(initialValue: reference)
    }
    static func request(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:(?:kan|vil) du (?:lige )?)?(?:lav(?:e)?|generer(?:e)?|tegn(?:e)?) (?:mig )?(?:et )?(?:billede|foto|illustration)(?: af| med)?[ :]+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let range = Range(match.range(at: 1), in: clean) else { return nil }
        return String(clean[range])
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Billeder med \(bot.name)").font(.title2.bold())
                            Toggle("Brug PC", isOn: $onPC).disabled(api == nil || task != nil)
                            if !onPC {
                                Picker("Telefonmodel", selection: $model) {
                                    ForEach(StudioImageModel.allCases) { model in Text(model.title).tag(model) }
                                }.disabled(task != nil)
                                if !model.isInstalled { Button("Hent billedmodel", systemImage: "arrow.down.circle") { downloads = true } }
                            }
                            TextField("Beskriv billedet eller ændringen", text: $prompt, axis: .vertical).lineLimit(3...8)
                            ChatPhotoPicker(photo: $first, loading: $firstLoading, onError: { notice = $0 }, addTitle: "Reference 1", replaceTitle: "Skift reference 1")
                            if first != nil {
                                ChatPhotoPicker(photo: $second, loading: $secondLoading, onError: { notice = $0 }, addTitle: "Reference 2", replaceTitle: "Skift reference 2")
                            }
                            if onPC && first != nil {
                                Text("Denne PC-billedforbindelse understøtter tekst. Vælg iPhone og FLUX.2 Klein for at redigere med referencefotos her.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else if second != nil && model != .fluxKlein {
                                Text("To referencefotos kræver FLUX.2 Klein.").font(.subheadline)
                            }
                            HStack {
                                FadedPrimaryButton("Lav billede", icon: "photo.badge.plus") { generate(1) }
                                Button("4 forslag", systemImage: "square.grid.2x2") { generate(4) }.buttonStyle(.bordered)
                            }.disabled(!ready)
                            if task != nil { ProgressView(progress); Button("Stop", systemImage: "stop.circle") { task?.cancel() } }
                            if let notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    if !results.isEmpty { Text("Resultater · vælg et billede som udgangspunkt").font(.headline) }
                    ForEach(results.reversed()) { result in
                        if let name = result.imageName, let file = StudioImageFiles.savedImage(name),
                           let image = UIImage(contentsOfFile: file.path) {
                            FadedCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 18))
                                        .accessibilityLabel(result.prompt)
                                    Text(result.prompt).font(.caption).lineLimit(3)
                                    HStack {
                                        Button("Arbejd videre", systemImage: "pencil") {
                                            first = try? Data(contentsOf: file); second = nil
                                            prompt = ""; onPC = false; model = .fluxKlein
                                            notice = "Billedet er valgt som reference. Beskriv ændringen ovenfor. Den tidligere version bliver bevaret."
                                        }
                                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Del billede")
                                        Button("Slet", systemImage: "trash", role: .destructive) { delete(result, file: file) }
                                    }.buttonStyle(.bordered).disabled(task != nil)
                                }
                            }
                        }
                    }
                }.padding()
            }
            .background { FadedBackground() }
            .navigationTitle("Billeder i chat")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Tilbage til chat") { dismiss() } } }
            .sheet(isPresented: $downloads) { PhoneModelsView(initialImages: true) }
            .onAppear { results = MigratedAppData.shared.regularStudioTurns().filter { $0.botID == bot.id && $0.imageName != nil } }
            .onChange(of: first) { _, value in if value == nil { second = nil } }
            .onChange(of: phase) { _, value in if value != .active { task?.cancel() } }
            .onDisappear { task?.cancel() }
        }
    }
    private var ready: Bool {
        task == nil && !firstLoading && !secondLoading && (1...1_000).contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && (onPC ? api != nil && first == nil : model.isInstalled && (second == nil || model == .fluxKlein))
    }
    private func generate(_ count: Int) {
        guard ready else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = first, reference2 = second, selected = model, pc = onPC
        notice = nil
        task = Task {
            var completed = 0
            defer { task = nil }
            do {
                try StudioImageFiles.prepare(StudioImageFiles.library)
                for i in 0..<count {
                    try Task.checkCancellation()
                    progress = "Laver billede \(i + 1) af \(count)…"
                    let bytes: Data
                    if pc, let api { bytes = try await api.v2GenerateImage(prompt: text) }
                    else {
                        let seed = UInt32.random(in: 0...UInt32.max)
                        let output = try await StudioImageGeneration.whileDeviceReady(model: selected, protectBattery: true) {
                            try await StudioImageGeneration.render(model: selected, prompt: text, seed: seed,
                                source: reference, referenceMode: reference == nil ? nil : .edit, secondReference: reference2)
                        }
                        guard let output else { throw PhoneModelError.emptyResponse }; bytes = output
                    }
                    try Task.checkCancellation()
                    guard UIImage(data: bytes) != nil else { throw PhoneModelError.emptyResponse }
                    let file = StudioImageFiles.destination(in: StudioImageFiles.library)
                    try bytes.write(to: file, options: .atomic)
                    let turn = PrivateChatTurn(prompt: text, reply: "Billede lavet.", imageName: file.lastPathComponent,
                        source: pc ? "PC" : "iPhone", botID: bot.id, replyModelName: pc ? nil : selected.title)
                    do { try MigratedAppData.shared.saveRegularStudioTurns(MigratedAppData.shared.regularStudioTurns() + [turn]) }
                    catch { try? StudioImageFiles.deleteSavedImage(file); throw error }
                    results.append(turn); created(turn); completed += 1
                    if bot.id != VillageBot.lumiID, MusicPlayer.shared.playing, let song = MusicPlayer.shared.current {
                        do {
                            try PersonalMediaLink.Store().remember(.init(id: turn.id, botID: bot.id, imageName: file.lastPathComponent,
                                prompt: text, musicID: song.id, musicTitle: song.title, musicArtist: song.artist, created: .now))
                        } catch { AppDiagnostics.record(error) }
                    }
                }
                notice = count == 1 ? "Billedet er også i chatten." : "Fire forslag er klar og gemt i chatten."
            } catch {
                notice = Task.isCancelled ? "Stoppet. \(completed) færdige billeder er bevaret."
                    : "Kunne ikke lave næste billede: \(error.localizedDescription). \(completed) færdige billeder er bevaret."
            }
        }
    }
    private func delete(_ turn: PrivateChatTurn, file: URL) {
        do {
            try StudioImageFiles.deleteSavedImage(file)
            try MigratedAppData.shared.saveRegularStudioTurns(MigratedAppData.shared.regularStudioTurns().filter { $0.id != turn.id })
            try PersonalMediaLink.Store().remove(turn.id)
            results.removeAll { $0.id == turn.id }
        } catch { notice = "Billedet kunne ikke slettes helt. Prøv igen." }
    }
}

extension AgentPhoneChat {
    @ViewBuilder func generatedImage(_ turn: PrivateChatTurn) -> some View {
        if let name = turn.imageName, let file = StudioImageFiles.savedImage(name), let image = UIImage(contentsOfFile: file.path) {
            Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 16)).accessibilityLabel(turn.prompt)
            HStack {
                Button("Arbejd videre", systemImage: "pencil") {
                    interactiveTool = .images("", try? Data(contentsOf: file))
                }
                ShareLink(item: file) { Label("Del", systemImage: "square.and.arrow.up") }
                Button("Slet", systemImage: "trash", role: .destructive) {
                    do {
                        try StudioImageFiles.deleteSavedImage(file)
                        try MigratedAppData.shared.saveRegularStudioTurns(MigratedAppData.shared.regularStudioTurns().filter { $0.id != turn.id })
                        try PersonalMediaLink.Store().remove(turn.id)
                        turns.removeAll { $0.id == turn.id }
                    } catch { notice = "Billedet kunne ikke slettes helt. Prøv igen." }
                }
            }.buttonStyle(.bordered).disabled(running != nil)
        }
    }
}
