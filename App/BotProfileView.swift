// Bot profile, local voice previews and a private chat entry point.

import Foundation
import AVKit
import SwiftUI

struct VillageBotProfile: View {
    let botID: UUID
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    var onFileShared: (UUID, UUID, UUID) -> Void = { _, _, _ in }
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
                    computerLink(bot, roster: localBots)
                    voiceCard(bot)
                    personalityCard(bot)
                    if bot.id != VillageBot.lumiID { testCard(bot) }
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
            if botID == VillageBot.lumiID {
                LumiStudio(api: api)
            } else {
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: botID)
            }
        }
        .task(id: deletedBot?.id) {
            guard let id = deletedBot?.id else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if deletedBot?.id == id { deletedBot = nil }
        }
    }

    private func computerLink(_ bot: VillageBot, roster: [VillageBot]) -> some View {
        NavigationLink {
            BotComputerView(bot: bot, roster: roster, api: api, onFileShared: onFileShared)
        } label: {
            FadedCard(accent: palette.cyan) {
                Label("Åbn computer", systemImage: "desktopcomputer")
                    .font(FadedTypography.action)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Computer for \(bot.name)")
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
            FadedSecondaryButton(bot.id == VillageBot.lumiID ? "Åbn Lumis private studie" : "Chat med botten", icon: "lock.shield") {
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

/// Lumi has a separate screen and a fixed PC route; ordinary bot chats never select her models.
struct LumiStudio: View {
    let api: LiveAPI?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.lumiPendingVideoJob) private var pendingVideoJobID = ""
    @State private var mode = 0
    @State private var draft = ""
    @State private var messages: [[String: String]] = []
    @State private var picture: Data?
    @State private var pictureFile: URL?
    @State private var videoPlayer: AVPlayer?
    @State private var videoFile: URL?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Vælg", selection: $mode) {
                    Text("Samtale").tag(0)
                    Text("Billeder").tag(1)
                    Text("Video").tag(2)
                }.pickerStyle(.segmented)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Lumi · privat 18+")
                            .font(.title2.bold())
                        Text("Skriv på dansk, engelsk eller en blanding. Du behøver ikke skrive perfekt.")
                            .font(.subheadline).foregroundStyle(palette.secondary)
                        if mode == 0 {
                            ForEach(Array(messages.enumerated()), id: \.offset) { _, item in
                                Text(item["content"] ?? "")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(item["role"] == "user" ? palette.raised : palette.card,
                                                in: .rect(cornerRadius: 14))
                            }
                        } else if mode == 1 {
                            if let picture, let image = UIImage(data: picture) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(.rect(cornerRadius: 16))
                                    .accessibilityLabel("Billede lavet af Lumi")
                            }
                            if let pictureFile {
                                ShareLink(item: pictureFile) {
                                    Label("Gem eller del billede", systemImage: "square.and.arrow.up")
                                        .frame(minHeight: 44)
                                }
                            }
                        } else if let videoPlayer {
                            VideoPlayer(player: videoPlayer).frame(height: 300)
                            if let videoFile {
                                ShareLink(item: videoFile) {
                                    Label("Gem eller del video", systemImage: "square.and.arrow.up")
                                        .frame(minHeight: 44)
                                }
                            }
                        } else {
                            Text("Lav et kort klip med PC’en. Det kan tage flere minutter.")
                                .font(.subheadline).foregroundStyle(palette.secondary)
                        }
                        if let notice {
                            Text(notice).font(.footnote).foregroundStyle(palette.coralText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField(mode == 0 ? "Skriv til Lumi" : mode == 1 ? "Beskriv dit billede" : "Beskriv din video", text: $draft,
                          axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(palette.raised, in: .rect(cornerRadius: 14))
                FadedPrimaryButton(busy ? "Arbejder på PC’en…" : mode == 0 ? "Send" : mode == 1 ? "Lav billede" : "Lav video",
                                   icon: mode == 0 ? "arrow.up" : mode == 1 ? "photo" : "film") { send() }
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || api == nil)
                if api == nil { Text("Forbind din PC for at bruge Lumi.").font(.footnote) }
            }
            .padding(16)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Lumi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Luk") { dismiss() } }
            .task { await resumeVideoIfNeeded() }
        }
    }

    private func send() {
        guard let api, !busy else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let selectedMode = mode
        let previous = Array(messages.suffix(16))
        draft = ""
        notice = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                if selectedMode == 0 {
                    let reply = try await api.lumiChat(message: input, history: previous)
                    messages.append(["role": "user", "content": input])
                    messages.append(["role": "assistant", "content": reply])
                } else if selectedMode == 1 {
                    let data = try await api.lumiImage(prompt: input)
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("lumi-\(UUID().uuidString).png")
                    try data.write(to: file, options: .atomic)
                    picture = data
                    pictureFile = file
                } else {
                    let receipt = try await api.lumiStartVideo(prompt: input)
                    guard let id = UUID(uuidString: receipt.id) else { throw APIError.malformed }
                    pendingVideoJobID = id.uuidString
                    try await finishVideo(id: id, api: api)
                }
            } catch {
                AppDiagnostics.record(error)
                if selectedMode != 2 || pendingVideoJobID.isEmpty { draft = input }
                show(error)
            }
        }
    }

    private func resumeVideoIfNeeded() async {
        guard !pendingVideoJobID.isEmpty else { return }
        guard let id = UUID(uuidString: pendingVideoJobID) else {
            pendingVideoJobID = ""
            return
        }
        guard let api, !busy else { return }
        mode = 2
        busy = true
        defer { busy = false }
        do { try await finishVideo(id: id, api: api) }
        catch {
            AppDiagnostics.record(error)
            if let apiError = error as? APIError, case .http(404, _) = apiError {
                pendingVideoJobID = ""
            }
            show(error)
        }
    }

    private func finishVideo(id: UUID, api: LiveAPI) async throws {
        var status = try await api.lumiVideoStatus(id: id)
        while status.status == "working" {
            try await Task.sleep(for: .seconds(12))
            status = try await api.lumiVideoStatus(id: id)
        }
        guard status.status == "ready" else {
            pendingVideoJobID = ""
            throw LumiJobFailure(message: status.message ?? "Videoen fejlede på PC’en.")
        }
        let data = try await api.lumiVideoFile(id: id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lumi-\(id.uuidString).mp4")
        try data.write(to: file, options: .atomic)
        videoFile = file
        videoPlayer = AVPlayer(url: file)
        pendingVideoJobID = ""
    }

    private func show(_ error: Error) {
        if let failure = error as? LumiJobFailure { notice = failure.message }
        else if let apiError = error as? APIError,
                case let .http(_, problem) = apiError,
                let message = problem?.message { notice = message }
        else { notice = AppErrorPresentation(error).title }
    }
}

private struct LumiJobFailure: Error {
    let message: String
}
