// Bot profile, local voice previews and a private chat entry point.

import Foundation
import SwiftUI

struct VillageBotProfile: View {
    let botID: UUID
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    @Environment(\.fadedPalette) private var palette
    private var savedBots: Data { MigratedAppData.shared.villageBots }
    @AppStorage(AppStorageKeys.phoneModel) private var phoneModel = "apple"
    @State private var editingBot: VillageBot?
    @State private var showPrivateChat = false
    @State private var showModels = false
    @State private var fullPrompt = false
    @State private var deletedBot: VillageBot?
    @State private var deletedIndex = 0
    @State private var testQuestion = ""
    @State private var testReply = ""
    @State private var testMemory: TeamBotNotebookStore.Memory?
    @State private var testMemoryTitle: String?
    @State private var testTask: Task<Void, Never>?
    @State private var notice: String?
    @StateObject private var speechBox = SpeechBox()

    private var bots: [VillageBot] { VillageBot.list(from: savedBots) }

    private var modelID: String { PhoneModels.effectiveModelID(phoneModel) }
    private var canTest: Bool {
        modelID == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(modelID) != nil
    }

    var body: some View {
        let localBots = bots
        ScrollView {
            VStack(spacing: 16) {
                if let bot = localBots.first(where: { $0.id == botID }) {
                    hero(bot)
                    voiceCard(bot)
                    personalityCard(bot)
                    testCard(bot)
                    NavigationLink { TeamBotNotebook(botID: bot.id) } label: {
                        FadedCard(accent: palette.purple) {
                            Label("Hukommelse, skills og vejledninger", systemImage: "books.vertical")
                                .font(FadedTypography.action)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                    profileActions(bot, canDuplicate: localBots.count < 10)
                } else if let deletedBot {
                    FadedCard(accent: palette.coral) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(deletedBot.name) er slettet.").font(FadedTypography.action)
                            FadedSecondaryButton("Fortryd", icon: "arrow.uturn.backward", action: restoreBot)
                        }
                    }
                } else {
                    FadedEmptyState(icon: "person.crop.circle.badge.questionmark", title: "Botprofilen findes ikke længere",
                                    detail: "Du kan vælge en anden bot under Mine bots.")
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(palette.coralText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("Botprofil")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { speechBox.stop(); testTask?.cancel() }
        .sheet(item: $editingBot) { selection in
            VillageBotBuilder(api: api, bot: selection, onBack: { editingBot = nil })
        }
        .sheet(isPresented: $showModels) { PhoneModelsView() }
        .sheet(isPresented: $showPrivateChat) {
            OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                          initialPage: .chat, initialBotID: botID)
        }
        .task(id: deletedBot?.id) {
            guard let id = deletedBot?.id else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if deletedBot?.id == id { deletedBot = nil }
        }
    }

    private func hero(_ bot: VillageBot) -> some View {
        VStack(spacing: 10) {
            VillageBotAvatar(bot: bot, size: 120, radius: 28)
            Text(bot.name).font(.largeTitle.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
            Text(bot.specialtyTitle).font(FadedTypography.action).foregroundStyle(palette.secondary)
            Text(bot.personality ?? "Nysgerrig")
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? palette.purple : palette.text)
                .padding(.horizontal, 12).padding(.vertical, 6).background(palette.raised, in: .capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func voiceCard(_ bot: VillageBot) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Stemme")
                Text(bot.voiceDetails).font(.subheadline).foregroundStyle(palette.secondary)
                let playing = speechBox.playback == .preview
                FadedSecondaryButton(playing ? "Stop stemmeprøve" : "Prøv stemme", icon: playing ? "stop.circle" : "play.circle") {
                    if playing { speechBox.stop() }
                    else { speechBox.play(bot.utterance(bot.previewSentence), as: .preview) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func personalityCard(_ bot: VillageBot) -> some View {
        FadedCard(accent: palette.purple) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Personlighed")
                if let responsibility = bot.responsibility, !responsibility.isEmpty {
                    Text(responsibility).font(.subheadline).foregroundStyle(palette.secondary)
                }
                if bot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Du kan tilføje en systemprompt under Redigér.").font(.subheadline).foregroundStyle(palette.secondary)
                } else {
                    Text(bot.prompt).font(.body).lineLimit(fullPrompt ? nil : 5).textSelection(.enabled)
                    Button(fullPrompt ? "Vis mindre" : "Vis hele") { fullPrompt.toggle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.isDark ? palette.purple : palette.text).frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func testCard(_ bot: VillageBot) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Prøv personligheden")
                if canTest {
                    BotLocalMemoryPicker(botID: bot.id, selection: $testMemory).disabled(testTask != nil)
                    testComposer(bot)
                } else {
                    Text("Vælg en klar telefonmodel for at prøve botten.").font(.subheadline).foregroundStyle(palette.secondary)
                    FadedSecondaryButton("Lokale modeller", icon: "iphone") { showModels = true }
                }
                if !testReply.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Svar fra telefonen", systemImage: "iphone")
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.isDark ? palette.cyan : palette.text)
                        if let testMemoryTitle {
                            FadedDetailText("Valgt notat · \(testMemoryTitle)")
                        }
                        Text(testReply).textSelection(.enabled)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.raised, in: .rect(cornerRadius: 12))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func testComposer(_ bot: VillageBot) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Skriv til botten…", text: $testQuestion, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).padding(12).frame(minHeight: 48)
                .background(palette.raised, in: .rect(cornerRadius: 12))
                .disabled(testTask != nil)
            if let testTask {
                FadedSecondaryButton("Stop", icon: "stop.fill") { testTask.cancel() }
            } else {
                Button { startTest(bot) } label: { Image(systemName: "arrow.up").frame(minWidth: 24) }
                    .buttonStyle(FadedButtonStyle(kind: .primary))
                    .disabled(testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send testbesked")
            }
        }
    }

    private func profileActions(_ bot: VillageBot, canDuplicate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedSecondaryButton("Chat med botten", icon: "lock.shield") {
                speechBox.stop()
                showPrivateChat = true
            }
            FadedSecondaryButton("Redigér", icon: "pencil") {
                speechBox.stop()
                editingBot = bot
            }
            FadedSecondaryButton("Duplikér bot", icon: "plus.square.on.square", action: duplicateBot)
                .disabled(!canDuplicate)
            if !canDuplicate { FadedDetailText("Der er plads til op til 10 bots.") }
            FadedSecondaryButton("Slet bot", icon: "trash", role: .destructive, action: deleteBot)
        }.frame(maxWidth: .infinity, alignment: .leading).disabled(testTask != nil)
    }

    private func startTest(_ bot: VillageBot) {
        let question = testQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canTest, !question.isEmpty, testTask == nil else { return }
        let selectedModel = modelID
        let localPrompt = question + (testMemory?.localReplyContext ?? "")
        testMemoryTitle = testMemory?.title
        testMemory = nil
        testReply = ""
        notice = nil
        testTask = Task {
            defer { testTask = nil }
            do {
                try await PhoneModels.reply(modelID: selectedModel, prompt: localPrompt,
                                            instructions: OfflineStudio.companionInstructions(for: bot)) {
                    if !Task.isCancelled { testReply = $0 }
                }
            } catch is CancellationError {
                return
            } catch {
                AppDiagnostics.record(error)
                notice = "Telefonen kunne ikke svare. Tjek din lokale model, og prøv igen."
            }
        }
    }

    private func deleteBot() {
        guard let bots = try? VillageBot.listRecovering(from: savedBots),
              let index = bots.firstIndex(where: { $0.id == botID }),
              let remaining = try? JSONEncoder().encode(bots.filter { $0.id != botID }) else {
            notice = "Botprofilen kunne ikke slettes."
            return
        }
        do {
            try MigratedAppData.shared.saveVillageBots(remaining)
            speechBox.stop()
            deletedBot = bots[index]
            deletedIndex = index
            notice = nil
        } catch { AppDiagnostics.record(error); notice = "Botprofilen kunne ikke slettes." }
    }

    private func duplicateBot() {
        var updated = bots
        guard let original = updated.first(where: { $0.id == botID }), updated.count < 10 else {
            notice = "Botten kunne ikke duplikeres. Tjek, om der er plads på holdet."
            return
        }
        let baseName = "\(original.name) – kopi"
        var name = baseName
        var number = 2
        while updated.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(baseName) \(number)"
            number += 1
        }
        let copy = VillageBot(name: name, prompt: original.prompt, voice: original.voice,
                              personality: original.personality, notifications: false, voiceRate: original.voiceRate,
                              language: original.language, specialty: original.specialty, responsibility: original.responsibility,
                              traits: original.traits)
        updated.append(copy)
        do {
            try MigratedAppData.shared.saveVillageBots(JSONEncoder().encode(updated))
            speechBox.stop()
            notice = nil
            editingBot = copy
        } catch {
            AppDiagnostics.record(error)
            notice = "Kopien kunne ikke gemmes. Prøv igen."
        }
    }

    private func restoreBot() {
        guard let deletedBot, var bots = try? VillageBot.listRecovering(from: savedBots),
              !bots.contains(where: { $0.id == deletedBot.id }), bots.count < 10 else {
            notice = "Botten kunne ikke gendannes. Tjek, om der er plads på holdet."
            return
        }
        bots.insert(deletedBot, at: min(deletedIndex, bots.count))
        do {
            try MigratedAppData.shared.saveVillageBots(JSONEncoder().encode(bots))
            self.deletedBot = nil
            notice = nil
        } catch { AppDiagnostics.record(error); notice = "Botten kunne ikke gendannes." }
    }
}
