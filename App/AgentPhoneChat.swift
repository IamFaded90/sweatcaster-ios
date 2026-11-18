import AVFAudio
import SwiftUI
import UIKit

@MainActor struct AgentPhoneChat: View {
    struct Model: Identifiable {
        let id: String
        let title: String
    }

    let bot: VillageBot
    let api: LiveAPI?
    let startsOnPhone: Bool
    let opensAction: UUID?
    let sharedAttachment: AgentShareAttachment?
    enum Source: String, CaseIterable, Identifiable {
        case phone = "iPhone", pc = "PC", composio = "Composio"
        var id: Self { self }
    }
    @Environment(\.dismiss) var dismiss
    @Environment(\.fadedPalette) var palette
    @Environment(\.scenePhase) var phase
    @AppStorage(AppStorageKeys.phoneModel) var preferredModel = "apple"
    @AppStorage var rememberedModel: String
    @AppStorage var rememberedPCModel: String
    @AppStorage var rememberedSource: String
    @AppStorage var voiceOverride: String
    @AppStorage var dictationLanguage: String
    @AppStorage var voicePauseSeconds: Double
    @State var selectedModel = ""
    @State var models: [Model] = []
    @State var pcModels: [Model] = []
    @State var selectedPCModel = ""
    @ObservedObject var composioCloud = ComposioCloudAccount.shared
    @ObservedObject var nvidiaCloud = NvidiaCloudAccount.shared
    @ObservedObject var openRouterCloud = OpenRouterCloudAccount.shared
    @State var selectedComposioModel = "deepseek-chat"
    @State var source = Source.phone
    @State var turns: [PrivateChatTurn] = []
    @State var draft = ""
    @FocusState var composerFocused: Bool
    @State var notice: String?
    @State var running: Task<Void, Never>?
    @State var pendingPrompt: String?
    @State var showModels = false
    @State var showEverydayTools = false
    @State private var showPCTools = false
    @State var showDocuments = false
    @State var nextDocument: AgentDocument?
    @State var showTranscript = false
    @State var translating: PrivateChatTurn?
    @State var gmailDraft: PrivateChatTurn?
    @State var gmailCheck: AgentGmailCheck.Request?
    @State var openAgentAction: UUID?
    @State var agentActionRefresh = UUID()
    @State var modelBeforeSettings = ""
    @State var loaded = false
    @State var web = false
    @State var answerAsCard = false
    @State var wakeID = UUID()
    @State var appleDictation = ChatDictation()
    @State var whisper = AgentWhisperCapture()
    @State var showVoice = false
    @State var handsFree = false
    @State var waitingForVoice = false
    @State var handsFreeOffline = false
    @State var voiceSilence: Task<Void, Never>?
    @State var listeningTask: Task<Void, Never>?
    @State var voiceRun = UUID()
    @State var pcVoiceReplyID: UUID?
    @State var spokenLanguage = "da-DK"
    @StateObject var speech = SpeechBox()
    @StateObject var kokoro = ChristelPlayer()

    init(bot: VillageBot, api: LiveAPI? = nil, startsOnPhone: Bool = false, opensAction: UUID? = nil,
         sharedAttachment: AgentShareAttachment? = nil) {
        self.bot = bot
        self.api = api
        self.startsOnPhone = startsOnPhone
        self.opensAction = opensAction
        self.sharedAttachment = sharedAttachment
        _nextDocument = State(initialValue: sharedAttachment?.document)
        _rememberedModel = AppStorage(wrappedValue: "", PhoneModels.agentModelKey(bot.id))
        _rememberedPCModel = AppStorage(wrappedValue: "", PhoneModels.agentPCModelKey(bot.id))
        _rememberedSource = AppStorage(wrappedValue: Source.phone.rawValue, "agent-chat.source." + bot.id.uuidString.lowercased())
        _voiceOverride = AppStorage(wrappedValue: "", PhoneModels.agentVoiceKey(bot.id))
        _dictationLanguage = AppStorage(wrappedValue: "da-DK", "agent-chat.dictation-language." + bot.id.uuidString.lowercased())
        _voicePauseSeconds = AppStorage(wrappedValue: 2.5, "agent-chat.voice-pause." + bot.id.uuidString.lowercased())
    }

    var keepHistory: Bool { bot.id != VillageBot.lumiID }
    var cleanDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var draftKey: String { AppStorageKeys.chatSession("agent-phone-\(bot.id.uuidString.lowercased())") }
    var recoverableDraft: String { draft.isEmpty ? pendingPrompt ?? "" : draft }
    var currentModel: String {
        source == .phone ? selectedModel : source == .pc ? selectedPCModel : selectedComposioModel
    }

