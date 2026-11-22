import AVFAudio
import SwiftUI

@MainActor struct VillageSpeakingRoom: View {
    let artwork: String
    let zone: VillageZoneID
    let residents: [VillageLifeBot]
    let animated: Bool
    @Environment(\.villagePlannerAPI) private var api
    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette
    @StateObject private var player = ChristelPlayer()
    @State private var selectedID: String?
    @State private var notice: String?

    private var activeID: String? { player.playing || player.loading ? selectedID : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VillageInteriorArtwork(name: artwork, label: zone.title, residents: residents, animateResidents: animated,
                                   speakingID: activeID, onHear: hear, onMoveSpeaker: { id, pan in
                if activeID == id { player.updatePan(pan) }
            })
            .frame(height: 230).frame(maxWidth: .infinity)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if let message = notice ?? player.notice {
                Text(message).font(.footnote).foregroundStyle(palette.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onDisappear { player.stop() }
        .onChange(of: phase) { _, next in if next != .active { player.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { event in
            if (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                player.stop()
            }
        }
        .onChange(of: residents.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { player.stop() }
        }
    }

    private func hear(_ bot: VillageLifeBot, pan: Float) {
        let stopping = activeID == bot.id
        player.stop()
        notice = nil
        guard !stopping else { return }
        let id = UUID(uuidString: bot.id)
        guard let profiles = try? MigratedAppData.shared.loadBots().get() else {
            notice = "Agentens stemmevalg kunne ikke læses. Prøv igen."
            return
        }
        let profile = profiles.first { $0.id == id }
            ?? (id == VillageBot.lumiID ? VillageBot.lumi() : nil)
        let identifier = profile.map { AgentVoiceSelection.identifier(for: $0) } ?? "da-DK"
        selectedID = bot.id
        if let local = DownloadedAgentVoice.selected(identifier) {
            player.playDownloaded(text: line(bot, language: "da-DK"), voice: local, agentID: id, rate: profile?.voiceRate ?? 1, pan: pan)
        } else if let voice = AgentPCVoice(rawValue: identifier), let id {
            guard let api else { notice = "Forbind PC’en for at høre agentens valgte stemme."; return }
            player.playAgentVoice(text: line(bot, language: voice.language), voice: voice, agentID: id, pc: api, pan: pan)
        } else {
            let language = identifier.hasPrefix("en-") ? identifier : "da-DK"
            guard let voice = AgentVoiceSelection.resolve(identifier: identifier, language: language) else {
                notice = AgentVoiceSelection.unavailable
                return
            }
            let utterance = LocalSpeechVoice.utterance(line(bot, language: voice.language), voice: voice, rate: profile?.voiceRate ?? 1)
            player.playRoomVoice(utterance, agentID: id, pan: pan)
        }
    }

    private func line(_ bot: VillageLifeBot, language: String) -> String {
        guard language.hasPrefix("en") else { return VillageCopy.speech(bot.speechHint) ?? bot.poseLabel }
        switch bot.activity {
        case .idle: return bot.pcJobQueued ? "I'm waiting for a task." : "I'm ready."
        case .walk: return "I'm on my way."
        case .work: return bot.localPractice ? "I'm practising." : "I'm working."
        case .talk: return "I'm having a chat."
        case .rest: return "I'm taking a break."
        case .sleep: return "I'm asleep."
        }
    }
}

@MainActor struct VillageRoomActivities: View {
    let residents: [VillageLifeBot]
    @Environment(\.villagePlannerAPI) private var api
    @Environment(\.scenePhase) private var phase
    @State private var items: [Item] = []
    @State private var profiles: [VillageBot] = []
    @State private var selected: VillageSurprise?
    @State private var creating: VillageBot?
    @State private var refresh = 0
    @State private var notice: String?

    private struct Item: Identifiable {
        let owner: String
        let job: VillageSurprise
        var id: UUID { job.id }
    }

    private var owners: [VillageBot] {
        let ids = Set(residents.compactMap { UUID(uuidString: $0.id) })
        return profiles.filter { ids.contains($0.id) }
    }
    private var requestID: String { residents.map(\.id).sorted().joined(separator: ",") + String(refresh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !items.isEmpty {
                Text("Prøv det, vi har lavet").font(.headline)
                ForEach(items) { item in
                    Button { selected = item.job } label: {
                        FadedCard {
                            HStack(spacing: 12) {
                                Image(systemName: item.job.state == "ready" ? "sparkles" : "wrench.and.screwdriver")
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.job.title).font(.headline)
                                    Text(item.owner + " · " + item.job.stateTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            if let owner = owners.first, api != nil {
                FadedSecondaryButton("Bed " + owner.name + " skabe noget til rummet", icon: "sparkles") { creating = owner }
            }
            if api == nil && !residents.isEmpty {
                Text("Forbind din PC for at hente agenternes nye aktiviteter.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: requestID) { await load() }
        .onChange(of: phase) { _, phase in if phase == .active { refresh += 1 } }
        .sheet(item: $selected, onDismiss: { refresh += 1 }) { job in
            if let api { VillageSurpriseDetails(api: api, job: job) }
        }
        .sheet(item: $creating, onDismiss: { refresh += 1 }) { owner in
            VillageSurprisesView(api: api, bot: owner)
        }
    }

    private func load() async {
        profiles = (try? MigratedAppData.shared.loadBots().get()) ?? []
        guard let api else { items = []; return }
        var found: [Item] = []
        do {
            struct Library: Decodable { let items: [VillageSurprise] }
            for owner in owners {
                let result: Library = try await api.moduleJSON("village-surprises",
                    query: [.init(name: "bot_id", value: owner.id.uuidString)])
                try Task.checkCancellation()
                found.append(contentsOf: result.items.filter { ["ready", "kept"].contains($0.state) }.map {
                    Item(owner: owner.name, job: $0)
                })
            }
            items = found
            notice = nil
        } catch is CancellationError { return }
        catch {
            items = []
            notice = (error as? APIError)?.title ?? "Aktiviteterne kunne ikke hentes fra PC’en."
        }
    }
}
