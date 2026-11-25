import AVFAudio
import SwiftUI
import UIKit

@MainActor struct AgentTasteTest: View {
    let bot: VillageBot
    let api: LiveAPI?
    let kind: AgentTasteKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var speech = SpeechBox()
    @StateObject private var pcSpeech = ChristelPlayer()
    @State private var round = AgentTasteRound()
    @State private var names: [String: String] = [:]
    @State private var heard: Set<String> = []
    @State private var previewID: String?
    @State private var loading = true
    @State private var reload = 0
    @State private var notice: String?
    @State private var savedName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(bot.name).font(.title.bold())
                    if loading {
                        ProgressView("Finder valgmuligheder…")
                    } else if let savedName {
                        Label(savedName + " er valgt til " + bot.name, systemImage: "checkmark.circle.fill")
                        Button("Færdig") { dismiss() }.buttonStyle(FadedButtonStyle(kind: .primary))
                    } else if round.pair.count == 2 {
                        Text(kind == .voice ? "Lyt til den samme sætning med begge stemmer. Hvilken passer til \(bot.name)?"
                             : kind == .figure ? "Hvilken figur skal \(bot.name) bruge i landsbyen?"
                             : "Hvilken billedstil skal \(bot.name) bruge til dine billeder?")
                        ForEach(Array(round.pair.enumerated()), id: \.element) { index, id in
                            candidate(id, letter: index == 0 ? "A" : "B")
                        }
                        if kind == .voice, round.pair.contains(where: { !heard.contains($0) }) {
                            Text("Afspil begge prøver for at vælge.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if savedName == nil, !loading, let favorite = round.favorite {
                        if round.pair.isEmpty {
                            Text("Din favorit er " + (names[favorite] ?? "") + ".").font(.headline)
                        }
                        Button(round.pair.isEmpty ? "Brug min favorit" : "Afslut og brug min seneste favorit") {
                            save(favorite)
                        }.buttonStyle(FadedButtonStyle(kind: .primary))
                    }
                    if let notice, savedName == nil {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                    if !loading && savedName == nil && kind == .voice {
                        Button("Hent stemmelisten igen", systemImage: "arrow.clockwise") { reload += 1 }
                            .frame(minHeight: 44)
                    }
                    if !loading && savedName == nil && kind == .imageStyle,
                       AgentImageTasteStyle.selected(for: bot.id) != nil {
                        Button("Fjern agentens gemte billedstil") {
                            UserDefaults.standard.removeObject(forKey: AgentImageTasteStyle.key(for: bot.id))
                            dismiss()
                        }.frame(minHeight: 44)
                    }
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 580).frame(maxWidth: .infinity)
            }
            .background { FadedBackground() }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
        .task(id: reload) { await load() }
        .onReceive(speech.$isSpeaking) { speaking in
            if speaking, let previewID, AgentPCVoice(rawValue: previewID) == nil { heard.insert(previewID) }
        }
        .onReceive(pcSpeech.$playing) { playing in
            if playing, let previewID, AgentPCVoice(rawValue: previewID) != nil { heard.insert(previewID) }
        }
        .onChange(of: pcSpeech.notice) { _, message in
            if message != nil { notice = "Prøven kunne ikke afspilles. Tjek PC-forbindelsen, og prøv igen." }
        }
        .onChange(of: phase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }

    private func candidate(_ id: String, letter: String) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                if kind == .voice {
                    let active = previewID == id && (speech.playback != nil || pcSpeech.playing || pcSpeech.loading)
                    Button(active ? "Stop prøve " + letter : "Hør prøve " + letter,
                           systemImage: active ? "stop.circle" : "play.circle") {
                        if active { stop() } else { play(id) }
                    }.frame(minHeight: 44)
                    if previewID == id && pcSpeech.loading { ProgressView("Henter lyd…") }
                } else if kind == .figure, let frame = VillageProductionArt.frame(character: id, direction: 0, step: 0) {
                    Image(uiImage: frame).resizable().interpolation(.none).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 130).accessibilityLabel(names[id] ?? "Landsbyfigur")
                } else if let style = AgentImageTasteStyle(rawValue: id) {
                    Image(style.sampleAsset).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 160)
                        .accessibilityLabel("Eksempel i " + style.title)
                }
                Button("Jeg vælger " + letter) {
                    stop()
                    notice = nil
                    round.choose(id)
                }
                .buttonStyle(FadedButtonStyle(kind: .secondary))
                .disabled(kind == .voice && !round.pair.allSatisfy(heard.contains))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        stop()
        heard.removeAll()
        notice = nil
        loading = true
        var choices: [(String, String)] = []
        var current: String?
        switch kind {
        case .voice:
            let pcVoices = if let api { (try? await api.agentPCVoices(for: bot.id)) ?? [] } else { [AgentPCVoice]() }
            guard !Task.isCancelled else { return }
            choices = pcVoices.filter { $0.language == "da-DK" }.map { ($0.id, $0.label) }
            var namesSeen = Set<String>()
            for voice in LocalSpeechVoice.options(language: "da-DK", includePersonalVoices: true)
                where voice.language.hasPrefix("da") && namesSeen.insert(voice.name.lowercased()).inserted {
                choices.append((voice.identifier, LocalSpeechVoice.label(voice)))
            }
            choices += DownloadedAgentVoice.playable.map { ($0.id, $0.label) }
            current = AgentVoiceSelection.identifier(for: bot)
            if choices.count < 2 {
                notice = "Der skal være to forskellige danske stemmer at lytte til. Forbind PC’en med dens stemmer, eller hent en anden dansk stemme på iPhone."
            }
        case .figure:
            if VillagePortraitIdentity.name(for: bot) != nil {
                notice = bot.name + " bruger sin originale figur."
            } else if let profiles = try? MigratedAppData.shared.loadBots().get() {
                let occupied = Set(profiles.filter { $0.id != bot.id }.map(\.villageFigure))
                choices = VillageCharacterCatalog.all.filter {
                    !occupied.contains($0.id) && VillageProductionArt.frame(character: $0.id, direction: 0, step: 0) != nil
                }.map { ($0.id, $0.name) }
                current = profiles.first { $0.id == bot.id }?.villageFigure
                if choices.count < 2 { notice = "Der er færre end to ledige landsbyfigurer." }
            } else { notice = "Kunne ikke læse agenterne fra telefonen." }
        case .imageStyle:
            choices = AgentImageTasteStyle.allCases.filter { UIImage(named: $0.sampleAsset) != nil }
                .map { ($0.rawValue, $0.title) }
            current = AgentImageTasteStyle.selected(for: bot.id)?.rawValue
            if choices.count < 2 { notice = "Der er færre end to billedeksempler i appen." }
        }
        names = Dictionary(choices, uniquingKeysWith: { first, _ in first })
        var ids = Array(names.keys).shuffled()
        if let current, let pos = ids.firstIndex(of: current) {
            ids.swapAt(0, pos)
            if ids.count >= 2 && Bool.random() { ids.swapAt(0, 1) }
        }
        round = AgentTasteRound(ids)
        loading = false
    }

    private func play(_ id: String) {
        stop()
        notice = nil
        previewID = id
        let sample = LocalSpeechVoice.previewSentence(language: "da-DK")
        if let local = DownloadedAgentVoice.selected(id) {
            pcSpeech.playDownloaded(text: sample, voice: local, agentID: bot.id, rate: bot.voiceRate ?? 1)
        } else if let pcVoice = AgentPCVoice(rawValue: id), let api {
            pcSpeech.playAgentVoice(text: sample, voice: pcVoice, agentID: bot.id, pc: api)
        } else if let voice = AgentVoiceSelection.resolve(identifier: id, language: "da-DK") {
            speech.play(LocalSpeechVoice.utterance(sample, voice: voice, rate: bot.voiceRate ?? 1),
                        as: .preview, agentID: bot.id)
        } else { notice = "Stemmen er blevet utilgængelig. Hent stemmelisten igen." }
    }

    private func save(_ id: String) {
        stop()
        guard let name = names[id], id == round.favorite else { return }
        do {
            let store = MigratedAppData.shared
            switch kind {
            case .voice:
                guard heard.contains(id) else { return }
                try AgentVoiceSelection.save(id, for: bot.id, store: store)
            case .figure:
                var bots = try JSONDecoder().decode([VillageBot].self, from: store.villageBots)
                guard let i = bots.firstIndex(where: { $0.id == bot.id }) else { throw AgentVoiceSelection.SaveFailure.unknownBot }
                guard VillagePortraitIdentity.name(for: bots[i]) == nil,
                      VillageCharacterCatalog.valid(id, for: bot.id) != nil,
                      !bots.contains(where: { $0.id != bot.id && $0.villageFigure == id }) else {
                    notice = "Figuren kan ikke længere vælges. Åbn sammenligningen igen."
                    return
                }
                bots[i].chooseVillageFigure(id)
                try store.saveVillageBots(JSONEncoder().encode(bots))
            case .imageStyle:
                guard try store.loadBots().get().contains(where: { $0.id == bot.id }) else { throw AgentVoiceSelection.SaveFailure.unknownBot }
                guard let style = AgentImageTasteStyle(rawValue: id) else { return }
                style.save(for: bot.id)
            }
            notice = nil
            savedName = name
        } catch AgentVoiceSelection.SaveFailure.unknownBot {
            notice = "Agenten findes ikke længere i landsbyen."
        } catch { notice = "Valget kunne ikke gemmes. Prøv igen." }
    }

    private func stop() {
        previewID = nil
        speech.stop()
        pcSpeech.stop()
    }
}
