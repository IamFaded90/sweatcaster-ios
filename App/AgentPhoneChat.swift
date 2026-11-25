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
    @State var attachedPhoto: Data?
    @State var loadingPhoto = false
    @State var sentPhotos: [UUID: Data] = [:]
    @FocusState var composerFocused: Bool
    @State var notice: String?
    @State var running: Task<Void, Never>?
    @State var pendingPrompt: String?
    @State var showModels = false
    @State var showOfflineSetup = false
    @State var showPhoneConnections = false
    @State var startOfflineAfterSetup = false
    @State var showEverydayTools = false
    @State var showAgentShortcuts = false
    @State var selectedAgentShortcut: (() -> Void)?
    @State var interactiveTool: AgentInteractiveTool?
    @State var showTasteChoices = false
    @State private var showPCTools = false
    @State var showDocuments = false
    @State var nextDocument: AgentDocument?
    @State var showTranscript = false
    @State var showRecordingTranscript = false
    @State var translating: PrivateChatTurn?
    @State var gmailDraft: PrivateChatTurn?
    @State var gmailCheck: AgentGmailCheck.Request?
    @State var openAgentAction: UUID?
    @State var agentActionRefresh = UUID()
    @State var instagramPlanRequest: AgentInstagramPlanChange?
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
            persistedConversation
        }
    }

    private var conversationScroll: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    AgentSpeakingStage(bot: bot, listening: appleDictation.active || whisper.active, api: api)
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
    }

    private var conversationScreen: some View {
        conversationScroll
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle(bot.name + " · Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { conversationToolbar }
    }

    @ToolbarContentBuilder private var conversationToolbar: some ToolbarContent {
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
        if keepHistory {
            ToolbarItem(placement: .topBarTrailing) { agentActionShortcuts.labelStyle(.iconOnly) }
        }
        if api != nil && keepHistory {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Agentens PC-værktøjer", systemImage: "desktopcomputer") { showPCTools = true }
                    .disabled(running != nil)
            }
        }
    }

    private var conversationTools: some View {
        conversationScreen
            .sheet(isPresented: $showAgentShortcuts, onDismiss: runSelectedAgentShortcut) {
                agentShortcutsSheet
            }
            .sheet(isPresented: $showPCTools) {
                if let api { AgentPCToolsView(api: api, botID: bot.id) }
            }
            .sheet(item: $interactiveTool, onDismiss: {
                if keepHistory, running == nil {
                    let savedImages = Set(MigratedAppData.shared.regularStudioTurns()
                        .filter { $0.botID == bot.id && $0.imageName != nil }.map(\.id))
                    turns.removeAll { $0.imageName != nil && !savedImages.contains($0.id) }
                }
            }) { tool in interactiveToolSheet(tool) }
            .confirmationDialog("Hvad skal vi finde til " + bot.name + "?", isPresented: $showTasteChoices,
                                titleVisibility: .visible) {
                tasteChoices
                Button("Annuller", role: .cancel) {}
            }
            .sheet(isPresented: $showEverydayTools) { everydayToolsSheet }
            .sheet(isPresented: $showModels, onDismiss: {
                loadModels(preferSetting: preferredModel != modelBeforeSettings)
            }) { PhoneModelsView() }
            .sheet(isPresented: $showDocuments) {
                AgentDocumentsView(bot: bot, api: api, answersOnPC: source == .pc) { document in
                    nextDocument = document
                    web = false
                } onRemove: { id in
                    if nextDocument?.id == id { nextDocument = nil }
                }
            }
    }

    @ViewBuilder private func interactiveToolSheet(_ tool: AgentInteractiveTool) -> some View {
        switch tool {
        case .dayPlan: DayPlanView(bot: bot)
        case .scanDocument: DocumentScanView(bot: bot, model: selectedModel)
        case .audioJournal: AudioJournalView(bot: bot, model: selectedModel)
        case .capture: CaptureReviewView(bot: bot, model: selectedModel) { receipt in addAgentAction("Fang og følg op", kind: .workflow("Kilde og opfølgning"), receipt: receipt, source: "iPhone") }
        case .memory(let sources): AgentMemoryView(bot: bot, highlighted: sources)
        case .localCode(let query):
            AgentLocalCodeView(bot: bot, model: selectedModel, initial: query) { receipt in addAgentAction("Lokal kode", kind: .workflow("Lokalt værktøj"), receipt: receipt, source: "iPhone") }
        case .skills:
            AgentSkillsView(bot: bot) { receipt in addAgentAction("Valgt kontakt", kind: .workflow("Telefonværktøjer"), receipt: receipt, source: "iPhone") }
        case .contacts(let query):
            AgentContactsView(bot: bot, initialQuery: query) { receipt in addAgentAction("Valgt kontakt", kind: .workflow("Telefonværktøjer"), receipt: receipt, source: "iPhone") }
        case .browser(let task):
            AgentBrowserView(bot: bot, model: selectedModel, initialTask: task) { receipt in
                draft = ""
                addAgentAction("Agentbrowser", kind: .workflow("Arbejde i browseren"), receipt: receipt, source: "iPhone")
            }
        case .cameraGuide(let question, let photo):
            CameraGuideView(bot: bot, api: api, model: selectedModel, initialQuestion: question, initialPhoto: photo) { receipt in
                attachedPhoto = nil; draft = ""
                addAgentAction("Kamerahjælp", kind: .workflow("Kamerahjælp"), receipt: receipt, source: "Foto")
            }
        case .personalSearch(let query): PersonalHubSearchView(bot: bot, model: selectedModel, query: query)
        case .creative(let project): CreativeProjectView(bot: bot, model: selectedModel, initial: project)
        case .taskJourney:
            AgentTaskJourneyView(bot: bot, model: selectedModel, api: api) { receipt, _ in
                addAgentAction("Tag dig af min retursag", kind: .workflow("Retur og opfølgning"), receipt: receipt, source: "iPhone")
            }
        case .personality: AgentPersonalityView(bot: bot)
        case .mystery: VillageMysteryView()
        case .musicMix: MusicMixView()
        case .ambience: VillageAmbienceView(scene: "village", title: "landsbyen")
        case .caseTracker:
            CaseTrackerView(bot: bot, api: api, model: selectedModel) { receipt in
                addAgentAction("Følg sagen til dørs", kind: .workflow("Sagsopfølgning"), receipt: receipt, source: "iPhone")
            }
        case .songStudio(let initial): SongStudioView(api: api, initial: initial)
        case .productHunt(let query, let photo):
            ProductHuntView(bot: bot, api: api, model: selectedModel, query: query, photo: photo) { receipt in
                attachedPhoto = nil
                addAgentAction("Find fra et billede", kind: .workflow("Produktfund"), receipt: receipt, source: "Web")
            }
        case .evening(let request):
            EveningPlanView(initial: request) { kind in
                interactiveTool = nil; dismiss(); FadedHubRoute.open(kind)
            }
        case .images(let prompt, let reference):
            AgentImageWorkbench(bot: bot, api: api, prompt: prompt, reference: reference) { turn in
                turns.append(turn)
                draft = ""
                attachedPhoto = nil
            }
        case .workspace(let kind, let prompt):
            AgentWorkspaceView(bot: bot, api: api, model: selectedModel, initialKind: kind, initialPrompt: prompt) { document in
                nextDocument = document
                if source == .composio { source = .phone }
                interactiveTool = nil
                notice = "Filen er vedhæftet. Skriv, hvad du vil bruge den til."
            }
        case .milestone(let kind, let prompt):
            milestoneSheet(kind, prompt: prompt)
        case .appointmentChange(let prompt):
            AgentAppointmentChange(api: api, prompt: prompt) { receipt, link in
                addAgentAction(prompt, kind: .workflow("Flyttet aftale"), receipt: receipt, link: link)
            }
        case .gmailCleanup(let prompt):
            AgentGmailCleanup(api: api, bot: bot, prompt: prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("Mailoprydning"), receipt: receipt, source: "PC")
            }
        case .pcRepair(let prompt):
            AgentPCRepair(api: api, initialPrompt: prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("Billedmotor på PC"), receipt: receipt, source: "PC")
            }
        case .agentComputer(let goal):
            NavigationStack {
                let roster = (try? MigratedAppData.shared.loadBots().get()) ?? []
                BotComputerView(bot: bot, roster: roster, api: api, initialPrompt: goal)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { interactiveTool = nil } } }
            }
        case .phoneScreen(let prompt):
            AgentScreenShareView(api: api, bot: bot, prompt: prompt) { image, question in
                attachedPhoto = image
                draft = AgentScreenIntent.draftForScreenshot(question, current: draft)
            }
        case .sales(let prompt):
            AgentSalesView(api: api, bot: bot, prompt: prompt)
        case .surprise(let prompt):
            VillageSurprisesView(api: api, bot: bot, prompt: prompt)
        case .builtTools(let prompt):
            if let api {
                NavigationStack {
                    AgentBuiltTools(api: api, initialBrief: prompt, buildsOnOpen: !prompt.isEmpty)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { interactiveTool = nil } } }
                }
            }
            else { ContentUnavailableView("Forbind PC’en", systemImage: "desktopcomputer") }
        case .window(let prompt):
            AgentWindowHelp(api: api, botName: bot.name, prompt: prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("PC-opgave"), receipt: receipt, source: "PC")
            }
        case .taste(let target, let kind):
            AgentTasteTest(bot: target, api: api, kind: kind)
        }
    }

    private var everydayToolsSheet: some View {
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

    private var loadedConversation: some View {
        conversationTools
            .onChange(of: source) { if source == .composio { nextDocument = nil } }
            .task {
                loadModels()
                if !loaded && keepHistory {
                    turns = MigratedAppData.shared.regularStudioTurns().filter { $0.botID == bot.id }
                    draft = MigratedAppData.shared.chatDraft(draftKey)
                    if let opensAction, turns.contains(where: { $0.id == opensAction }) { openAgentAction = opensAction }
                }
                loaded = true
            }
            .task(id: api?.queueTargetID) {
                await loadPCModels()
                await selectRequestedAdamVoiceIfAvailable()
            }
            .task(id: instagramPollingID) { await monitorInstagramReports() }
            .task(id: gmailCheck?.id) { await gmailCheck?.run(bot: bot, api: api) }
    }

    private var observedConversation: some View {
        loadedConversation
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
    }

    private var persistedConversation: some View {
        observedConversation
            .sheet(isPresented: $showOfflineSetup, onDismiss: {
                loadModels()
                if startOfflineAfterSetup {
                    startOfflineAfterSetup = false
                    startHandsFree(offline: true)
                }
            }) {
                OfflineAgentSetup(bot: bot, model: Binding(get: { selectedModel }, set: {
                    selectedModel = $0; rememberedModel = $0
                }), voice: $voiceOverride, language: $dictationLanguage, api: api) { startOfflineAfterSetup = true }
            }
            .sheet(isPresented: $showPhoneConnections) { AgentPhoneConnections(api: api) }
            .sheet(isPresented: $showVoice) { voiceSettings }
            .sheet(isPresented: $showTranscript) { AgentDictationTranscript(segments: whisper.segments) }
            .sheet(isPresented: $showRecordingTranscript) {
                if let api { AgentRecordingTranscript(api: api, language: AgentWhisper.languageCode(dictationLanguage)) }
            }
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
        if let photo = sentPhotos[turn.id] { attachedPhoto = photo }
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
