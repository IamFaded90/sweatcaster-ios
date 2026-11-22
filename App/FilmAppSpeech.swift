import Combine
import SwiftUI

@MainActor final class FilmAppSpeech: ObservableObject {
    @Published var notice: String?
    private let pc = ChristelPlayer()
    private let phone = SpeechBox()
    private var updates = Set<AnyCancellable>()

    init() {
        pc.$notice.compactMap { $0 }.sink { [weak self] reason in
            Task { @MainActor in self?.notice = reason }
        }.store(in: &updates)
    }

    func speak(_ text: String, language: String, api: LiveAPI?) {
        pc.stop()
        phone.stop()
        notice = nil
        guard !text.isEmpty else { return }
        let profiles = (try? MigratedAppData.shared.loadBots().get()) ?? []
        let bot = profiles.first(where: {
            ($0.specialty ?? "").localizedCaseInsensitiveContains("underholdning")
        }) ?? profiles.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? VillageBot.founderAdam()
        let identifier = AgentVoiceSelection.identifier(for: bot)
        if let local = DownloadedAgentVoice.selected(identifier) {
            pc.playDownloaded(text: text, voice: local, agentID: bot.id, language: language, rate: bot.voiceRate ?? 1)
        } else if let voice = AgentPCVoice(rawValue: identifier) {
            guard let api else { notice = "Forbind PC’en for at høre agentens valgte stemme."; return }
            let spoken = text.count > 450 ? String(text.prefix(450)) + " Resten står på skærmen." : text
            pc.playAgentVoice(text: spoken, voice: voice, agentID: bot.id, pc: api)
        } else if let voice = AgentVoiceSelection.resolve(identifier: identifier, language: language) {
            phone.play(LocalSpeechVoice.utterance(text, voice: voice, rate: bot.voiceRate ?? 1),
                       as: .preview, agentID: bot.id)
        } else { notice = "Vælg en tilgængelig stemme til agenten for at høre svaret." }
    }
}
