// Bot profile, local voice previews and a private chat entry point.

import Foundation
import AVKit
import AVFAudio
import PhotosUI
import SwiftUI

@MainActor struct VillageBotProfile: View {
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
    @State private var showPhoneChat = false
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
    @State private var confirmRetirement = false
    @StateObject private var speechBox = SpeechBox()

    private var bots: [VillageBot] { VillageBot.list(from: savedBots) }

    private var modelID: String { PhoneModels.effectiveModelID(phoneModel) }
    private var canTest: Bool {
        PhoneModels.isReady(modelID)
    }

    var body: some View {
        let localBots = bots
        ScrollView {
            VStack(spacing: 16) {
                if let bot = localBots.first(where: { $0.id == botID }) {
                    hero(bot)
                    profileShortcuts(bot, roster: localBots)
                    roomCard(bot)
                    NavigationLink {
                        BotMailView(api: api, bot: bot)
                    } label: {
                        FadedCard(accent: palette.cyan) {
                            Label("E-mail", systemImage: "envelope")
                                .font(FadedTypography.action)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    voiceCard(bot)
                    personalityCard(bot)
                    relationsCard(bot, roster: localBots)
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
        .sheet(isPresented: $showPhoneChat) {
            if let bot = localBots.first(where: { $0.id == botID }) { AgentPhoneChat(bot: bot, api: api) }
        }
        .sheet(isPresented: $showPrivateChat) {
            if botID == VillageBot.lumiID {
                LumiStudio(api: api)
            } else {
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: botID)
            }
        }
        .confirmationDialog("Slet bot og gem minde?", isPresented: $confirmRetirement, titleVisibility: .visible) {
            Button("Slet bot", role: .destructive, action: deleteBot)
        } message: {
            Text("Botten fjernes fra telefonen. Et minde med navn og rolle bliver i Kirkegården.")
        }
        .task(id: deletedBot?.id) {
            guard let id = deletedBot?.id else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if deletedBot?.id == id { deletedBot = nil }
        }
    }

    private func profileShortcuts(_ bot: VillageBot, roster: [VillageBot]) -> some View {
        HStack(spacing: 10) {
            FadedPrimaryButton("Chat", icon: "bubble.left") {
                speechBox.stop()
                if bot.id == VillageBot.lumiID { showPrivateChat = true }
                else { showPhoneChat = true }
            }
            .accessibilityLabel("Chat med \(bot.name)")
            NavigationLink {
                BotComputerView(bot: bot, roster: roster, api: api, onFileShared: onFileShared)
            } label: {
                Label("Computer", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(FadedButtonStyle(kind: .secondary))
            .accessibilityLabel("Computer for \(bot.name)")
        }
    }

    private func hero(_ bot: VillageBot) -> some View {
        VStack(spacing: 10) {
            Text(VillageHistory.shared.ageLabel(for: bot.id))
                .font(.caption.weight(.semibold)).foregroundStyle(FadedBrand.mint)
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

    private func roomCard(_ bot: VillageBot) -> some View {
        VillagePixelImage(name: "room-" + VillageAssets.newArtName(name: bot.name, id: bot.id.uuidString),
                          folder: "new")
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityLabel("Personligt område for \(bot.name)")
    }

    private func relationsCard(_ bot: VillageBot, roster: [VillageBot]) -> some View {
        FadedCard(accent: palette.green) {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Relationer og rytme")
                if let friend = roster.first(where: { $0.id == bot.bestFriendID }) {
                    Text("Nær ven: \(friend.name)").font(.subheadline)
                } else {
                    Text("Ingen relation er valgt endnu.").font(.subheadline).foregroundStyle(palette.secondary)
                }
                Text("Fokus 09–17 · fællesskab 17–21 · hvile 21–09")
                    .font(.caption).foregroundStyle(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
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
            if bot.id != VillageBot.lumiID {
                FadedSecondaryButton("Åbn i Studio", icon: "lock.shield") {
                    speechBox.stop()
                    showPrivateChat = true
                }
            }
            FadedSecondaryButton("Redigér", icon: "pencil") {
                speechBox.stop()
                editingBot = bot
            }
            FadedSecondaryButton("Duplikér bot", icon: "plus.square.on.square", action: duplicateBot)
                .disabled(!canDuplicate)
            if !canDuplicate { FadedDetailText("Der er plads til op til 10 bots.") }
            FadedSecondaryButton("Slet bot", icon: "trash", role: .destructive) { confirmRetirement = true }
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
            VillageHistory.shared.retired(bots[index])
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
            VillageHistory.shared.created(copy)
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
            VillageHistory.shared.restored(deletedBot.id)
            self.deletedBot = nil
            notice = nil
        } catch { AppDiagnostics.record(error); notice = "Botten kunne ikke gendannes." }
    }
}

/// Lumi has a separate screen and a fixed PC route; ordinary bot chats never select her models.
@MainActor struct LumiStudio: View {
    private enum SceneSheet: String, Identifiable {
        case library, new, edit, saveAs
        var id: String { rawValue }
    }

    let api: LiveAPI?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.lumiPendingVideoJob) private var pendingVideoJobID = ""
    @State private var mode = 0
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var imageDraft = ""
    @State private var videoDraft = ""
    @State private var language = "da-DK"
    @State private var dictation = ChatDictation()
    @StateObject private var speech = SpeechBox()
    @StateObject private var christel = ChristelPlayer()
    @State private var showChristelSettings = false
    @State private var showEverydayTools = false
    @State private var christelReady = false
    @State private var christelPCReady = false
    @Environment(\.scenePhase) private var phase
    @State private var messages: [LumiSceneMessage] = []
    @State private var sceneCard: LumiSceneCard?
    @State private var initiative: LumiInitiative = .together
    @State private var scenes: [LumiSavedScene] = []
    @State private var libraryNotice: String?
    @State private var sceneSheet: SceneSheet?
    @State private var nextSceneSheet: SceneSheet?
    @State private var pendingScene: LumiSavedScene?
    @State private var confirmSceneSwitch = false
    @State private var picture: Data?
    @State private var pictureFile: URL?
    @State private var referenceSelection: PhotosPickerItem?
    @State private var imageReference: Data?
    @State private var loadingReference = false
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

                ScrollViewReader { scroll in
                    ScrollView {
                        studioContent
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) {
                        guard mode == 0 else { return }
                        scroll.scrollTo("latest-lumi-message", anchor: .bottom)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { promptComposer }
                }
            }
            .padding(16)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Lumi")
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Luk") { dismiss() }
                }
                if mode == 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Hverdagsværktøjer", systemImage: "wrench.and.screwdriver") {
                            composerFocused = false
                            showEverydayTools = true
                        }
                        .disabled(busy || dictation.active)
                    }
                }
            }
            .sheet(isPresented: $showEverydayTools) {
                NavigationStack {
                    EverydayToolsView(draftTitle: "Brug i chat") { text in
                        guard !busy, !dictation.active,
                              let updated = EverydayDraft.appending(text, to: draft, limit: 4_000) else { return false }
                        draft = updated
                        showEverydayTools = false
                        return true
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Luk") { showEverydayTools = false } }
                    }
                }
            }
            .sheet(isPresented: $showChristelSettings, onDismiss: refreshChristel) {
                ChristelSettingsView(pcReady: christelPCReady)
            }
            .sheet(item: $sceneSheet, onDismiss: finishSceneSheet, content: sceneSheetContent)
            .alert("Skift scene?", isPresented: $confirmSceneSwitch) {
                Button("Skift uden at gemme", role: .destructive) {
                    if let pendingScene { openScene(pendingScene) }
                }
                Button("Bliv her", role: .cancel) { pendingScene = nil }
            } message: {
                Text("Du har nye beskeder eller ændringer i denne scene. Du kan blive her og gemme dem først.")
            }
            .task(id: "\(api?.queueTargetID ?? ""):\(phase == .active)") {
                if phase == .active { await refreshChristelPC() }
            }
            .task {
                refreshChristel()
                await resumeVideoIfNeeded()
            }
            .onChange(of: mode) {
                composerFocused = false
                stopAudio()
            }
            .onChange(of: phase) { if phase != .active { stopAudio() } }
            .onDisappear { stopAudio() }
        }
    }

    private var studioContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == 0 {
                sceneControls
                voiceControls
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { item in messageCard(item) }
                }
                Color.clear.frame(height: 1).id("latest-lumi-message")
            } else if mode == 1 {
                referencePicker
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
                FadedDetailText("Lav et kort klip med PC’en. Det kan tage flere minutter.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptComposer: some View {
        let currentDraft = promptDraft(for: mode)
        let placeholder = mode == 0 ? "Skriv til Lumi" : mode == 1 ? "Beskriv dit billede" : "Beskriv din video"
        let action = mode == 0 ? "Send" : mode == 1 ? "Lav billede" : "Lav video"
        let icon = mode == 0 ? "arrow.up" : mode == 1 ? "photo" : "film"
        return VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(palette.coralText)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if api == nil {
                FadedDetailText("Forbind din PC for at bruge Lumi.")
            }
            if busy { ProgressView(mode == 0 ? "Lumi svarer på PC’en…" : "Arbejder på PC’en…") }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: currentDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .frame(minHeight: 44)
                    .fadedGlassSurface()
                    .focused($composerFocused)
                if composerFocused {
                    Button("Skjul tastatur", systemImage: "keyboard.chevron.compact.down") { composerFocused = false }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .fadedGlassSurface()
                }
                Button(action, systemImage: icon) { send() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .buttonStyle(FadedButtonStyle(kind: .primary))
                    .disabled(busy || (mode == 1 && loadingReference) || dictation.active || api == nil ||
                              !isValidPrompt(currentDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(.top, 8)
        .background(palette.background)
    }

    private func messageCard(_ message: LumiSceneMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == .user ? "Dig" : "Lumi")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondary)
            Text(message.text).textSelection(.enabled)
            if message.role == .assistant {
                replyAudio(message.text, language: message.language)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(message.role == .user ? palette.raised : palette.card, in: .rect(cornerRadius: 14))
    }

    private var sceneControls: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(sceneCard?.title ?? "Lumi · privat 18+")
                    .font(FadedTypography.action)
                if let sceneCard {
                    FadedDetailText(sceneCard.mood.title)
                }
                Picker("Initiativ", selection: $initiative) {
                    ForEach(LumiInitiative.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        leadButton
                        libraryButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        leadButton
                        libraryButton
                    }
                }
                HStack {
                    Button("Gem scenen", systemImage: "bookmark") {
                        if let sceneCard { saveScene(sceneCard) }
                        else { sceneSheet = .saveAs }
                    }
                    .frame(minHeight: 44)
                    .disabled(sceneCard == nil && messages.isEmpty && draft.isEmpty)
                    Spacer()
                    if sceneCard != nil {
                        Button("Redigér scenekort", systemImage: "pencil") { sceneSheet = .edit }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        }
        .disabled(busy || dictation.active)
    }

    private var leadButton: some View {
        FadedSecondaryButton("Tag føringen", icon: "sparkles") { send(opening: true) }
            .disabled(api == nil)
    }

    private var libraryButton: some View {
        FadedSecondaryButton("Scenebibliotek", icon: "books.vertical") {
            loadScenes()
            sceneSheet = .library
        }
    }

    @ViewBuilder private func sceneSheetContent(_ sheet: SceneSheet) -> some View {
        switch sheet {
        case .library:
            LumiSceneLibraryView(scenes: scenes, notice: libraryNotice, onOpen: { pendingScene = $0 },
                                 onRemove: removeScene, onNew: { nextSceneSheet = .new })
        case .new:
            LumiSceneCardEditor(card: LumiSceneCard(), actionTitle: "Start scenen") { card in
                pendingScene = .snapshot(card: card, initiative: .together, language: language, messages: [], draft: "")
            }
        case .edit:
            if let sceneCard {
                LumiSceneCardEditor(card: sceneCard, actionTitle: "Brug scenekort") { self.sceneCard = $0 }
            }
        case .saveAs:
            LumiSceneCardEditor(card: LumiSceneCard(), actionTitle: "Gem scenen") { saveScene($0) }
        }
    }

    private func finishSceneSheet() {
        if let nextSceneSheet {
            self.nextSceneSheet = nil
            sceneSheet = nextSceneSheet
            return
        }
        guard let pendingScene else { return }
        if sceneHasEdits {
            confirmSceneSwitch = true
        } else {
            openScene(pendingScene)
        }
    }

    private var sceneHasEdits: Bool {
        guard let sceneCard else { return !messages.isEmpty || !draft.isEmpty }
        guard let saved = scenes.first(where: { $0.id == sceneCard.id }) else { return true }
        return !saved.matches(sceneSnapshot(sceneCard))
    }

    private func sceneSnapshot(_ card: LumiSceneCard) -> LumiSavedScene {
        .snapshot(card: card, initiative: initiative, language: language, messages: messages, draft: draft)
    }

    private func openScene(_ scene: LumiSavedScene) {
        stopAudio()
        sceneCard = scene.card
        initiative = scene.initiative
        language = scene.language == "en-US" ? "en-US" : "da-DK"
        messages = scene.messages
        draft = scene.draft
        pendingScene = nil
        notice = nil
    }

    private func loadScenes() {
        do {
            scenes = try LumiSceneLibrary.load()
            libraryNotice = nil
        } catch {
            libraryNotice = "Scenebiblioteket kunne ikke læses. Lås iPhone op, og prøv igen."
        }
    }

    private func saveScene(_ card: LumiSceneCard) {
        do {
            let current = try LumiSceneLibrary.load()
            guard current.count < LumiSceneLibrary.maximumScenes || current.contains(where: { $0.id == card.id }) else {
                notice = "Scenebiblioteket er fuldt. Fjern en gammel scene, før du gemmer en ny."
                return
            }
            let updated = [sceneSnapshot(card)] + current.filter { $0.id != card.id }
            try LumiSceneLibrary.save(updated)
            scenes = updated
            sceneCard = card
            notice = "Scenen er gemt på denne iPhone."
        } catch {
            notice = "Scenen kunne ikke gemmes. Lås iPhone op, og prøv igen."
        }
    }

    private func removeScene(_ id: UUID) {
        do {
            let updated = try LumiSceneLibrary.load().filter { $0.id != id }
            try LumiSceneLibrary.save(updated)
            scenes = updated
            libraryNotice = nil
        } catch {
            libraryNotice = "Scenen kunne ikke slettes. Prøv igen."
        }
    }

    private func refreshChristel() {
        christelReady = ChristelConfiguration.load() != nil
        Task { await refreshChristelPC() }
    }

    private func refreshChristelPC() async {
        let available = (try? await api?.christelConfigured()) == true
        if !Task.isCancelled { christelPCReady = available }
    }

    private func replyAudio(_ text: String, language: String) -> some View {
        let locale = LocalSpeechVoice.detectedReplyLanguage(text) ?? language
        return VStack(alignment: .leading, spacing: 2) {
            Button("Læs op på iPhone", systemImage: "speaker.wave.2") {
                dictation.stop()
                christel.stop()
                let voice = LocalSpeechVoice.preferred(language: locale)
                speech.play(LocalSpeechVoice.utterance(LocalSpeechVoice.replyText(text), voice: voice, rate: 1), as: .preview)
            }
            .frame(minHeight: 44)
            if locale == "da-DK" && (christelReady || christelPCReady) {
                Button("Læs med Christel · online", systemImage: "waveform") {
                    dictation.stop()
                    speech.stop()
                    christel.play(text: LocalSpeechVoice.replyText(text), pc: christelPCReady ? api : nil)
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var voiceControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Sprog", selection: $language) {
                    Text("Dansk").tag("da-DK")
                    Text("English").tag("en-US")
                }
                .disabled(dictation.active)
                Spacer()
                Button(dictation.active ? "Stop" : "Diktér", systemImage: dictation.active ? "stop.circle" : "mic") {
                    if dictation.active {
                        dictation.stop()
                    } else {
                        speech.stop()
                        christel.stop()
                        let locale = language
                        let prefix = draft.isEmpty ? "" : draft + " "
                        Task { await dictation.start(language: locale) { draft = prefix + $0 } }
                    }
                }
                .frame(minHeight: 44)
                if speech.playback != nil || christel.loading || christel.playing {
                    Button("Stop oplæsning", systemImage: "speaker.slash") {
                        speech.stop()
                        christel.stop()
                    }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            Button(christelReady || christelPCReady ? "Christel · indstillinger" : "Sæt Christel op", systemImage: "waveform") {
                stopAudio()
                showChristelSettings = true
            }
            .font(.footnote)
            .frame(minHeight: 44)
            if christel.loading {
                ProgressView("Christel gør oplæsningen klar…").font(.caption)
            }
            if let notice = christel.notice {
                FadedDetailText(notice)
            }
            if let problem = dictation.problem {
                Text(problem).font(.caption).foregroundStyle(palette.secondary)
            } else if dictation.hasTranscript {
                Text("Du kan rette teksten, før du sender.").font(.caption).foregroundStyle(palette.secondary)
            }
        }
    }

    private func stopAudio() {
        dictation.stop()
        speech.stop()
        christel.stop()
    }

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let imageReference, let preview = UIImage(data: imageReference) {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                        .accessibilityLabel("Valgt referencebillede")
                }
                PhotosPicker(selection: $referenceSelection, matching: .images) {
                    Label(imageReference == nil ? "Tilføj referencebillede" : "Skift referencebillede",
                          systemImage: "photo.badge.plus").frame(minHeight: 44)
                }
                .disabled(busy)
                if loadingReference { ProgressView() }
                if imageReference != nil || loadingReference {
                    Button("Fjern referencebillede", systemImage: "xmark") {
                        referenceSelection = nil
                        imageReference = nil
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(busy)
                }
            }
            if imageReference != nil {
                Text("Referencebilledet sendes til ComfyUI på din PC, når du trykker Lav billede.")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
        }
        .task(id: referenceSelection) {
            guard let item = referenceSelection else { loadingReference = false; return }
            imageReference = nil
            loadingReference = true
            defer { if referenceSelection == item { loadingReference = false } }
            do {
                guard let input = try await item.loadTransferable(type: StudioPhotoInput.self),
                      (1...1_000_000).contains(input.data.count) else { throw APIError.input }
                try Task.checkCancellation()
                if referenceSelection == item { imageReference = input.data }
            } catch {
                if !Task.isCancelled && referenceSelection == item {
                    notice = "Referencebilledet kunne ikke åbnes."
                }
            }
        }
    }

    private func promptDraft(for mode: Int) -> Binding<String> {
        switch mode {
        case 1: $imageDraft
        case 2: $videoDraft
        default: $draft
        }
    }

    private func isValidPrompt(_ prompt: String) -> Bool {
        (1...4_000).contains(prompt.unicodeScalars.count)
    }

    private func send(opening: Bool = false) {
        guard let api, !busy, !dictation.active else { return }
        let selectedMode = mode
        guard !opening || selectedMode == 0 else { return }
        let selectedDraft = promptDraft(for: selectedMode)
        let input = opening ? (language == "da-DK" ? "Tag føringen" : "Take the lead")
            : selectedDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPrompt(input) else { return }
        composerFocused = false
        let reference = selectedMode == 1 ? imageReference : nil
        let replyLanguage = language
        let selectedScene = sceneCard
        let selectedInitiative: LumiInitiative = opening ? .lumi : initiative
        dictation.clearReview()
        let previous = modelHistory
        if !opening { selectedDraft.wrappedValue = "" }
        notice = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                if selectedMode == 0 {
                    let reply = try await api.lumiChat(message: input, history: previous, language: replyLanguage,
                                                      scene: selectedScene, initiative: selectedInitiative, opening: opening)
                    if opening { initiative = .lumi }
                    messages.append(LumiSceneMessage(role: .user, text: input, language: replyLanguage))
                    messages.append(LumiSceneMessage(role: .assistant, text: String(reply.unicodeScalars.prefix(4_000)),
                                                     language: replyLanguage))
                } else if selectedMode == 1 {
                    let data = try await api.lumiImage(prompt: input, reference: reference)
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
                if !opening && selectedDraft.wrappedValue.isEmpty && (selectedMode != 2 || pendingVideoJobID.isEmpty) {
                    selectedDraft.wrappedValue = input
                }
                if selectedMode == 0, selectedScene != nil || selectedInitiative != .together || opening,
                   let apiError = error as? APIError, case .http(404, _) = apiError {
                    notice = "Opdatér FadedAI på PC’en for at bruge scenekort og initiativ."
                } else {
                    show(error)
                }
            }
        }
    }

    private var modelHistory: [[String: String]] {
        var remaining = 9_000
        var selected: [[String: String]] = []
        for message in messages.suffix(16).reversed() {
            guard remaining >= 80 else { break }
            let text = String(decoding: message.text.utf8.prefix(remaining), as: UTF8.self)
            selected.append(["role": message.role.rawValue, "content": text])
            remaining -= text.utf8.count
        }
        if selected.last?["role"] == "assistant" { selected.removeLast() }
        return Array(selected.reversed())
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
