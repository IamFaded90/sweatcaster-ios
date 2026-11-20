import Foundation
import AVFAudio
import SwiftUI

enum AgentPCVoice: String, Codable, CaseIterable, Identifiable {
    case danish = "piper-da"
    case roestMic = "roest-mic"
    case roestNic = "roest-nic"
    case roestLumi = "roest-lumi"
    case heart = "kokoro-heart"
    case michael = "kokoro-michael"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .danish: "Talesyntese"
        case .roestMic: "Mic"
        case .roestNic: "Nic"
        case .roestLumi: "Lumi"
        case .heart: "Heart"
        case .michael: "Michael"
        }
    }
    var language: String { [.danish, .roestMic, .roestNic, .roestLumi].contains(self) ? "da-DK" : "en-US" }
    var label: String { name + " · " + (language == "da-DK" ? "Dansk PC-stemme" : "Engelsk PC-stemme") }
}

extension LiveAPI {
    func agentPCVoices(for botID: UUID? = nil) async throws -> [AgentPCVoice] {
        struct Catalog: Decodable { let voices: [String] }
        let catalog: Catalog = try await moduleJSON("agent-local-voices", timeout: 8)
        return catalog.voices.compactMap(AgentPCVoice.init(rawValue:))
            .filter { $0 != .roestLumi || botID == VillageBot.lumiID }
    }

    func agentPCVoiceAudio(_ text: String, voice: AgentPCVoice) async throws -> Data {
        struct Speech: Decodable { let audio: Data }
        let body = try JSONEncoder().encode(["text": text, "voice": voice.rawValue])
        let result: Speech = try await moduleJSON("agent-local-voices", upload: body, timeout: 190, maximumBytes: 6_000_000)
        guard !result.audio.isEmpty else { throw APIError.malformed }
        return result.audio
    }
}

enum AgentVoiceSelection {
    enum SaveFailure: Error { case unknownBot, voiceUnavailableForBot }

    @MainActor static func save(_ identifier: String, for botID: UUID, store: MigratedAppData,
                                defaults: UserDefaults = .standard) throws {
        guard identifier != AgentPCVoice.roestLumi.rawValue || botID == VillageBot.lumiID else {
            throw SaveFailure.voiceUnavailableForBot
        }
        let data = store.villageBots
        var bots = data.isEmpty && botID == VillageBot.lumiID ? [] : try JSONDecoder().decode([VillageBot].self, from: data)
        if let index = bots.firstIndex(where: { $0.id == botID }) {
            bots[index].voice = identifier
            try store.saveVillageBots(JSONEncoder().encode(bots))
        } else if botID != VillageBot.lumiID {
            throw SaveFailure.unknownBot
        }
        // Lumi's private chat can also open without a saved village profile.
        defaults.set(identifier, forKey: PhoneModels.agentVoiceKey(botID))
    }

    static func identifier(for bot: VillageBot) -> String {
        let override = UserDefaults.standard.string(forKey: PhoneModels.agentVoiceKey(bot.id)) ?? ""
        return override.isEmpty ? bot.voice : override
    }

    static func lumiIdentifier(profile: String, override: String, pcVoiceAvailable: Bool) -> String {
        if !override.isEmpty { return override }
        if pcVoiceAvailable && profile == "da-DK" { return AgentPCVoice.roestLumi.rawValue }
        return profile
    }

    @MainActor static func adoptApprovedLumiVoiceIfAvailable(_ voices: [AgentPCVoice],
                                                            defaults: UserDefaults = .standard) {
        let appliedKey = "fadedai.lumi.approvedReferenceVoice.v1"
        guard voices.contains(.roestLumi), !defaults.bool(forKey: appliedKey) else { return }
        defaults.set(AgentPCVoice.roestLumi.rawValue, forKey: PhoneModels.agentVoiceKey(VillageBot.lumiID))
        defaults.set(true, forKey: appliedKey)
    }

    /// Explicit voices keep their identity; a missing voice never silently becomes another one.
    static func resolve(identifier: String, language: String) -> AVSpeechSynthesisVoice? {
        if identifier.isEmpty || ["auto", "da-DK", "en-US", "en-GB"].contains(identifier) {
            return LocalSpeechVoice.preferred(language: language == "auto" ? "da-DK" : language)
        }
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier),
              !voice.voiceTraits.contains(.isPersonalVoice) ||
                AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized else { return nil }
        return voice
    }

    static let unavailable = "Den valgte stemme er ikke tilgængelig på denne iPhone. Vælg en anden stemme eller hent den igen."
}

