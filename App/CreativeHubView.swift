import SwiftUI

@MainActor struct CreativeHubView: View {
    @State private var bots: [VillageBot] = []
    @State private var projects: [CreativeProject] = []
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Start med en agent") {
                    ForEach(bots) { bot in
                        NavigationLink { CreativeProjectView(bot: bot, model: model(bot.id)) } label: {
                            HStack(spacing: 12) { VillageBotAvatar(bot: bot, size: 46, radius: 14); Text(bot.name).font(.headline) }.frame(minHeight: 52)
                        }
                    }
                    if bots.isEmpty { Text("Opret en agent under Agenter først, så kan I skabe noget sammen her.").foregroundStyle(.secondary) }
                }
                Section("Dine kreative forløb") {
                    ForEach(projects) { project in
                        NavigationLink { CreativeProjectView(bot: owner(project), model: model(project.botID), initial: project) } label: {
                            VStack(alignment: .leading) { Text(project.title.isEmpty ? project.kind.rawValue : project.title); Text(project.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }.frame(minHeight: 48)
                        }
                    }
                }
                if let notice { Text(notice) }
            }.scrollContentBackground(.hidden).background { FadedBackground() }.navigationTitle("Skab noget sammen")
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear {
                    bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                    do { projects = try CreativeProject.Store().list().filter { $0.botID != VillageBot.lumiID } }
                    catch { notice = "Nogle forløb kunne ikke læses. De er ikke ændret." }
                }
        }
    }
    private func model(_ id: UUID) -> String { UserDefaults.standard.string(forKey: PhoneModels.agentModelKey(id)) ?? "apple" }
    private func owner(_ project: CreativeProject) -> VillageBot {
        bots.first { $0.id == project.botID } ?? VillageBot(id: project.botID, name: "Tidligere agent")
    }
}
