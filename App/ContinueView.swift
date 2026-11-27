import CastBrowserFeature
import SwiftUI

@MainActor struct FadedContinueView: View {
    let api: LiveAPI?
    let open: (EveningPlan.Kind) -> Void
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var library = MusicLibrary.shared
    @State private var bots: [VillageBot] = []
    @State private var turns: [PrivateChatTurn] = []
    @State private var jobs: [UUID: [AgentWorkspace.Job]] = [:]
    @State private var projects: [FadedProject] = []
    @State private var pages: [CastLibraryBridge.Item] = []
    @State private var chat: VillageBot?
    @State private var workspace: VillageBot?
    @State private var pendingChat: VillageBot?
    @State private var attachment: AgentShareAttachment?
    @State private var project: FadedProject?
    @State private var notice: String?
    @State private var cast = CastLibraryBridge.nowPlaying
    @State private var mystery: VillageMystery?
    @State private var showMystery = false
    @State private var journeys: [UUID: AgentTaskJourney] = [:]
    @State private var journeyBot: VillageBot?
    @State private var creativeProjects: [CreativeProject] = []
    @State private var creative: CreativeProject?
    @State private var trackedCases: [UUID: [CaseTracker]] = [:]
    @State private var caseBot: VillageBot?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Tilbage til det, du var i gang med.").font(.title2.bold())
                    if let mystery, !mystery.finished {
                        row(mystery.title, detail: "Landsbyens mysterium · \(mystery.clues.count)/3 spor", icon: "moon.stars") { showMystery = true }
                    }
                    if let cast {
                        row(cast.title, detail: cast.route + " · \(Int(max(0, cast.position))) sek.", icon: "tv") {
                            CastLibraryBridge.showControls(); open(.film)
                        }
                    }
                    if let current = player.current {
                        row(current.title, detail: "Din aktuelle kø · \(Int(player.position)) sek.", icon: "music.note") {
                            player.resume(); open(.music)
                        }
                    }
                    if !pages.isEmpty {
                        Text("Film og serier").font(.headline)
                        ForEach(pages.prefix(6)) { page in
                            row(page.title, detail: "Åbn filmsiden · din gemte afspilning tilbydes i afspilleren", icon: "play.tv") {
                                CastLibraryBridge.open(page.page); open(.film)
                            }
                        }
                    }
                    if !bots.isEmpty {
                        Text("Samtaler og opgaver").font(.headline)
                        ForEach(bots) { bot in
                            AgentLocalContinuations(bot: bot)
                            ForEach((trackedCases[bot.id] ?? []).filter { $0.completedAt == nil }.prefix(4)) { record in
                                row(record.title, detail: bot.name + " · " + record.stateTitle, icon: "checkmark.bubble") { caseBot = bot }
                            }
                            if let journey = journeys[bot.id] {
                                row("Retursag · " + bot.name, detail: journey.subject.isEmpty ? journey.goal : journey.subject, icon: "shippingbox") { journeyBot = bot }
                            }
                            if let turn = turns.last(where: { $0.botID == bot.id }) {
                                row(bot.name, detail: String(turn.prompt.prefix(110)), icon: "bubble.left.and.bubble.right") { chat = bot }
                            }
                            ForEach((jobs[bot.id] ?? []).prefix(3)) { job in
                                row(job.prompt, detail: bot.name + " · " + job.state.title, icon: "tray") { workspace = bot }
                            }
                        }
                    }
                    if !projects.isEmpty {
                        Text("Dine projekter").font(.headline)
                        ForEach(projects.prefix(6)) { item in
                            row(item.title.isEmpty ? "Projekt uden navn" : item.title,
                                detail: item.updatedAt.formatted(date: .abbreviated, time: .shortened), icon: "doc.text") { project = item }
                        }
                    }
                    if !creativeProjects.isEmpty {
                        Text("Dit kreative hold").font(.headline)
                        ForEach(creativeProjects.prefix(6)) { item in
                            row(item.title.isEmpty ? item.kind.rawValue : item.title, detail: item.kind.rawValue, icon: "paintbrush.pointed") { creative = item }
                        }
                    }
                    if player.current == nil && !library.recent.isEmpty {
                        Text("Hør igen").font(.headline)
                        ForEach(library.recent.prefix(4)) { track in
                            row(track.title, detail: track.artist, icon: "music.note") { player.play(track); open(.music) }
                        }
                    }
                    if bots.isEmpty && turns.isEmpty && projects.isEmpty && pages.isEmpty && player.current == nil && library.recent.isEmpty {
                        ContentUnavailableView("Her venter dit næste kapitel", systemImage: "play.circle",
                            description: Text("Når du starter en samtale, et projekt eller noget underholdning, finder du det igen her."))
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FadedSpacing.edge)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { FadedBackground() }
                .navigationTitle("Fortsæt")
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { Button("Opdatér", systemImage: "arrow.clockwise") { refresh() } }
                .onAppear { refresh() }
                .onReceive(NotificationCenter.default.publisher(for: CastLibraryBridge.playbackChanged)) { _ in cast = CastLibraryBridge.nowPlaying }
                .sheet(item: $chat, onDismiss: { attachment = nil; refresh() }) { AgentPhoneChat(bot: $0, api: api, sharedAttachment: attachment) }
                .sheet(item: $workspace, onDismiss: {
                    refresh(); if let pendingChat { chat = pendingChat; self.pendingChat = nil }
                }) { bot in
                    AgentWorkspaceView(bot: bot, api: api,
                        model: PhoneModels.readyTextModel(for: bot.id), useFile: { document in
                            attachment = .init(document: document, onUse: { attachment = nil })
                            pendingChat = bot; workspace = nil
                        })
                }
                .sheet(item: $project, onDismiss: refresh) { FadedProjectsView(initialProjectID: $0.id) }
                .sheet(isPresented: $showMystery, onDismiss: refresh) { VillageMysteryView() }
                .sheet(item: $journeyBot, onDismiss: refresh) { bot in
                    AgentTaskJourneyView(bot: bot, model: UserDefaults.standard.string(forKey: PhoneModels.agentModelKey(bot.id)) ?? "apple", api: api) { receipt, _ in
                        do {
                            guard let journey = try AgentTaskJourney.Store(botID: bot.id).load(), journey.readyForChat else { return }
                            var turn = PrivateChatTurn(prompt: journey.goal, reply: receipt, source: "iPhone", botID: bot.id)
                            turn.id = journey.id; turn.agentAction = .init(kind: .workflow("Retur og opfølgning"), receipt: receipt)
                            try MigratedAppData.shared.saveRegularStudioTurns(MigratedAppData.shared.regularStudioTurns().filter { $0.id != turn.id } + [turn])
                        } catch { notice = "Resultatet kunne ikke gemmes i chatten. Sagen er stadig gemt." }
                    }
                }
                .sheet(item: $creative, onDismiss: refresh) { item in
                    let bot = bots.first { $0.id == item.botID } ?? VillageBot(id: item.botID, name: "Tidligere agent")
                    CreativeProjectView(bot: bot, model: UserDefaults.standard.string(forKey: PhoneModels.agentModelKey(bot.id)) ?? "apple", initial: item)
                }
                .sheet(item: $caseBot, onDismiss: refresh) { bot in
                    CaseTrackerView(bot: bot, api: api, model: UserDefaults.standard.string(forKey: PhoneModels.agentModelKey(bot.id)) ?? "apple")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { FadedBackground() }
    }
    private func row(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FadedCard {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.title2).foregroundStyle(FadedBrand.gradient).frame(width: 38)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
        }.buttonStyle(.plain)
    }
    private func refresh() {
        bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
        turns = MigratedAppData.shared.regularStudioTurns().filter { $0.botID != VillageBot.lumiID }
        pages = CastLibraryBridge.items().filter { !$0.isSource }
        jobs = [:]; journeys = [:]; trackedCases = [:]; notice = nil
        do { mystery = try VillageMystery.Store().load() } catch { notice = "Det gemte mysterium kunne ikke læses." }
        for bot in bots {
            do { trackedCases[bot.id] = try CaseTracker.Store(botID: bot.id).list() }
            catch { notice = "En sagsoversigt kunne ikke læses. Den er ikke ændret." }
            do { journeys[bot.id] = try AgentTaskJourney.Store(botID: bot.id).load() }
            catch { notice = "En retursag kunne ikke læses. Den er ikke ændret." }
            do { jobs[bot.id] = Array(try AgentWorkspace(botID: bot.id).load().jobs.filter { $0.state != .completed && $0.state != .cancelled }.reversed()) }
            catch { notice = "Nogle agentopgaver kunne ikke læses. De er ikke ændret." }
        }
        do { projects = try FadedProjectStore.load().sorted { $0.updatedAt > $1.updatedAt } }
        catch { notice = "Projekterne kunne ikke læses. De er ikke ændret." }
        do { creativeProjects = try CreativeProject.Store().list().filter { $0.botID != VillageBot.lumiID } }
        catch { notice = "De kreative forløb kunne ikke læses." }
    }
}
