import SwiftUI

@MainActor struct VillageMysteryView: View {
    @State private var session: VillageMystery?
    @State private var bots: [VillageBot] = []
    @State private var notice: String?
    @State private var pendingAccusation: Int?
    @State private var replacing = false
    @StateObject private var speech = ChristelPlayer()
    @Environment(\.dismiss) private var dismiss
    let storage = VillageMystery.Store()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let session {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("En krimi i din landsby", systemImage: "moon.stars").font(.caption).foregroundStyle(.secondary)
                                Text(session.title).font(.largeTitle.bold())
                                Text(session.introduction)
                                ProgressView("Spor \(session.clues.count)/3 · Alibier \(session.questioned.count)/3", value: Double(session.clues.count + session.questioned.count), total: 6)
                            }
                        }
                        Text("Undersøg rummene").font(.title3.bold())
                        ForEach(0..<3) { index in
                            FadedCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        change { $0.visit(index) }
                                    } label: {
                                        Label(session.locations[index], systemImage: session.clues.contains(index) ? "checkmark.magnifyingglass" : "magnifyingglass")
                                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    }.disabled(session.finished)
                                    if session.clues.contains(index) { Text(session.clue(index)).textSelection(.enabled) }
                                }
                            }
                        }
                        Text("Tal med beboerne").font(.title3.bold())
                        ForEach(Array(session.roles.enumerated()), id: \.element.id) { index, role in
                            FadedCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        if let bot = bots.first(where: { $0.id == role.botID }) { VillageBotAvatar(bot: bot, size: 58, radius: 16) }
                                        Text(role.name).font(.headline); Spacer()
                                        if session.questioned.contains(index) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint) }
                                    }
                                    Button("Spørg om alibiet", systemImage: "bubble.left") { change { $0.question(index) } }.frame(minHeight: 44).disabled(session.finished)
                                    if session.questioned.contains(index) {
                                        Text(session.dialogue(index))
                                        Button("Hør svaret", systemImage: "speaker.wave.2") { read(index) }.frame(minHeight: 44)
                                    }
                                    if session.canAccuse { Button("Anklag " + role.name, systemImage: "hand.raised") { pendingAccusation = index }.frame(minHeight: 44) }
                                }
                            }
                        }
                        if let verdict = session.verdict {
                            FadedCard { VStack(alignment: .leading, spacing: 12) { Text("Sagen er afsluttet").font(.title2.bold()); Text(verdict); Button("Spil en ny sag") { replacing = true }.frame(minHeight: 44) } }
                        } else { Text("Find alle tre spor og hør alle tre alibier, før du vælger din anklage.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        ContentUnavailableView("En nat fuld af hemmeligheder", systemImage: "moon.stars", description: Text("Dine agenter spiller roller. Du finder sporene. Historien kan spilles og gemmes helt uden PC eller internet."))
                        FadedPrimaryButton("Start mysteriet", icon: "play") { start() }
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Landsbyens mysterier")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Menu("Spilvalg", systemImage: "ellipsis") {
                        Button("Ny sag") { replacing = true }
                        Button("Slet gemt spil", role: .destructive) {
                            do { try storage.remove(); session = nil; speech.stop() } catch { notice = "Spillet kunne ikke slettes." }
                        }
                    } }
                }
                .onAppear {
                    bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                    do { session = try storage.load() } catch { notice = "Det gemte spil kunne ikke læses. Du kan slette det eller prøve igen." }
                }
                .onDisappear { speech.stop() }
                .confirmationDialog("Afslut den nuværende sag og start en ny?", isPresented: $replacing, titleVisibility: .visible) {
                    Button("Start ny sag") { start() }
                    Button("Behold sagen", role: .cancel) {}
                }
                .confirmationDialog("Vil du fremsætte denne anklage?", isPresented: Binding(get: { pendingAccusation != nil }, set: { if !$0 { pendingAccusation = nil } }), titleVisibility: .visible) {
                    if let index = pendingAccusation {
                        Button("Fremsæt anklagen") { change { _ = $0.accuse(index) }; pendingAccusation = nil }
                        Button("Undersøg videre", role: .cancel) { pendingAccusation = nil }
                    }
                }
        }
    }
    private func start() {
        let roles = bots.prefix(3).map { VillageMystery.Role(id: $0.id, name: $0.name, botID: $0.id) }
        let next = VillageMystery.start(roles: roles)
        do { try storage.save(next); session = next; notice = nil; speech.stop() } catch { notice = "Sagen kunne ikke gemmes. Prøv igen." }
    }
    private func change(_ action: (inout VillageMystery) -> Void) {
        guard var next = session else { return }
        action(&next)
        do { try storage.save(next); session = next; notice = nil } catch { notice = "Dit træk kunne ikke gemmes. Prøv igen." }
    }
    private func read(_ index: Int) {
        guard let session, session.roles.indices.contains(index) else { return }
        let role = session.roles[index]
        let identifier = role.botID.flatMap { UserDefaults.standard.string(forKey: PhoneModels.agentVoiceKey($0)) }
            ?? bots.first(where: { $0.id == role.botID })?.voice ?? DownloadedAgentVoice.all[index].id
        guard let voice = DownloadedAgentVoice.selected(identifier), AgentVoiceDownload.available(voice) else {
            notice = "Vælg en hentet telefonstemme til \(role.name) på agentens profil for at høre rollen uden PC."; return
        }
        MusicPlayer.shared.pause(); speech.playDownloaded(text: session.dialogue(index), voice: voice, agentID: role.botID, language: "da-DK", rate: 1)
    }
}

struct AgentMysteryShortcut: View {
    var body: some View { NavigationLink { VillageMysteryView() } label: { Label("Spil et mysterium i landsbyen", systemImage: "moon.stars").frame(minHeight: 48) } }
}
