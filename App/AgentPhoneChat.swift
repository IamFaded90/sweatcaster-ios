import SwiftUI
import UIKit

@MainActor struct AgentPhoneChat: View {
    private struct Model: Identifiable {
        let id: String
        let title: String
    }

    let bot: VillageBot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.phoneModel) private var preferredModel = "apple"
    @AppStorage private var rememberedModel: String
    @State private var selectedModel = ""
    @State private var models: [Model] = []
    @State private var turns: [PrivateChatTurn] = []
    @State private var draft = ""
    @State private var notice: String?
    @State private var running: Task<Void, Never>?
    @State private var pendingPrompt: String?
    @State private var showModels = false
    @State private var showEverydayTools = false
    @State private var modelBeforeSettings = ""
    @State private var loaded = false
    @StateObject private var speech = SpeechBox()

    init(bot: VillageBot) {
        self.bot = bot
        _rememberedModel = AppStorage(wrappedValue: "", "agent-phone.model.\(bot.id.uuidString.lowercased())")
    }

    private var keepHistory: Bool { bot.id != VillageBot.lumiID }
    private var cleanDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftKey: String { AppStorageKeys.chatSession("agent-phone-\(bot.id.uuidString.lowercased())") }
    private var recoverableDraft: String { draft.isEmpty ? pendingPrompt ?? "" : draft }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        modelCard
                        ForEach(turns) { turn in
                            turnCard(turn)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(FadedSpacing.edge)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
                .safeAreaInset(edge: .bottom) { composer }
            }
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle(bot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hverdagsværktøjer", systemImage: "wrench.and.screwdriver") { showEverydayTools = true }
                        .disabled(running != nil)
                }
            }
            .sheet(isPresented: $showEverydayTools) {
                NavigationStack {
                    EverydayToolsView(showAppleApps: keepHistory, draftTitle: "Brug i chat") { text in
                        guard running == nil, let updated = EverydayDraft.appending(text, to: draft, limit: 1_200) else {
                            return false
                        }
                        draft = updated
                        showEverydayTools = false
                        return true
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Luk") { showEverydayTools = false } }
                    }
                }
            }
            .sheet(isPresented: $showModels, onDismiss: {
                loadModels(preferSetting: preferredModel != modelBeforeSettings)
            }) { PhoneModelsView() }
            .task {
                loadModels()
                if !loaded && keepHistory {
                    turns = MigratedAppData.shared.regularStudioTurns().filter { $0.botID == bot.id && $0.imageName == nil }
                    draft = MigratedAppData.shared.chatDraft(draftKey)
                }
                loaded = true
            }
            .task(id: recoverableDraft) {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                saveDraft()
            }
            .onChange(of: phase) { _, value in
                if value == .active { loadModels() }
                else {
                    saveDraft()
                    running?.cancel()
                    speech.stop()
                }
            }
            .onDisappear {
                saveDraft()
                running?.cancel()
                speech.stop()
            }
        }
    }

    private var modelCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Chat på iPhone", systemImage: "iphone").font(.headline)
                if models.isEmpty {
                    FadedDetailText("Vælg eller hent en telefonmodel, før du chatter offline.")
                } else {
                    Picker("Telefonmodel", selection: Binding(get: { selectedModel }, set: { id in
                        selectedModel = id
                        rememberedModel = id
                    })) {
                        ForEach(models) { model in Text(model.title).tag(model.id) }
                    }
                    .disabled(running != nil)
                }
                FadedSecondaryButton("Lokale modeller", icon: "arrow.down.circle") {
                    modelBeforeSettings = preferredModel
                    showModels = true
                }
                    .disabled(running != nil)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func turnCard(_ turn: PrivateChatTurn) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Dig", systemImage: "person.crop.circle").font(.caption.weight(.semibold))
                Text(turn.prompt)
                if !turn.reply.isEmpty {
                    Divider()
                    Label(bot.name, systemImage: "iphone").font(.caption.weight(.semibold))
                    Text(turn.reply).textSelection(.enabled)
                    HStack {
                        let playing = speech.playback == .reply(turn.id)
                        Button(playing ? "Stop oplæsning" : "Læs op", systemImage: playing ? "stop.circle" : "speaker.wave.2") {
                            readReply(turn)
                        }
                        .frame(minHeight: 44)
                        Button("Kopiér", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.reply }
                            .frame(minHeight: 44)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice { FadedDetailText(notice) }
            if running != nil { ProgressView("\(bot.name) svarer på iPhone…") }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Skriv til \(bot.name)…", text: $draft, axis: .vertical)
                    .lineLimit(1...4).frame(minHeight: 44)
                    .textFieldStyle(.roundedBorder)
                if running != nil {
                    Button("Stop svar", systemImage: "stop.fill") { running?.cancel() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Send på iPhone", systemImage: "arrow.up") { send() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .disabled(cleanDraft.isEmpty || cleanDraft.count > 1200 || selectedModel.isEmpty)
                }
            }
        }
        .padding(FadedSpacing.edge)
        .background(palette.background)
    }

    private func loadModels(preferSetting: Bool = false) {
        var available = PhoneModels.catalog.filter { PhoneModels.isReady($0.id) }
            .map { Model(id: $0.id, title: $0.name) }
        if PhoneModels.appleAvailable { available.insert(Model(id: "apple", title: "Apple på iPhone"), at: 0) }
        if PhoneModels.isReady("imported") { available.append(Model(id: "imported", title: "Importeret model")) }
        models = available
        let ids = Set(available.map(\.id))
        if preferSetting && ids.contains(preferredModel) && preferredModel != rememberedModel {
            selectedModel = preferredModel
            rememberedModel = preferredModel
        } else if !ids.contains(selectedModel) {
            selectedModel = if ids.contains(rememberedModel) { rememberedModel }
            else if ids.contains(preferredModel) { preferredModel }
            else { available.first?.id ?? "" }
        }
    }

    private func saveDraft() {
        guard keepHistory, loaded else { return }
        let value = String(recoverableDraft.prefix(1200))
        guard value != MigratedAppData.shared.chatDraft(draftKey) else { return }
        do { try MigratedAppData.shared.saveChatDraft(value, sessionKey: draftKey) }
        catch { AppDiagnostics.record(error) }
    }

    private func readReply(_ turn: PrivateChatTurn) {
        if speech.playback == .reply(turn.id) {
            speech.stop()
            return
        }
        let text = LocalSpeechVoice.replyText(turn.reply)
        let locale = LocalSpeechVoice.detectedReplyLanguage(text) ?? bot.language ?? "da-DK"
        let voice = LocalSpeechVoice.forReply(LocalSpeechVoice.resolve(identifier: bot.voice, language: locale),
                                             language: locale)
        speech.play(LocalSpeechVoice.utterance(text, voice: voice, rate: bot.voiceRate ?? 1), as: .reply(turn.id))
    }

    private func send() {
        let message = cleanDraft
        let model = selectedModel
        guard running == nil, !message.isEmpty, message.count <= 1200, PhoneModels.isReady(model) else { return }
        let history = turns.suffix(4).filter { !$0.reply.isEmpty }
            .map { PhoneModels.ChatExchange(prompt: String($0.prompt.prefix(220)), reply: String($0.reply.prefix(280))) }
        let request = if model == "apple", !history.isEmpty {
            "Tidligere samtale:\n" + history.map { "Dig: \($0.prompt)\n\(bot.name): \($0.reply)" }.joined(separator: "\n") +
                "\n\nSeneste besked: " + message
        } else { message }
        let instructions = OfflineStudio.companionInstructions(for: bot) +
            " Du kører lokalt på iPhone. Du kan svare på tekst. Påstå ikke, at du kan åbne mail, en PC eller hjemmesider."
        let turn = PrivateChatTurn(prompt: message, reply: "", source: "Telefon", botID: bot.id)
        turns.append(turn)
        pendingPrompt = message
        draft = ""
        speech.stop()
        notice = nil
        running = Task {
            defer {
                pendingPrompt = nil
                running = nil
                saveDraft()
            }
            do {
                try await PhoneModels.reply(modelID: model, prompt: request, instructions: instructions, history: history) { reply in
                    if !Task.isCancelled, let index = turns.firstIndex(where: { $0.id == turn.id }) {
                        turns[index].reply = reply
                    }
                }
                try Task.checkCancellation()
                if keepHistory, let completed = turns.first(where: { $0.id == turn.id }), !completed.reply.isEmpty {
                    do {
                        let saved = MigratedAppData.shared.regularStudioTurns()
                        try MigratedAppData.shared.saveRegularStudioTurns(saved + [completed])
                    } catch { notice = "Svaret vises her, men historikken kunne ikke gemmes." }
                }
            } catch {
                turns.removeAll { $0.id == turn.id }
                if draft.isEmpty { draft = message }
                if !Task.isCancelled { notice = "Telefonmodellen kunne ikke svare. Prøv en kortere besked eller en anden model." }
            }
        }
    }
}