    var cloudModels: [Model] {
        guard keepHistory else { return [] }
        var result: [Model] = []
        if composioCloud.allows("deepseek") { result.append(.init(id: "deepseek-chat", title: "DeepSeek · Composio")) }
        if composioCloud.allows("grok") { result.append(.init(id: "grok-4.7", title: "Grok · Composio")) }
        if nvidiaCloud.enabled {
            result.append(contentsOf: nvidiaCloud.models.map { .init(id: $0, title: NvidiaCloud.title($0)) })
        }
        if openRouterCloud.enabled {
            result.append(contentsOf: openRouterCloud.models.map { .init(id: $0, title: OpenRouterCloud.title($0)) })
        }
        return result
    }

    var sourceModels: [Model] { source == .phone ? models : source == .pc ? pcModels : cloudModels }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        AgentSpeakingStage(bot: bot, listening: appleDictation.active || whisper.active)
                        DisclosureGroup {
                            modelCard
                        } label: {
                            Label(source.rawValue + " · " + (sourceModels
                                .first(where: { $0.id == currentModel })?.title ?? "Vælg model"),
                                  systemImage: source == .composio ? "cloud" : source == .pc ? "desktopcomputer" : "iphone")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(source == .pc ? palette.cyan : palette.lime)
                        }
                        if turns.isEmpty && gmailCheck == nil {
                            VStack(spacing: 12) {
                                VillageBotAvatar(bot: bot, size: 64, radius: 32)
                                Text("Tal med " + bot.name).font(.title2.bold())
                                FadedDetailText("Din agent · din samtale. Skriv nedenfor for at begynde.")
                                if keepHistory { agentActionShortcuts }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                        }
                        if let gmailCheck, gmailCheck.afterTurn == nil { gmailCard(gmailCheck) }
                        ForEach(turns) { turn in
                            agentChatEntry(turn)
                            if let gmailCheck, gmailCheck.afterTurn == turn.id { gmailCard(gmailCheck) }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(FadedSpacing.edge)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, _ in
                    if let openAgentAction { scroll.scrollTo(openAgentAction, anchor: .center) }
                    else { scroll.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: gmailCheck?.id) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
                .onChange(of: openAgentAction) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                .safeAreaInset(edge: .bottom) { composer }
            }
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle(bot.name + " · Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        VillageBotAvatar(bot: bot, size: 30, radius: 15)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bot.name).font(.headline).lineLimit(1)
                            Text("Agentchat").font(.caption).foregroundStyle(palette.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hverdagsværktøjer", systemImage: "wrench.and.screwdriver") { showEverydayTools = true }
                        .disabled(running != nil)
                }
                if api != nil && keepHistory {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Agentens PC-værktøjer", systemImage: "desktopcomputer") { showPCTools = true }
                            .disabled(running != nil)
                    }
                }
            }
            .sheet(isPresented: $showPCTools) {
                if let api { AgentPCToolsView(api: api) }
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
                    .safeAreaInset(edge: .bottom) {
                        if keepHistory { AssistantCaptureStrip().padding(FadedSpacing.edge) }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Luk") { showEverydayTools = false } }
                    }
                }
            }
            .sheet(isPresented: $showModels, onDismiss: {
                loadModels(preferSetting: preferredModel != modelBeforeSettings)
            }) { PhoneModelsView() }
            .sheet(isPresented: $showDocuments) {
                AgentDocumentsView(bot: bot) { document in
                    nextDocument = document
                    web = false
                } onRemove: { id in
                    if nextDocument?.id == id { nextDocument = nil }
                }
            }
            .onChange(of: source) { if source != .phone { nextDocument = nil } }
            .task {
                loadModels()
                if !loaded && keepHistory {
                    turns = MigratedAppData.shared.regularStudioTurns().filter { $0.botID == bot.id && $0.imageName == nil }
                    draft = MigratedAppData.shared.chatDraft(draftKey)
                    if let opensAction, turns.contains(where: { $0.id == opensAction }) { openAgentAction = opensAction }
                }
                loaded = true
            }
            .task(id: api?.queueTargetID) {
                await loadPCModels()
                await selectRequestedAdamVoiceIfAvailable()
            }
            .task(id: gmailCheck?.id) { await gmailCheck?.run(bot: bot, api: api) }
            .onChange(of: running != nil, initial: true) {
                ChatScreenWake.hold(wakeID, whileReplying: running != nil && phase == .active)
            }
            .onChange(of: speech.playback) { _, playback in
                if playback == nil, waitingForVoice, handsFree {
                    waitingForVoice = false
                    listenHandsFree()
                }
            }
            .onChange(of: kokoro.playing) { old, playing in
                if old && !playing { finishPCReading() }
            }
            .onChange(of: kokoro.notice) { _, problem in
                if let problem { if handsFree { stopVoice() }; notice = problem }
            }
            .onChange(of: appleDictation.problem) { _, problem in
                if !handsFreeOffline, let problem { stopVoice(); notice = problem }
            }
            .onChange(of: appleDictation.active) { _, active in
                if !active, handsFree, !handsFreeOffline, !waitingForVoice, running == nil, cleanDraft.isEmpty {
                    stopVoice()
                    notice = "Jeg hørte ingen ord. Start mikrofonen igen, når du er klar."
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
                stopVoice()
            }
            .onReceive(kokoro.$notice) { if let message = $0 { notice = message } }
            .sheet(isPresented: $showVoice) { voiceSettings }
            .sheet(isPresented: $showTranscript) { AgentDictationTranscript(segments: whisper.segments) }
            .sheet(item: $translating) { AgentTranslationView(original: $0.reply, suggestedModel: selectedModel) }
            .sheet(item: $gmailDraft) { turn in
                if let api { GmailDraftView(api: api, draft: turn.reply) }
            }
            .task(id: recoverableDraft) {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                saveDraft()
            }
            .onChange(of: phase) { _, value in
                if value == .active { loadModels() }
                else {
                    ChatScreenWake.hold(wakeID, whileReplying: false)
                    stopVoice()
                    saveDraft()
                    running?.cancel()
                    speech.stop()
                }
            }
            .onDisappear {
                ChatScreenWake.hold(wakeID, whileReplying: false)
                stopVoice()
                saveDraft()
                running?.cancel()
                speech.stop()
            }
        }
    }

    var modelCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Svar fra", selection: Binding(get: { source }, set: { selected in
                    source = selected
                    if selected == .composio && !cloudModels.contains(where: { $0.id == selectedComposioModel }) {
                        selectedComposioModel = cloudModels.first?.id ?? ""
                    }
                    rememberedSource = selected.rawValue
                })) {
                    Text("iPhone").tag(Source.phone)
                    if !pcModels.isEmpty { Text("PC").tag(Source.pc) }
                    if !cloudModels.isEmpty { Text("Cloud").tag(Source.composio) }
                }
                .pickerStyle(.segmented)
                .disabled(running != nil)
                if source == .composio {
                    Picker("Cloudmodel", selection: $selectedComposioModel) {
                        ForEach(cloudModels) { Text($0.title).tag($0.id) }
                    }.disabled(running != nil)
                    FadedDetailText("Virker over internet med PC’en slukket. Forbrug afhænger af kontoen.")
                } else if source == .pc {
                    Picker("PC-model", selection: Binding(get: { selectedPCModel }, set: { id in
                        selectedPCModel = id
                        rememberedPCModel = id
                    })) {
                        ForEach(pcModels) { model in Text(model.title).tag(model.id) }
                    }
                    .disabled(running != nil)
                } else if models.isEmpty {
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
                if keepHistory {
                    ComposioCloudSetup(api: api).disabled(running != nil)
                    NvidiaCloudSetup(api: api).disabled(running != nil)
                    OpenRouterCloudSetup(api: api).disabled(running != nil)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func turnCard(_ turn: PrivateChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentChatBubble(user: true, title: "Dig", pc: false) {
                Text(turn.prompt).textSelection(.enabled)
                    .contextMenu {
                        Button("Redigér besked", systemImage: "pencil") { edit(turn) }.disabled(running != nil)
                        if !turn.reply.isEmpty { retryMenu(turn) }
                    }
            }
            if !turn.reply.isEmpty {
                AgentChatBubble(user: false,
                                title: [bot.name, turn.source, turn.replyModelName].compactMap { $0 }.joined(separator: " · "),
                                pc: turn.source == "PC") {
                    if let card = turn.replyCard {
                        Text(card.title).font(.headline)
                        ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "circle.fill").labelStyle(.titleOnly)
                        }
                    } else {
                        ChatTranscriptView(reply: turn.reply)
                    }
                    if let sources = turn.webSources, !sources.isEmpty {
                        DisclosureGroup("Kilder · \(sources.count)") {
                            ForEach(sources.filter(\.isWeb)) { source in
                                Link(destination: source.url) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.title)
                                        Text(source.readPage ? "Side læst" : "Søgeuddrag")
                                            .font(.caption).foregroundStyle(palette.secondary)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                    if let sources = turn.documentSources, !sources.isEmpty {
                        DisclosureGroup("Dokumentkilder") {
                            ForEach(sources) { source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "[\(source.id)] \(source.name)")
                                    if let page = source.page { Text("Side \(page)").font(.caption) }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    if running == nil || turns.last?.id != turn.id { HStack {
                        let playing = speech.playback == .reply(turn.id) ||
                            (pcVoiceReplyID == turn.id && (kokoro.playing || kokoro.loading))
                        Button(playing ? "Stop oplæsning" : "Læs op", systemImage: playing ? "stop.circle" : "speaker.wave.2") {
                            readReply(turn)
                        }
                        .frame(minHeight: 44)
                        Button("Kopiér", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.reply }
                            .frame(minHeight: 44)
                        Button("Oversæt til dansk", systemImage: "character.bubble") { translating = turn }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        if let api, keepHistory { kokoroMenu(turn, api: api) }
                        if api != nil, keepHistory {
                            Button("Lav Gmail-kladde", systemImage: "envelope") { gmailDraft = turn }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    } }
                }
            } else if running != nil {
                AgentChatBubble(user: false, title: bot.name, pc: turn.source == "PC") {
                    FadedThinkingIndicator(title: "Svarer…").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice { FadedDetailText(notice) }
            if running != nil { FadedThinkingIndicator(title: "\(bot.name) svarer…") }
            if running == nil {
                voiceActions
                if keepHistory && source == .phone {
                    HStack {
                        Button("Dokumenter", systemImage: "doc.text") { showDocuments = true }
                            .frame(minHeight: 44)
                        if let nextDocument {
                            Text(verbatim: nextDocument.name).lineLimit(1)
                            Button("Fjern fra næste besked", systemImage: "xmark.circle") { self.nextDocument = nil }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .font(.caption)
                }
                HStack {
                    if api != nil {
                        Button(web ? "Nettet er valgt" : "Brug nettet", systemImage: "globe") {
                            web.toggle()
                            if web { nextDocument = nil }
                        }
                            .tint(web ? palette.cyan : palette.secondary)
                    }
                    Button(answerAsCard ? "Kort valgt" : "Svar som kort", systemImage: "rectangle.on.rectangle") { answerAsCard.toggle() }
                        .tint(answerAsCard ? palette.cyan : palette.secondary)
                }
                .font(.caption)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Skriv til \(bot.name)…", text: $draft, axis: .vertical)
                    .lineLimit(1...4).frame(minHeight: 44)
                    .textFieldStyle(.plain).padding(.horizontal, 12)
                    .focused($composerFocused)
                if composerFocused {
                    Button("Skjul tastatur", systemImage: "keyboard.chevron.compact.down") { composerFocused = false }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .fadedGlassSurface()
                }
                if running != nil {
                    Button("Stop svar", systemImage: "stop.fill") { running?.cancel() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Send", systemImage: "arrow.up") { send() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(FadedButtonStyle(kind: .primary))
                        .disabled(cleanDraft.isEmpty || cleanDraft.count > (web ? 500 : 1_200) ||
                                  (currentModel.isEmpty && !shouldCheckGmail(cleanDraft) && chatIntent(cleanDraft) == nil &&
                                   !canAskAboutSharedCalendar(cleanDraft)) ||
                                  whisper.active || whisper.processing)
                }
            }
        }
        .padding(14)
        .background { ChatGlassSurface(radius: 22, colors: source == .pc
            ? [FadedBrand.pc, FadedBrand.blue] : [FadedBrand.mint, FadedColors.purple]) }
        .fadedWorkingBeam(active: running != nil, pc: source == .pc)
        .padding(.horizontal, FadedSpacing.edge).padding(.vertical, 8)
    }

    func loadPCModels() async {
        guard let api, keepHistory else { pcModels = []; if source == .pc { source = .phone }; return }
        do {
            let catalog = try await api.v2Models()
            try Task.checkCancellation()
            pcModels = PCModelSelection.installed(in: catalog).filter(PCModelSelection.usable)
                .map { Model(id: $0.id, title: $0.label) }
            selectedPCModel = pcModels.contains { $0.id == rememberedPCModel } ? rememberedPCModel : (pcModels.first?.id ?? "")
            if !startsOnPhone, !pcModels.isEmpty, rememberedSource == Source.pc.rawValue { source = .pc }
        } catch {
            if !Task.isCancelled { pcModels = []; if source == .pc { source = .phone } }
        }
    }

    func edit(_ turn: PrivateChatTurn) {
        guard running == nil else { return }
        guard cleanDraft.isEmpty || cleanDraft == turn.prompt else {
            notice = "Gem eller send din nuværende kladde, før du redigerer en tidligere besked."
            return
        }
        draft = turn.prompt
        composerFocused = true
    }

    @ViewBuilder func retryMenu(_ turn: PrivateChatTurn) -> some View {
        Menu("Prøv med en anden model", systemImage: "arrow.clockwise") {
            Section("iPhone") {
                ForEach(models) { model in
                    Button(model.title) { send(message: turn.prompt, source: .phone, model: model.id) }
                }
            }
            if !pcModels.isEmpty {
                Section("PC") {
                    ForEach(pcModels) { model in
                        Button(model.title) { send(message: turn.prompt, source: .pc, model: model.id) }
                    }
                }
            }
        }
        .disabled(running != nil || !cleanDraft.isEmpty)
    }

}
