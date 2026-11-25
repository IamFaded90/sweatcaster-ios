import SwiftUI

@MainActor struct AgentPersonalityView: View {
    let bot: VillageBot
    @State private var settings = AgentPersonality.Settings()
    @State private var loaded = false
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        VillageBotAvatar(bot: bot, size: 68, radius: 20)
                        VStack(alignment: .leading, spacing: 6) { Text(bot.name).font(.title2.bold()); Text(bot.personality ?? bot.traits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }
                Section("Samtalens stil") {
                    Picker("Tone", selection: $settings.style) { ForEach(AgentPersonality.Style.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Dine ønsker til måden at tale på", text: $settings.detail, axis: .vertical).lineLimit(3...7)
                    Text("Eksempel: ‘Vær mere afslappet, stil færre spørgsmål, og sig din mening.’").font(.caption).foregroundStyle(.secondary)
                    Toggle("Vis en genvej til sidste samtaleemne", isOn: $settings.followUp)
                }
                Section("Hukommelse") {
                    Text("Relevante tidligere beskeder fra denne agent kan bruges, også når de ligger længere tilbage. Dine rettelser og gemte ønsker gælder fortsat.")
                    ForEach(AgentChatPreferences.entries(for: bot.id), id: \.self) { entry in Text(entry.value).font(.subheadline) }
                    Text("Skriv ‘husk at …’ eller ‘vis mine ønsker’ i chatten for at styre de gemte ønsker.").font(.caption).foregroundStyle(.secondary)
                }
                if let notice { Section { Text(notice) } }
            }.scrollContentBackground(.hidden).background { FadedBackground() }
                .navigationTitle(bot.name + "s personlighed")
                .toolbar { Button("Færdig") { dismiss() } }
                .onAppear { if !loaded { settings = AgentPersonality.load(bot.id); loaded = true } }
                .onChange(of: settings) { _, value in
                    guard loaded else { return }
                    do { try AgentPersonality.save(value, bot: bot.id); notice = nil } catch { notice = "Dine ønsker kunne ikke gemmes." }
                }
        }
    }
}

extension AgentPhoneChat {
    var personalityInstructions: String {
        AgentPersonality.instructions(name: bot.name, personality: bot.personality, traits: bot.traits,
            settings: AgentPersonality.load(bot.id))
    }
    @ViewBuilder var personalFollowUp: some View {
        if keepHistory, running == nil, cleanDraft.isEmpty, AgentPersonality.load(bot.id).followUp,
           let previous = turns.last(where: { $0.agentAction == nil && $0.imageName == nil && !$0.reply.isEmpty }) {
            Button { draft = "Lad os fortsætte med: " + String(previous.prompt.prefix(300)); composerFocused = true } label: {
                Label("Fortsæt: " + String(previous.prompt.prefix(65)), systemImage: "arrow.turn.down.right")
                    .font(.caption).lineLimit(2).frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.bordered)
        }
    }
}
