import Foundation
import AVFAudio
import SwiftUI

enum AgentVoiceSelection {
    static func identifier(for bot: VillageBot) -> String {
        let override = UserDefaults.standard.string(forKey: PhoneModels.agentVoiceKey(bot.id)) ?? ""
        return override.isEmpty ? bot.voice : override
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
    @Binding var selection: String
    @Binding var language: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var speech = SpeechBox()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var previewID: String?
    @State private var saveNotice: String?

    private var selectedID: String { selection.isEmpty ? inheritedVoice : selection }
    private var selectedVoice: AVSpeechSynthesisVoice? {
        AgentVoiceSelection.resolve(identifier: selectedID, language: language)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(name)s stemme") {
                    if let voice = selectedVoice {
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
                Section("Stemmer på din iPhone · \(voices.count)") {
                    ForEach(voices, id: \.identifier) { voice in
                        HStack(spacing: 8) {
                            Button {
                                choose(voice.identifier)
                            } label: {
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
                    if voices.isEmpty { Text("Der er ingen tilgængelige stemmer på dette sprog endnu.") }
                }
                Section("Flere stemmer") {
                    Text(LocalSpeechVoice.downloadHint)
                    Text("Apple styrer hentningen af telefonstemmer. Når du vender tilbage hertil, opdateres listen automatisk. Standard og Premium med samme navn er kvaliteter af samme stemme.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Din personlige Apple-stemme") {
                        Form { PersonalVoiceSettings() }.navigationTitle("Personlig stemme")
                    }
                    Button("Opdatér stemmelisten", systemImage: "arrow.clockwise") { refresh() }
                }
            }
            .navigationTitle("Vælg og hør stemme")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Færdig") { dismiss() } } }
            .onAppear { refresh() }
            .onChange(of: language) { _, _ in speech.stop(); refresh() }
            .onChange(of: phase) { _, value in
                if value == .active { refresh() } else { speech.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in refresh() }
            .onDisappear { speech.stop() }
        }
    }

    private func choose(_ identifier: String) {
        speech.stop()
        do {
            var bots = try VillageBot.listRecovering(from: MigratedAppData.shared.villageBots)
            guard let index = bots.firstIndex(where: { $0.id == botID }) else {
                saveNotice = "Agenten findes ikke længere. Åbn profilen igen."
                return
            }
            bots[index].voice = identifier
            try MigratedAppData.shared.saveVillageBots(JSONEncoder().encode(bots))
            selection = identifier
            saveNotice = nil
        } catch {
            saveNotice = "Stemmen kunne ikke gemmes. Dit tidligere valg er bevaret."
        }
    }

    private func refresh() {
        voices = LocalSpeechVoice.options(language: language, includePersonalVoices: true)
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        if previewID == voice.identifier, speech.playback != nil { speech.stop(); return }
        previewID = voice.identifier
        speech.play(LocalSpeechVoice.utterance(LocalSpeechVoice.previewSentence(language: voice.language),
                                               voice: voice, rate: rate), as: .preview)
    }
}

struct AgentVoiceProfileCard: View {
    let bot: VillageBot
    @AppStorage private var voice: String
    @State private var language = "da-DK"
    @State private var showPicker = false

    init(bot: VillageBot) {
        self.bot = bot
        _voice = AppStorage(wrappedValue: "", PhoneModels.agentVoiceKey(bot.id))
    }

    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Stemme")
                let selected = AgentVoiceSelection.resolve(identifier: voice.isEmpty ? bot.voice : voice,
                                                           language: bot.language ?? "da-DK")
                Text(selected.map(LocalSpeechVoice.label) ?? AgentVoiceSelection.unavailable).font(.subheadline)
                FadedSecondaryButton("Vælg og hør stemmer", icon: "person.wave.2") { showPicker = true }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showPicker) {
            AgentVoicePicker(botID: bot.id, name: bot.name, inheritedVoice: bot.voice, rate: bot.voiceRate ?? 1,
                             selection: $voice, language: $language)
        }
    }
}
