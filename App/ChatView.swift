// Chat screen state, navigation and the primary transcript layout.

import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct ChatView: View {
    struct RemovedTurn {
        let turn: ChatTurn
        let index: Int
        let expiresAt: ContinuousClock.Instant
    }

    enum ReplySource: String, CaseIterable {
        case phone = "Telefon"
        case pc = "PC"
        case grok = "Grok"

        var icon: String {
            switch self {
            case .phone: "iphone"
            case .pc: "desktopcomputer"
            case .grok: "cloud"
            }
        }
    }

    struct ManualRoute {
        let source: ReplySource
        let modelID: String?
    }

    struct ResolvedRoute {
        let source: ReplySource
        let modelID: String?
        let automatic: ModelRouter.Selection?
    }

    @Environment(\.fadedPalette) var palette
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) private var chatTypeSize
    let api: (any ChatAPI)?
    let demo: Bool
    let initialDraft: String
    let connection: String
    let storageKey: String
    let onBack: (() -> Void)?
    let openImageStudio: ((String) -> Void)?
    let openPrivateStudio: (() -> Void)?
    let pcTargetAddress: String?
    let pcQueueTargetID: String?
    let pcConnectionError: APIError?
    let reconnectPC: (() -> Void)?
    let initialSearch: String
    @State var sessionID = UUID()
    @State var draft = ""
    @AppStorage var savedDraft: String
    @State var turns: [ChatTurn] = []
    @State var status: String?
    @State var streamedText = ""
    @State var task: Task<Void, Never>?
    @State var busyPCTurn: UUID?
    @State var searchSteps: [String] = []
    @State var loaded = false
    var notes: String { MigratedAppData.shared.notes }
    @State var sourceExcerpt: String?
    @State var models: [V2Models.Entry] = []
    @State var selectedModel = ""
    @State var pcDefaultModelID = ""
    @State var manualRoute: ManualRoute?
    @State var inFlightAutoRoute: ModelRouter.Selection?
    @State var cloudKeyAvailable = CloudModelKey.exists()
    @State var replySource = ReplySource.phone
    @State var modelsLoading = true
    @State var modelsError: String?
    @State var legacyChat = false
    @State var completedReplies = 0
    @AppStorage(AppStorageKeys.phoneModel) var phoneModel = "apple"
    @AppStorage(AppStorageKeys.phoneModelFavorites) var phoneFavorites = ""
    @AppStorage(AppStorageKeys.chatAutoModelRouter) var autoRouterEnabled = false
    @State var phoneBatteryLevel = UIDevice.current.batteryLevel
    @State var dictation = ChatDictation()
    @StateObject private var speechBox = SpeechBox()
    private var speech: AVSpeechSynthesizer { speechBox.synthesizer }
    @AppStorage(AppStorageKeys.chatVoiceMode) var voiceMode = false
    @AppStorage(AppStorageKeys.chatVoiceBot) private var voiceBotID = ""
    @AppStorage(AppStorageKeys.chatVoiceLanguage) private var preferredVoiceLanguage = "da-DK"
    @AppStorage(AppStorageKeys.chatVoiceIdentifier) private var preferredVoiceID = ""
    private var voiceBotData: Data { MigratedAppData.shared.villageBots }
    @FocusState var composerFocused: Bool
    @State var chatSearch = ""
    @State var archivedTurns: [ChatTurn] = []
    @State var favoritesOnly = false
    @State var scrollRequest = 0
    @State var showComposerTools = false
    @State var choosingNote = false
    @State var newNote = ""
    @State var attachedNote: String?
    @State var attachedQuote: String?
    @State var noteDestination: ReplySource?
    @State var quoteDestination: ReplySource?
    @State var imageHandoff: String?
    @State var privateHandoff = false
    @State var removedTurns: [RemovedTurn] = []
    @State var outboxEntries: [PCChatOutbox.Entry] = []
    @State var activeOutboxIDs = Set<UUID>()
    @State var chatNotice: String?
    @AppStorage(AppStorageKeys.aiTone) var aiTone = "Naturlig"
    @AppStorage(AppStorageKeys.aiLength) var aiLength = "Kort"
    @AppStorage(AppStorageKeys.aiLanguage) var aiLanguage = "Dansk"
    @AppStorage(AppStorageKeys.aiCreativity) var aiCreativity = "Balanceret"
    @AppStorage(AppStorageKeys.aiBullets) var aiBullets = false
    @AppStorage(AppStorageKeys.aiExamples) var aiExamples = false
    @AppStorage(AppStorageKeys.aiSummary) var aiSummary = false
    @AppStorage(AppStorageKeys.aiActions) var aiActions = false
    @AppStorage(AppStorageKeys.aiClarify) var aiClarify = true
    @AppStorage(AppStorageKeys.aiSimple) var aiSimple = true
    @AppStorage(AppStorageKeys.aiNoJargon) var aiNoJargon = true
    @AppStorage(AppStorageKeys.aiSteps) var aiSteps = false
    @AppStorage(AppStorageKeys.aiTables) var aiTables = false
    @AppStorage(AppStorageKeys.aiUncertainty) var aiUncertainty = true
    @AppStorage(AppStorageKeys.aiCounterpoint) var aiCounterpoint = false
    @AppStorage(AppStorageKeys.aiAssumptions) var aiAssumptions = false
    @AppStorage(AppStorageKeys.aiSources) var aiSources = false
    @AppStorage(AppStorageKeys.aiCodeComments) var aiCodeComments = true
    @AppStorage(AppStorageKeys.aiPreserveNames) var aiPreserveNames = true
    @AppStorage(AppStorageKeys.aiEmojis) var aiEmojis = false
    @AppStorage(AppStorageKeys.aiHeadings) var aiHeadings = true
    @AppStorage(AppStorageKeys.aiRecapQuestion) var aiRecapQuestion = false
    @AppStorage(AppStorageKeys.aiSuggestions) var aiSuggestions = true
    @AppStorage(AppStorageKeys.aiRisks) var aiRisks = false
    @AppStorage(AppStorageKeys.aiProsCons) var aiProsCons = false
    @AppStorage(AppStorageKeys.aiChecklist) var aiChecklist = false
    @AppStorage(AppStorageKeys.aiTimestamps) var aiTimestamps = false
    @AppStorage(AppStorageKeys.aiWordCount) var aiWordCount = false
    @AppStorage(AppStorageKeys.aiShowTools) var aiShowTools = true
    @AppStorage(AppStorageKeys.qolReduceMotion) var calmMotion = false

    init(api: (any ChatAPI)?, demo: Bool, initialDraft: String, connection: String, storageKey: String,
         onBack: (() -> Void)? = nil, openImageStudio: ((String) -> Void)? = nil,
         pcTargetAddress: String? = nil, pcQueueTargetID: String? = nil,
         pcConnectionError: APIError? = nil, reconnectPC: (() -> Void)? = nil,
         initialSearch: String = "", openPrivateStudio: (() -> Void)? = nil) {
        self.api = api
        self.demo = demo
        self.initialDraft = initialDraft
        self.connection = connection
        self.storageKey = storageKey
        self.onBack = onBack
        self.openImageStudio = openImageStudio
        self.openPrivateStudio = openPrivateStudio
        self.pcTargetAddress = pcTargetAddress
        self.pcQueueTargetID = pcQueueTargetID
        self.pcConnectionError = pcConnectionError
        self.reconnectPC = reconnectPC
        self.initialSearch = initialSearch
        _savedDraft = AppStorage(wrappedValue: "", AppStorageKeys.chatDraft(storageKey))
    }

    private var voiceBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: voiceBotData)) ?? []
    }

    private var voiceControls: some View {
        DisclosureGroup("Oplæsning på telefonen") {
            Toggle("Læs færdige svar op", isOn: $voiceMode)
            if !voiceBots.isEmpty {
                Picker("Botstemme", selection: $voiceBotID) {
                    Text("Valgt telefonstemme").tag("")
                    ForEach(voiceBots) { bot in Text(bot.name).tag(bot.id.uuidString) }
                }
            }
            if voiceBots.first(where: { $0.id.uuidString == voiceBotID }) == nil {
                Picker("Oplæsningssprog", selection: $preferredVoiceLanguage) {
                    Text("Dansk").tag("da-DK")
                    Text("Engelsk").tag("en-US")
                }
                .onChange(of: preferredVoiceLanguage) { preferredVoiceID = "" }
                let voices = LocalSpeechVoice.options(language: preferredVoiceLanguage)
                Picker("Telefonstemme", selection: $preferredVoiceID) {
                    Text("Bedste tilgængelige").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(LocalSpeechVoice.label(voice)).tag(voice.identifier)
                    }
                }
            }
            Button("Stop oplæsning") { speech.stopSpeaking(at: .immediate) }
                .frame(minHeight: 44)
        }
    }

    func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let bot = voiceBots.first { $0.id.uuidString == voiceBotID }
        utterance.voice = LocalSpeechVoice.resolve(identifier: bot?.voice ?? preferredVoiceID,
                                                   language: bot?.language ?? preferredVoiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(bot?.voiceRate ?? 1)
        speech.speak(utterance)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                chatContent(userBubbleWidth: max(1, (geometry.size.width - 32) * 0.8))
            }
            .background { FadedBackground() }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(palette.isDark ? palette.lime : palette.text)
    }

    private func chatContent(userBubbleWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            chatHeading
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                        if !outboxEntries.isEmpty { outboxPanel }
                        TextField("Søg i alle samtaler", text: $chatSearch)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .onChange(of: chatSearch) { old, new in
                                if old.isEmpty && !new.isEmpty { archivedTurns = ChatArchive.turns() }
                                if new.isEmpty { archivedTurns = [] }
                            }
                        DisclosureGroup("Chatindstillinger") {
                            VStack(alignment: .leading, spacing: 12) {
                                StatsBar(turns: turns.count, streaming: task != nil)
                                if effectiveReplySource == .pc { modelControls }
                                if effectiveReplySource == .grok && !demo { CloudModelSettings() }
                                voiceControls
                                aiBoostControls
                                if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                                Text("Researcher bruger internettet, når en websøgning er nødvendig.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Toggle("Vis kun favoritter", isOn: $favoritesOnly)
                                ShareLink(item: conversationText) {
                                    Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                                        .frame(minHeight: 44)
                                }.disabled(turns.isEmpty)
                            }.padding(.top, 8)
                        }
                        if chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if turns.isEmpty && task == nil {
                                FadedEmptyState(icon: "bubble.left", title: "Start en samtale", detail: "Vælg en kilde, og skriv din besked.")
                            } else if favoritesOnly && !turns.contains(where: { $0.favorite == true }) && task == nil {
                                FadedEmptyState(icon: "star", title: "Ingen favoritter i samtalen",
                                                detail: "Markér et svar som favorit via menuen ved svaret.",
                                                actionTitle: "Vis alle beskeder") { favoritesOnly = false }
                            }
                            transcriptRows(userBubbleWidth: userBubbleWidth)
                        } else { globalSearchRows }
                        if aiShowTools && !searchSteps.isEmpty {
                            DisclosureGroup("Agentaktivitet · \(searchSteps.count) trin") {
                                ForEach(searchSteps.indices, id: \.self) { index in
                                    Label(searchSteps[index], systemImage: index + 1 == searchSteps.count ? "circle.fill" : "arrow.down.circle")
                                }
                            }
                        }
                        if let status, task != nil { AgentToolWave(status: status) }
                        if task != nil && streamedText.isEmpty { LoadingSkeleton(label: "Venter på AI…") }
                        if let sourceExcerpt {
                            DisclosureGroup("Lokal reference · Notes") {
                                Text(sourceExcerpt)
                                Text("Fundet på telefonen. Referencen blev ikke sendt til PC’en.")
                                    .font(.caption)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(FadedSpacing.edge)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: turns.count) { scrollChat(proxy) }
                .onChange(of: streamedText) { scrollChat(proxy) }
                .onChange(of: scrollRequest) { scrollChat(proxy) }
                .onChange(of: effectiveReplySource) {
                    attachedNote = nil
                    attachedQuote = nil
                }
                .onChange(of: draft) { _, value in
                    if loaded { savedDraft = value }
                }
                .safeAreaInset(edge: .bottom) { composer }
                .onAppear {
                    phoneBatteryLevel = UIDevice.current.batteryLevel
                    cloudKeyAvailable = CloudModelKey.exists()
                    guard !loaded else { return }
                    loaded = true
                    UserDefaults.standard.removeObject(forKey: AppStorageKeys.aiPrivate)
                    let localModelID = PhoneModels.effectiveModelID(phoneModel)
                    let localReady = localModelID == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(localModelID) != nil
                    if api != nil && !localReady && !demo { replySource = .pc }
                    loadHistory()
                    draft = initialDraft.isEmpty ? savedDraft : initialDraft
                    chatSearch = initialSearch
                    reloadOutbox()
                    if initialSearch.isEmpty { scrollChat(proxy) }
                }
                .onDisappear { stop(); dictation.stop(); speech.stopSpeaking(at: .immediate) }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                    phoneBatteryLevel = UIDevice.current.batteryLevel
                }
                .onReceive(NotificationCenter.default.publisher(for: CloudModelKey.didChange)) { _ in
                    cloudKeyAvailable = CloudModelKey.exists()
                }
                .onReceive(NotificationCenter.default.publisher(for: PCChatOutbox.didChange)) { _ in reloadOutbox() }
                .onChange(of: pcQueueTargetID) { reloadOutbox() }
                .onChange(of: task != nil) { _, active in if !active { reloadOutbox() } }
                .task(id: (api as? LiveAPI)?.queueTargetID) { await loadModels() }
                .sensoryFeedback(.success, trigger: completedReplies)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Tilbage", systemImage: "chevron.left", action: goBack)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ny samtale", systemImage: "square.and.pencil") { newConversation() }
                    .disabled(task != nil)
            }
        }
        .sheet(isPresented: $showComposerTools, onDismiss: finishComposerTools) { composerToolsSheet }
        .task(id: removedTurns.last?.turn.id) { await expireUndo() }
    }

    private var chatHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chatTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    chatTitle
                    quickModelPicker
                }
            } else {
                HStack {
                    chatTitle
                    Spacer(minLength: 8)
                    quickModelPicker
                }
            }
            HStack {
                Text(connection).font(.subheadline).foregroundStyle(palette.secondary)
                Spacer(minLength: 8)
                if openPrivateStudio != nil {
                    Button("Privat", systemImage: "lock.shield", action: goToPrivateStudio)
                        .frame(minHeight: 44).disabled(task != nil)
                        .accessibilityHint("Åbner privat chat på telefonen")
                }
            }
            if !demo { sourcePicker }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FadedSpacing.edge).padding(.bottom, 8)
        .foregroundStyle(palette.text)
    }

    private var chatTitle: some View {
        Text("AI-chat").font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var quickModelPicker: some View {
        if effectiveReplySource == .pc && !models.isEmpty {
            Menu {
                ForEach(models) { entry in
                    Button(entry.label) { chooseSource(.pc, modelID: entry.id) }
                }
            } label: {
                Label(models.first(where: { $0.id == effectivePCModelID })?.label ?? "Model", systemImage: "chevron.down")
                    .font(.caption.bold()).lineLimit(chatTypeSize.isAccessibilitySize ? nil : 1)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            }
            .disabled(task != nil)
            .accessibilityLabel("Skift PC-model")
            .accessibilityValue(models.first(where: { $0.id == effectivePCModelID })?.label ?? "Ingen model valgt")
        }
    }
}
