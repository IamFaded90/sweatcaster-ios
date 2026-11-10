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

    struct DroppedPhoto: Identifiable {
        let id = UUID()
        let data: Data
        let preview: UIImage
    }

    struct ResolvedRoute {
        let source: ReplySource
        let modelID: String?
        let automatic: ModelRouter.Selection?
    }

    @Environment(\.fadedPalette) var palette
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var chatTypeSize
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
    private let preferPhone: Bool
    private let embedded: Bool
    private let newConversationRequest: UUID?
    private let onConsumeNewConversation: (() -> Void)?
    private let openBots: (() -> Void)?
    private let onConsumeSearch: (() -> Void)?
    private let onConsumePhonePreference: (() -> Void)?
    private let onComposerFocusChange: ((Bool) -> Void)?
    @Environment(\.horizontalSizeClass) private var chatSizeClass
    @Environment(\.scenePhase) var chatScenePhase
    @State private var showHistory = false
    @State private var showChatSettings = false
    @State private var handledNewConversation: UUID?
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
    @State var replySource: ReplySource?
    @State var modelsLoading = true
    @State var modelsError: String?
    @State var legacyChat = false
    @State var pcEngineOffline = false
    @State var completedReplies = 0
    @AppStorage(AppStorageKeys.phoneModel) var phoneModel = "apple"
    @AppStorage(AppStorageKeys.phoneModelFavorites) var phoneFavorites = ""
    @AppStorage(AppStorageKeys.chatAutoModelRouter) var autoRouterEnabled = false
    @State var phoneBatteryLevel = UIDevice.current.batteryLevel
    @State var dictation = ChatDictation()
    @StateObject var speechBox = SpeechBox()
    @AppStorage(AppStorageKeys.chatVoiceMode) var voiceMode = false
    @AppStorage(AppStorageKeys.chatVoiceBot) var voiceBotID = ""
    @AppStorage(AppStorageKeys.chatVoiceLanguage) var preferredVoiceLanguage = "da-DK"
    @AppStorage(AppStorageKeys.chatVoiceIdentifier) var preferredVoiceID = ""
    @AppStorage(AppStorageKeys.chatVoiceRate) var preferredVoiceRate = 1.0
    @State var availableVoiceRevision = 0
    @FocusState var composerFocused: Bool
    @State var chatSearch = ""
    @State var archivedSessions: [SavedAgentSession] = []
    @State var favoritesOnly = false
    @State var scrollRequest = 0
    @State private var messageJumpID: UUID?
    @State var showComposerTools = false
    @State var showPhoneModelSetup = false
    @State var showPCModelSetup = false
    @State var stagedPhoto: DroppedPhoto?
    @State private var droppedPhoto: DroppedPhoto?
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
    @State var outboxRetryID: UUID?
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
         initialSearch: String = "", openPrivateStudio: (() -> Void)? = nil, preferPhone: Bool = false,
         embedded: Bool = false, newConversationRequest: UUID? = nil, onConsumeNewConversation: (() -> Void)? = nil,
         openBots: (() -> Void)? = nil, onConsumeSearch: (() -> Void)? = nil, onConsumePhonePreference: (() -> Void)? = nil,
         onComposerFocusChange: ((Bool) -> Void)? = nil) {
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
        self.initialSearch = FadedSearchIndex.boundedQuery(initialSearch)
        self.preferPhone = preferPhone
        self.embedded = embedded
        self.newConversationRequest = newConversationRequest
        self.onConsumeNewConversation = onConsumeNewConversation
        self.openBots = openBots
        self.onConsumeSearch = onConsumeSearch
        self.onConsumePhonePreference = onConsumePhonePreference
        self.onComposerFocusChange = onComposerFocusChange
        _savedDraft = AppStorage(wrappedValue: "", AppStorageKeys.chatDraft(storageKey))
    }

    var body: some View {
        Group {
            if embedded {
                chatLayout
            } else {
                NavigationStack {
                    chatLayout.toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .tint(palette.isDark ? palette.lime : palette.text)
        .sheet(isPresented: $showPhoneModelSetup) { PhoneModelsView() }
        .sheet(isPresented: $showPCModelSetup, onDismiss: { Task { await loadModels() } }) {
            NavigationStack {
                PCModelsView(api: api as? LiveAPI) { model in
                    models.removeAll { $0.id == model.id }
                    models.append(model)
                    selectedModel = model.id
                    chooseModelForNextMessage(.pc, modelID: model.id)
                    showPCModelSetup = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Luk") { showPCModelSetup = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showChatSettings) { chatSettingsSheet }
        .sheet(isPresented: $showComposerTools, onDismiss: finishComposerTools) { composerToolsSheet }
        .sheet(item: $droppedPhoto) { photo in
            LocalImageAnalysisView(data: photo.data, onChooseNote: attachPhotoExcerpt, api: api as? LiveAPI)
        }
        .onChange(of: sessionID) { stagedPhoto = nil; messageJumpID = nil }
        .task(id: removedTurns.last?.turn.id) { await expireUndo() }
    }

    private var chatLayout: some View {
        GeometryReader { geometry in
            let wide = chatSizeClass == .regular && geometry.size.width >= 740
            let sidebarWidth: CGFloat = 300
            let width = geometry.size.width - (wide ? sidebarWidth : 0)
            HStack(spacing: 0) {
                if wide {
                    historySidebar.frame(width: sidebarWidth)
                    Divider()
                }
                chatContent(userBubbleWidth: max(1, (width - 32) * 0.8), wide: wide)
            }
            .sheet(isPresented: Binding(
                get: { showHistory && !wide }, set: { showHistory = $0 }
            )) {
                NavigationStack {
                    historySidebar
                        .navigationTitle("Samtaler")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Luk") { showHistory = false }
                            }
                        }
                }
            }
        }
        .background { FadedBackground() }
    }

    private var historySidebar: some View {
        ChatSidebarView(query: $chatSearch, sessions: historySessions, selectedID: sessionID,
                        isBusy: task != nil, activeTurns: turns) {
            let previous = sessionID
            newConversation()
            if sessionID != previous { showHistory = false }
        } select: { session in
            if openConversation(session) { showHistory = false }
        } jumpToTurn: { id in
            favoritesOnly = false
            showHistory = false
            messageJumpID = id
        }
    }

    private func chatContent(userBubbleWidth: CGFloat, wide: Bool) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                chatHeading(wide: wide) {
                    withAnimation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo("chat-outbox", anchor: .top)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                        if !outboxEntries.isEmpty { outboxPanel.id("chat-outbox") }
                        if turns.isEmpty && task == nil {
                            FadedEmptyState(icon: "bubble.left", title: "Start en samtale", detail: "Vælg en kilde, og skriv din besked.",
                                            actionTitle: "Skriv en besked") { composerFocused = true }
                        } else if favoritesOnly && !turns.contains(where: { $0.favorite == true }) && task == nil {
                            FadedEmptyState(icon: "star", title: "Ingen favoritter i samtalen",
                                            detail: "Markér et svar som favorit via menuen ved svaret.",
                                            actionTitle: "Vis alle beskeder") { favoritesOnly = false }
                        }
                        transcriptRows(userBubbleWidth: userBubbleWidth)
                        chatAgentActivity
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
                composer.layoutPriority(1)
            }
            .onChange(of: composerFocused) { _, focused in
                onComposerFocusChange?(focused)
                if focused { scrollChat(proxy) }
            }
            .onChange(of: turns.count) { scrollChat(proxy) }
            .onChange(of: streamedText) { scrollChat(proxy) }
            .onChange(of: scrollRequest) { scrollChat(proxy) }
            .task(id: messageJumpID) {
                guard let id = messageJumpID else { return }
                await Task.yield()
                guard !Task.isCancelled, messageJumpID == id else { return }
                withAnimation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                messageJumpID = nil
            }
            .onChange(of: effectiveReplySource) {
                if noteDestination != effectiveReplySource { attachedNote = nil }
                if quoteDestination != effectiveReplySource { attachedQuote = nil }
            }
            .onChange(of: draft) { _, value in
                if loaded { savedDraft = value }
            }
            .onAppear {
                prepareConversation()
                consumeEntryRequests()
                scrollChat(proxy)
            }
            .onDisappear {
                onComposerFocusChange?(false)
                stop()
                dictation.stop()
                speechBox.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                phoneBatteryLevel = UIDevice.current.batteryLevel
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudModelKey.didChange)) { _ in
                cloudKeyAvailable = CloudModelKey.exists()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
                Task { @MainActor in availableVoiceRevision += 1 }
            }
            .onChange(of: chatScenePhase) { _, phase in
                if phase == .background { speechBox.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: PCChatOutbox.didChange)) { _ in reloadOutbox() }
            .onChange(of: pcQueueTargetID) { reloadOutbox() }
            .onChange(of: newConversationRequest) { consumeEntryRequests() }
            .onChange(of: initialSearch) { consumeEntryRequests() }
            .onChange(of: preferPhone) { consumeEntryRequests() }
            .onChange(of: task != nil) { _, active in
                if !active { reloadOutbox(); consumeEntryRequests() }
            }
            .task(id: (api as? LiveAPI)?.queueTargetID) { await loadModels() }
            .sensoryFeedback(.success, trigger: completedReplies)
        }
    }

    private func prepareConversation() {
        phoneBatteryLevel = UIDevice.current.batteryLevel
        cloudKeyAvailable = CloudModelKey.exists()
        guard !loaded else { return }
        loaded = true
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.aiPrivate)
        if preferPhone { chooseSource(.phone) }
        loadHistory()
        draft = savedDraft.isEmpty ? initialDraft : savedDraft
        if !savedDraft.isEmpty, !initialDraft.isEmpty, initialDraft != savedDraft {
            attachedQuote = initialDraft
            quoteDestination = effectiveReplySource
        }
        reloadOutbox()
    }

    private func consumeEntryRequests() {
        guard loaded else { return }
        if !initialSearch.isEmpty {
            chatSearch = initialSearch
            refreshHistorySessions()
            showHistory = true
            onConsumeSearch?()
        }
        guard task == nil else { return }
        if let request = newConversationRequest, handledNewConversation != request {
            handledNewConversation = request
            newConversation()
            onConsumeNewConversation?()
        }
        if preferPhone {
            chooseSource(.phone)
            onConsumePhonePreference?()
        }
    }

    private func chatHeading(wide: Bool, revealOutbox: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            HStack(spacing: FadedSpacing.xs) {
                if !embedded || onBack != nil {
                    headerButton("Tilbage", icon: "chevron.left", action: goBack)
                }
                chatTitle
                Spacer(minLength: FadedSpacing.xs)
                if composerFocused {
                    headerButton("Skjul tastatur", icon: "keyboard.chevron.compact.down") {
                        composerFocused = false
                    }
                } else {
                    if !wide {
                        headerButton("Samtaler og søgning", icon: "sidebar.left") {
                            refreshHistorySessions()
                            showHistory = true
                        }
                        headerButton("Ny samtale", icon: "square.and.pencil") { newConversation() }
                            .disabled(task != nil)
                    }
                    headerButton("Chatindstillinger", icon: "slider.horizontal.3") {
                        showChatSettings = true
                    }
                }
            }
            if !composerFocused {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: FadedSpacing.s) {
                        Text(connection).font(.subheadline).foregroundStyle(palette.secondary)
                        Spacer(minLength: FadedSpacing.xs)
                        quickModelPicker
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(connection).font(.subheadline).foregroundStyle(palette.secondary)
                        quickModelPicker
                    }
                }
                if chatTypeSize.isAccessibilitySize { chatNavigationMenu }
                else {
                    if !demo { sourcePicker }
                    ScrollView(.horizontal) { HStack(spacing: FadedSpacing.m) { chatShortcuts } }
                        .scrollIndicators(.hidden)
                }
                if !outboxEntries.isEmpty {
                    Button(action: revealOutbox) {
                        Label("Udbakke · \(outboxEntries.count)", systemImage: "tray")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
            }
            FadedSignature()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FadedSpacing.edge).padding(.bottom, FadedSpacing.s)
        .foregroundStyle(palette.text)
    }

    private var chatNavigationMenu: some View {
        Menu {
            if !demo {
                ForEach([ReplySource.phone, .pc], id: \.self) { source in
                    Button(source.rawValue, systemImage: source.icon) { chooseSource(source) }.disabled(task != nil)
                }
            }
            chatShortcuts
        } label: {
            Label(demo ? "Genveje" : "\(effectiveReplySource.rawValue) · Genveje", systemImage: "line.3.horizontal")
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder private var chatShortcuts: some View {
        if openPrivateStudio != nil {
            Button("Privat", systemImage: "lock.shield", action: goToPrivateStudio)
                .accessibilityHint("Åbner privat chat på telefonen")
                .frame(minHeight: 44).disabled(task != nil)
        }
        if let openImageStudio {
            Button("Billeder", systemImage: "photo") {
                composerFocused = false
                openImageStudio(draft)
            }
            .frame(minHeight: 44).disabled(task != nil)
        }
        if let openBots {
            Button("Mine bots", systemImage: "person.2") {
                composerFocused = false
                openBots()
            }
            .frame(minHeight: 44).disabled(task != nil)
        }
    }

    private func headerButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: icon, action: action)
            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            .help(label)
    }

    private var chatSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    StatsBar(turns: turns.count, streaming: task != nil)
                    if effectiveReplySource == .pc { modelControls }
                    if !demo { CloudModelSettings() }
                    voiceControls
                    aiBoostControls
                    if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                    FadedDetailText("Researcher bruger internettet, når en websøgning er nødvendig.")
                    Toggle("Vis kun favoritter", isOn: $favoritesOnly)
                    ShareLink(item: conversationText) {
                        Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }.disabled(turns.isEmpty)
                }
                .padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .navigationTitle("Chatindstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Luk") { showChatSettings = false }
                }
            }
        }
    }

    private var chatTitle: some View {
        Text("AI-chat").font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }

    func acceptDroppedPhotos(_ items: [StudioPhotoInput]) -> Bool {
        guard task == nil, droppedPhoto == nil, stagedPhoto == nil else { return false }
        guard items.count == 1, let photo = items.first, let preview = UIImage(data: photo.data) else {
            if items.count > 1 { chatNotice = "Træk ét billede ad gangen." }
            return false
        }
        dictation.stop()
        composerFocused = false
        stagedPhoto = DroppedPhoto(data: photo.data, preview: preview)
        return true
    }

    func analyzeStagedPhoto() {
        guard task == nil, let stagedPhoto else { return }
        composerFocused = false
        droppedPhoto = stagedPhoto
        self.stagedPhoto = nil
    }

    private func attachPhotoExcerpt(_ excerpt: String) {
        guard task == nil else { return }
        attachedNote = excerpt
        noteDestination = effectiveReplySource
        chatNotice = "Tekstuddraget er vedhæftet. Det sendes først, når du trykker Send."
    }
}