struct AgentVoicePicker: View {
    let botID: UUID
    let name: String
    let inheritedVoice: String
    let rate: Double
    let api: LiveAPI?
    @Binding var selection: String
    @Binding var language: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var speech = SpeechBox()
    @StateObject private var pcSpeech = ChristelPlayer()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var pcVoices: [AgentPCVoice] = []
    @State private var pcVoiceConnectionFailed = false
    @State private var refreshPC = 0
    @State private var englishPage = 0
    @State private var previewID: String?
    @State private var saveNotice: String?

    private var selectedID: String {
        if botID == VillageBot.lumiID {
            return AgentVoiceSelection.lumiIdentifier(profile: inheritedVoice, override: selection,
                                                      pcVoiceAvailable: pcVoices.contains(.roestLumi))
        }
        return selection.isEmpty ? inheritedVoice : selection
    }
    private var selectedPCVoice: AgentPCVoice? { AgentPCVoice(rawValue: selectedID) }
    private var selectedVoice: AVSpeechSynthesisVoice? {
        AgentVoiceSelection.resolve(identifier: selectedID, language: language)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(name)s stemme") {
                    if let selectedPCVoice {
                        Label(selectedPCVoice.label, systemImage: "desktopcomputer")
                        if !pcVoices.contains(selectedPCVoice) {
                            Text("Den valgte PC-stemme er ikke tilgængelig lige nu.").font(.footnote)
                        }
                    } else if let voice = selectedVoice {
                        Label(LocalSpeechVoice.label(voice), systemImage: "person.wave.2")
                    } else {
                        Text(AgentVoiceSelection.unavailable)
                    }
                    Text("Dit valg gemmes for denne agent. En valgt stemme bliver ikke skiftet ud, når svaret skifter sprog.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Vælg automatisk til sproget") { choose(language) }
                    if let saveNotice { Text(saveNotice).foregroundStyle(.red) }
                    Picker("Vis stemmer på", selection: $language) {
                        Text("Dansk").tag("da-DK")
                        Text("Engelsk").tag("en-US")
                    }
                }
                if language == "en-US" {
                    englishVoiceSection
                } else {
                    pcVoiceSection
                    Section("Apple-stemmer på din iPhone · \(voices.count)") {
                        ForEach(voices, id: \.identifier) { voice in
                            appleVoiceRow(voice)
                        }
                        if voices.isEmpty { Text("Der er ingen tilgængelige stemmer på dette sprog endnu.") }
                    }
                }
                Section("Flere stemmer") {
                    Text(LocalSpeechVoice.downloadHint)
                    Text("Apple styrer hentningen af telefonstemmer. Når du vender tilbage hertil, opdateres listen automatisk. Standard og Premium med samme navn er kvaliteter af samme stemme.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Din personlige Apple-stemme") {
                        Form { PersonalVoiceSettings() }.navigationTitle("Personlig stemme")
                    }
                    Button("Opdatér stemmelisten", systemImage: "arrow.clockwise") { refresh(); refreshPC += 1 }
                }
            }
            .navigationTitle("Vælg og hør stemme")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Færdig") { dismiss() } } }
            .onAppear { refresh() }
            .task(id: "\(api?.queueTargetID ?? ""):\(phase == .active):\(refreshPC)") {
                guard phase == .active else { return }
                guard let api else {
                    pcVoices = []
                    pcVoiceConnectionFailed = false
                    return
                }
                do {
                    let result = try await api.agentPCVoices(for: botID)
                    if !Task.isCancelled {
                        pcVoices = result
                        pcVoiceConnectionFailed = false
                        if botID == VillageBot.lumiID {
                            AgentVoiceSelection.adoptApprovedLumiVoiceIfAvailable(result)
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        pcVoices = []
                        pcVoiceConnectionFailed = true
                    }
                }
            }
            .onChange(of: language) { _, _ in englishPage = 0; stopPreview(); refresh() }
            .onChange(of: phase) { _, value in
                if value == .active { refresh() } else { stopPreview() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in refresh() }
            .onDisappear { stopPreview() }
        }
    }

    private enum EnglishVoice: Identifiable {
        case phone(AVSpeechSynthesisVoice), pc(AgentPCVoice)
        var id: String {
            switch self {
            case .phone(let voice): voice.identifier
            case .pc(let voice): voice.id
            }
        }
    }

    private var englishChoices: [EnglishVoice] {
        // Show people, not separate entries for each quality of the same Apple voice.
        var names = Set<String>()
        let distinct = voices.filter { names.insert($0.name.lowercased()).inserted }
        var choices = pcVoices.filter { $0.language == "en-US" }.map(EnglishVoice.pc) + distinct.map(EnglishVoice.phone)
        if let selected = voices.first(where: { $0.identifier == selectedID }),
           !choices.prefix(14).contains(where: { $0.id == selectedID }) {
            choices.removeAll { $0.id == selectedID }
            choices.insert(.phone(selected), at: 0)
        }
        return Array(choices.prefix(14))
    }

    private var englishVoiceSection: some View {
        let choices = englishChoices
        let pageCount = choices.count > 7 ? 2 : 1
        let page = min(englishPage, pageCount - 1)
        return Section("Engelske stemmer · \(choices.count)") {
            VStack(spacing: 4) {
                ForEach(Array(choices.dropFirst(page * 7).prefix(7))) { choice in
                    switch choice {
                    case .phone(let voice): appleVoiceRow(voice)
                    case .pc(let voice): pcVoiceRow(voice)
                    }
                }
                if choices.isEmpty { Text("Ingen engelske stemmer er tilgængelige lige nu.") }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 36).onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height), pageCount > 1 else { return }
                setEnglishPage(drag.translation.width < 0 ? 1 : 0)
            })
            if pageCount > 1 {
                HStack {
                    Button("Forrige", systemImage: "chevron.left") { setEnglishPage(0) }.disabled(page == 0)
                    Spacer()
                    Text("Side \(page + 1) af \(pageCount)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Næste", systemImage: "chevron.right") { setEnglishPage(1) }.disabled(page == 1)
                }.buttonStyle(.borderless).frame(minHeight: 44)
            }
            if pcVoices.contains(where: { $0.language == "en-US" }) {
                Text("En PC-stemme læser svar op lokalt på din parrede PC.").font(.footnote).foregroundStyle(.secondary)
            }
            if let notice = pcSpeech.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func setEnglishPage(_ page: Int) {
        guard englishPage != page else { return }
        stopPreview()
        englishPage = page
    }

    private func appleVoiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        HStack(spacing: 8) {
            Button { choose(voice.identifier) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name).font(.headline)
                        Text(LocalSpeechVoice.qualityLabel(voice) + " · " + voice.language)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedVoice?.identifier == voice.identifier { Image(systemName: "checkmark.circle.fill") }
                }
                .frame(minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Vælg " + LocalSpeechVoice.label(voice))
            .accessibilityAddTraits(selectedVoice?.identifier == voice.identifier ? .isSelected : [])
            Button { preview(voice) } label: {
                Image(systemName: previewID == voice.identifier && speech.playback != nil ? "stop.circle" : "play.circle")
                    .font(.title2).frame(width: 48, height: 48)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hør " + LocalSpeechVoice.label(voice))
        }
    }

    private var pcVoiceSection: some View {
        Section("Stemmer på din PC") {
            let choices = pcVoices.filter { $0.language == language }
            if choices.isEmpty {
                Text(api == nil ? "Forbind din PC for at vælge dens stemmer."
                     : pcVoiceConnectionFailed ? "Kunne ikke hente stemmer fra PC’en. Tjek forbindelsen og tryk Opdatér stemmelisten."
                     : "PC’en har ingen klar stemme på dette sprog. Den danske stemme kræver en installeret stemmeafspiller og stemmepakke på PC’en.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(choices) { voice in
                pcVoiceRow(voice)
            }
            if let notice = pcSpeech.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if !choices.isEmpty {
                Text("Ved oplæsning sendes svaret til din parrede PC. Stemmerne kører lokalt dér.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func pcVoiceRow(_ voice: AgentPCVoice) -> some View {
        HStack(spacing: 8) {
            Button { choose(voice.id) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voice.name).font(.headline)
                        Text("PC-stemme").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedID == voice.id { Image(systemName: "checkmark.circle.fill") }
                }
                .frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Vælg " + voice.label)
                .accessibilityAddTraits(selectedID == voice.id ? .isSelected : [])
            Button { previewPC(voice) } label: {
                Image(systemName: previewID == voice.id && (pcSpeech.loading || pcSpeech.playing) ? "stop.circle" : "play.circle")
                    .font(.title2).frame(width: 48, height: 48)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hør " + voice.label)
        }
    }

    private func choose(_ identifier: String) {
        stopPreview()
        do {
            try AgentVoiceSelection.save(identifier, for: botID, store: .shared)
            selection = identifier
            saveNotice = nil
        } catch AgentVoiceSelection.SaveFailure.unknownBot {
            saveNotice = "Agenten findes ikke længere. Åbn profilen igen."
        } catch {
            saveNotice = "Stemmen kunne ikke gemmes. Dit tidligere valg er bevaret."
        }
    }

    private func refresh() {
        voices = LocalSpeechVoice.options(language: language, includePersonalVoices: true)
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        if previewID == voice.identifier, speech.playback != nil { speech.stop(); return }
        stopPreview()
        previewID = voice.identifier
        speech.play(LocalSpeechVoice.utterance(LocalSpeechVoice.previewSentence(language: voice.language),
                                               voice: voice, rate: rate), as: .preview)
    }

    private func previewPC(_ voice: AgentPCVoice) {
        guard let api else { return }
        if previewID == voice.id, pcSpeech.playing || pcSpeech.loading { stopPreview(); return }
        stopPreview()
        previewID = voice.id
        pcSpeech.playAgentVoice(text: LocalSpeechVoice.previewSentence(language: voice.language),
                               voice: voice, agentID: botID, pc: api)
    }

    private func stopPreview() {
        speech.stop()
        pcSpeech.stop()
    }
}

struct AgentVoiceProfileCard: View {
    let bot: VillageBot
    let api: LiveAPI?
    @AppStorage private var voice: String
    @Environment(\.scenePhase) private var phase
    @State private var language = "da-DK"
    @State private var showPicker = false
    @State private var showTasteTest = false
    @State private var lumiPCVoiceAvailable = false

    init(bot: VillageBot, api: LiveAPI?) {
        self.bot = bot
        self.api = api
        _voice = AppStorage(wrappedValue: "", PhoneModels.agentVoiceKey(bot.id))
    }

    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Stemme")
                let identifier = bot.id == VillageBot.lumiID
                    ? AgentVoiceSelection.lumiIdentifier(profile: bot.voice, override: voice, pcVoiceAvailable: lumiPCVoiceAvailable)
                    : voice.isEmpty ? bot.voice : voice
                let selected = AgentVoiceSelection.resolve(identifier: identifier, language: bot.language ?? "da-DK")
                Text(AgentPCVoice(rawValue: identifier)?.label
                     ?? selected.map(LocalSpeechVoice.label) ?? AgentVoiceSelection.unavailable).font(.subheadline)
                FadedSecondaryButton("Vælg og hør stemmer", icon: "person.wave.2") { showPicker = true }
                FadedSecondaryButton("Sammenlign to danske stemmer", icon: "headphones") { showTasteTest = true }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(api?.queueTargetID ?? ""):\(phase == .active)") {
            guard bot.id == VillageBot.lumiID, phase == .active else { return }
            let voices = try? await api?.agentPCVoices(for: bot.id)
            if !Task.isCancelled {
                lumiPCVoiceAvailable = voices?.contains(.roestLumi) == true
                AgentVoiceSelection.adoptApprovedLumiVoiceIfAvailable(voices ?? [])
            }
        }
        .sheet(isPresented: $showPicker) {
            AgentVoicePicker(botID: bot.id, name: bot.name, inheritedVoice: bot.voice, rate: bot.voiceRate ?? 1,
                             api: api, selection: $voice, language: $language)
        }
        .sheet(isPresented: $showTasteTest) { AgentTasteTest(bot: bot, api: api, kind: .voice) }
    }
}
