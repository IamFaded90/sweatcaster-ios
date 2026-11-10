// OfflineStudio.swift
// Ejer studiets delte tilstand og sammensætter de tre faner.

import LocalAuthentication
import Network
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct OfflineStudio: View {
    let api: LiveAPI?
    @Binding var sessionUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let ephemeralOnly: Bool
    @State var studioPage: Page
    @State var imagePrompt: String
    @State var pendingBotID: UUID?
    @FocusState var imagePromptFocused: Bool
    @State private var loadingModel = false
    @State var showPromptEditor = false
    @State var editingImagePrompt = false
    @State var importPromptFile = false
    @State var importChatText = false
    @State var privateDeadline: ContinuousClock.Instant?
    @State var privateNetworkOffline: Bool?
    @State var privatePathMonitor: NWPathMonitor?
    @State var privateImageRendering = false
    @State var sessionPreferences = StudioSessionPreferences()
    @State var showSessionNote = false
    @State var sessionNote = ""
    @State var dictation = ChatDictation()
    @State var idleRevision = UUID()
    @State var idleAsleep = false
    @AppStorage(AppStorageKeys.offlineStudioAutoSleepMinutes) var autoSleepMinutes = 5.0
    @AppStorage(AppStorageKeys.offlineStudioPersonalityPreset) var personalityPreset = "bot"
    @AppStorage(AppStorageKeys.offlineStudioVoicePreview) var previewLanguage = "da-DK"
    @AppStorage(AppStorageKeys.offlineStudioVoiceDa) var danishVoiceID = ""
    @AppStorage(AppStorageKeys.offlineStudioVoiceEn) var englishVoiceID = ""
    @AppStorage(AppStorageKeys.offlineStudioChatBackdrop) var backdropData = Data()
    @Environment(\.dismiss) var dismiss
    @Environment(\.fadedPalette) var palette
    @Environment(\.scenePhase) var studioPhase
    @Environment(\.dynamicTypeSize) var studioTypeSize
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(AppStorageKeys.qolHaptics) var studioHaptics = true
    @AppStorage(AppStorageKeys.qolReduceMotion) var calmMotion = false
    @State private var reloadNotice = false
    @AppStorage(AppStorageKeys.offlineStudioEnabled) var enabled = false
    @AppStorage(AppStorageKeys.phoneModel) var textModel = "apple"
    @AppStorage(AppStorageKeys.offlineStudioLora) var loraName = ""
    private var botData: Data { MigratedAppData.shared.villageBots }
    @AppStorage(AppStorageKeys.privateBotId) var privateBotID = ""
    @AppStorage(AppStorageKeys.privateChatPromptsV1) var promptHistoryData = Data()
    @AppStorage(AppStorageKeys.phoneModelLiteBattery) var liteBatteryEnabled = false
    @State var showModels = false
    @State var showBotBuilder = false
    @State var importLoRA = false
    @State var prompt = ""
    @State var answer = ""
    @State var status = ""
    @State var imageURL: URL?
    @State var task: Task<Void, Never>?
    @AppStorage(AppStorageKeys.offlineStudioImageModel) var savedImageModel = "sd_v1.5_f16.ckpt"
    @AppStorage(AppStorageKeys.studioImagesAutoSavePhotos) var autoSaveStudioPhotos = false
    @AppStorage(AppStorageKeys.studioImagesAllowPCFallback) var allowPCFallback = true
    @AppStorage(AppStorageKeys.studioImagesLoraLabels) var loraLabelsData = Data()
    @State var negativeImagePrompt = ""
    @State var pendingImages: [StudioImageRequest] = []
    @State var generatingImages = false
    @State var galleryFilter: StudioGalleryFilter = .all
    @State var galleryTag = ""
    @State var cachedFilteredHistory: [URL] = []
    @State var cachedGalleryTags: [String] = []
    @State var selectedGalleryImages: Set<URL> = []
    @State var selectingGalleryImages = false
    @State var confirmGalleryDelete = false
    @State var galleryIndex = StudioGalleryIndex()
    @State var galleryMutation: UInt64 = 0
    @State var galleryLoadID: UUID?
    @State var galleryHasLoaded = false
    @State var galleryError: String?
    @State var transientDetails: [URL: StudioImageDetails] = [:]
    @State var privateImages: [URL: Data] = [:]
    @State var photosSaving: Set<URL> = []
    @State var pendingPrivatePhoto: StudioMultiShare?
    @State var photoAuthentication: LAContext?
    @State var confirmStudioPanic = false
    @State var panicDeletesDownloads = false
    @State var imageDetailsSheet: StudioImageSheet?
    @State var imageViewer: StudioImageSheet?
    @State var studioShareSheet: StudioMultiShare?
    @State var tagsDraft = ""
    @State var loraPreviewSelection: PhotosPickerItem?
    @State var loraPreviewRefresh = 0
    @AppStorage(AppStorageKeys.offlineStudioImageFavorites) var imageFavoritesData = Data()
    @AppStorage(AppStorageKeys.offlineStudioImageBatteryProtection) var imageBatteryProtection = true
    @State var studioSeed: UInt32?
    @State var makeFourImages = false
    @State var basePhoto: PhotosPickerItem?
    @State var baseImage: Data?
    @State var loadingBaseImage = false
    @State var batchImageURLs: [URL] = []
    @State var batchTurnID: UUID?
    @State var upscaleProgress: Double?
    @State var imageBenchmark: String?
    @State var imageCooling = false
    @State var temporaryImagesID = UUID()
    @State var useLoRA = false
    @State var authenticating = false
    @State var studioAuthentication: LAContext?
    @State var downloadProgress: Double?
    @State var turns: [PrivateChatTurn] = []
    @State var privateReplyIssues: [UUID: String] = [:]
    @State var loaded = false
    @State var chatWorkID: UUID?
    @State var textContextLimit = 2048
    @State var privateBatteryLevel: Float = -1
    @State var voiceLanguages: [UUID: String] = [:]
    @StateObject var speech = SpeechBox()
    @State var pendingImageDeletion: URL?
    @FocusState var promptFocused: Bool

    enum Page: String, CaseIterable, Identifiable {
        case chat = "Chat", images = "Billeder", gallery = "Galleri og indstillinger"
        var id: Self { self }
    }

    init(api: LiveAPI?, sessionUnlocked: Binding<Bool>, onPrivateSessionEnded: @escaping () -> Void = {},
         initialPage: Page? = nil, initialImagePrompt: String = "", initialBotID: UUID? = nil,
         ephemeralOnly: Bool = false) {
        self.api = ephemeralOnly ? nil : api
        _sessionUnlocked = sessionUnlocked
        self.onPrivateSessionEnded = onPrivateSessionEnded
        self.ephemeralOnly = ephemeralOnly
        _studioPage = State(initialValue: initialPage ?? .chat)
        _imagePrompt = State(initialValue: String(initialImagePrompt.prefix(2_000)))
        _pendingBotID = State(initialValue: initialBotID)
    }

    var privateSession: Bool { ephemeralOnly }
    var studioEnabled: Bool { privateSession || enabled }
    var imageModel: String { privateSession ? sessionPreferences.imageModel : savedImageModel }
    var sessionExpired: Bool { privateDeadline.map { $0 <= .now } ?? false }
    var canRenderPrivateImages: Bool {
        privateNetworkOffline == true && privatePathMonitor?.currentPath.status == .unsatisfied
    }
    var privateImageOfflineInstructions: String {
        "Slå flytilstand til og Wi-Fi fra, og gå tilbage til Billeder."
    }

    var historyFolder: URL { URL.applicationSupportDirectory.appending(path: "StudioImages", directoryHint: .isDirectory) }
    var privateImageFolder: URL {
        URL(string: "fadedai-private://studio/\(temporaryImagesID.uuidString)")!
    }
    var privateBots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: botData)) ?? [] }
    var selectedPrivateBot: VillageBot? {
        if ephemeralOnly { return nil }
        return privateBots.first { $0.id.uuidString == privateBotID } ?? privateBots.first
    }

    var currentBotTurns: [PrivateChatTurn] { turns.filter(belongsToCurrentBot) }

    func belongsToCurrentBot(_ turn: PrivateChatTurn) -> Bool {
        if ephemeralOnly { return turn.botID == nil }
        let botID = selectedPrivateBot?.id
        if let owner = turn.botID { return owner == botID }
        return botID == privateBots.first?.id
    }
    var history: [URL] {
        if privateSession { return privateImages.keys.sorted { $0.lastPathComponent > $1.lastPathComponent } }
        return galleryIndex.files
    }

    var body: some View {
        NavigationStack { studioNavigation }
    }

    private var studioChrome: some View {
        studioContent
            .background { FadedBackground(variant: privateSession ? .privateChat : .standard) }
            .navigationTitle(ephemeralOnly ? "NSFW" : (sessionUnlocked ? studioPage.rawValue : "Privat område"))
            .overlay(alignment: .top) {
                if reloadNotice && sessionUnlocked {
                    Text("Lokal model genindlæst for at spare hukommelse")
                        .font(.callout).padding(12)
                            .foregroundStyle(palette.text)
                            .background(palette.card, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 8)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .localModelReloaded)) { _ in reloadNotice = true }
            .task(id: reloadNotice) {
                guard reloadNotice else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                reloadNotice = false
            }
            .task(id: sessionUnlocked && task != nil && studioHaptics && studioPhase == .active) {
                guard sessionUnlocked, task != nil, studioHaptics, studioPhase == .active else { return }
                let feedback = UIImpactFeedbackGenerator(style: .soft)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    if LocalCompute.isRunning && !imageCooling { feedback.impactOccurred(intensity: 0.30) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left") {
                        stopStudioImageQueue()
                        closeChatSession()
                        dismiss()
                    }
                }
                if sessionUnlocked && studioPage == .chat {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Samtale", systemImage: "ellipsis.circle") {
                            Button("Ny samtale", systemImage: "square.and.pencil") { newPrivateConversation() }
                            if privateSession {
                                sessionModelPicker
                                Button("Galleri og indstillinger", systemImage: "gearshape") { studioPage = .gallery }
                            }
                        }
                            .disabled(task != nil)
                    }
                }
            }
    }

    private var studioPresentations: some View {
        studioChrome
            .sheet(isPresented: $showModels, onDismiss: {
                textContextLimit = contextWindow(for: effectiveTextModel)
            }) { PhoneModelsView(allowsImageDownloads: !privateSession) }
            .sheet(isPresented: $showBotBuilder) {
                VillageBotBuilder(api: privateSession ? nil : api, bot: selectedPrivateBot,
                                  onBack: { showBotBuilder = false })
            }
            .fullScreenCover(isPresented: $showPromptEditor) { studioPromptEditor }
            .sheet(item: $imageDetailsSheet) { item in
                if canShowStudio { imageDetailsView(item.url) }
            }
            .sheet(item: $studioShareSheet) { item in
                if canShowStudio { StudioImageShareController(files: item.files) }
            }
            .fullScreenCover(item: $imageViewer) { item in
                if canShowStudio {
                    let files = filteredImageHistory.contains(item.url) ? filteredImageHistory : batchImageURLs
                    StudioImageViewer(files: files.contains(item.url) ? files : [item.url], selected: item.url,
                                      privateImages: privateSession ? privateImages : [:])
                }
            }
            .confirmationDialog("Slet de valgte billeder?", isPresented: $confirmGalleryDelete) {
                Button("Slet valgte billeder", role: .destructive) {
                    for file in filteredImageHistory where selectedGalleryImages.contains(file) { deleteImage(file) }
                    selectedGalleryImages.removeAll()
                    selectingGalleryImages = false
                }
            }
            .fileImporter(isPresented: $importLoRA, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { loadLoRA(url) }
            }
            .confirmationDialog("Slet dette billede permanent?", isPresented: Binding(
                get: { pendingImageDeletion != nil }, set: { if !$0 { pendingImageDeletion = nil } }
            ), presenting: pendingImageDeletion) { file in
                Button("Slet billede", role: .destructive) { deleteImage(file) }
            }
    }

    private var studioPrivacyControls: some View {
        studioPresentations
            .sheet(isPresented: $showSessionNote) { sessionNoteSheet }
            .fileImporter(isPresented: $importChatText, allowedContentTypes: [.plainText]) { result in
                if case .success(let url) = result { loadPromptFile(url, intoImages: false) }
            }
            .confirmationDialog("Gem private billeder i Fotos?", isPresented: Binding(
                get: { pendingPrivatePhoto != nil }, set: { if !$0 { pendingPrivatePhoto = nil } }
            ), titleVisibility: .visible, presenting: pendingPrivatePhoto) { item in
                Button("Gem i Fotos") { exportPrivatePhotos(item.files) }
                Button("Annuller", role: .cancel) { }
            } message: { _ in
                Text("Kopier bliver i Fotos efter sessionen og kan synkroniseres med iCloud.")
            }
            .confirmationDialog(panicDeletesDownloads ? "Slet studiets indhold og lokale modeller?" : "Ryd denne private session?",
                                isPresented: $confirmStudioPanic, titleVisibility: .visible) {
                Button("Ryd og lås", role: .destructive) { clearStudioContent(includingModels: panicDeletesDownloads) }
            } message: {
                Text(panicDeletesDownloads ? "Studiets gemte samtaler og billeder slettes også uden for den private session. Downloadede tekst- og billedmodeller samt LoRA fjernes. Kopier i Fotos og Apples systemmodel bevares."
                                          : "Samtaler, noter og billeder fra sessionen forsvinder. Modeller på telefonen og kopier i Fotos bliver liggende.")
            }
    }

    private var studioSessionLifecycle: some View {
        studioPrivacyControls
            .onAppear { activateChatIfNeeded(); resetIdleTimer() }
            .onChange(of: sessionUnlocked) { _, unlocked in
                if unlocked { activateChatIfNeeded() }
                else if loaded || authenticating {
                    stopStudioImageQueue()
                    closeChatSession()
                }
                resetIdleTimer()
            }
            .onChange(of: studioPage) { _, page in
                if page != .chat { promptFocused = false; dictation.stop() }
                if page != .images { imagePromptFocused = false }
                resetIdleTimer()
            }
            .onChange(of: studioPhase) { _, phase in handleStudioPhase(phase) }
            .onChange(of: history, initial: true) { rebuildGalleryCache() }
            .onChange(of: galleryFilter) { rebuildGalleryCache() }
            .onChange(of: galleryTag) { rebuildGalleryCache() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                rebuildGalleryCache()
            }
            .task(id: sessionUnlocked && !privateSession && studioPhase == .active) {
                guard sessionUnlocked, !privateSession, studioPhase == .active else { return }
                await refreshPublicGallery()
            }
            .task(id: privateDeadline) { await awaitPrivateExpiry() }
            .task(id: privateSession && sessionUnlocked && loaded) { await monitorPrivateConnectivity() }
    }

    private var studioNavigation: some View {
        studioSessionLifecycle
            .onChange(of: task != nil) { _, _ in resetIdleTimer(extendPrivacy: false) }
            .onChange(of: autoSleepMinutes) { _, _ in resetIdleTimer() }
            .onChange(of: sessionPreferences.idleMinutes) { _, _ in resetIdleTimer() }
            .onChange(of: sessionPreferences.modelTimeoutMinutes) { _, _ in resetIdleTimer() }
            .onChange(of: imagePrompt) { _, _ in resetIdleTimer() }
            .onChange(of: prompt) { _, text in
                resetIdleTimer()
                guard loaded, sessionUnlocked, !privateSession else { return }
                do { try MigratedAppData.shared.saveRegularStudioDraft(text) }
                catch { AppDiagnostics.record(error); status = "Kladde kunne ikke gemmes." }
            }
            .task(id: idleRevision) { await sleepStudioWhenIdle() }
            .onReceive(NotificationCenter.default.publisher(for: .localModelLoadState)) { _ in
                loadingModel = LocalCompute.isLoadingModel
            }
            .task(id: effectiveTextModel) { textContextLimit = contextWindow(for: effectiveTextModel) }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                privateBatteryLevel = UIDevice.current.batteryLevel
            }
            .onDisappear {
                guard !showModels, !showBotBuilder, !showPromptEditor, !showSessionNote, imageViewer == nil,
                      imageDetailsSheet == nil, studioShareSheet == nil else { return }
                stopStudioImageQueue()
                closeChatSession()
            }
    }

    @ViewBuilder private var studioContent: some View {
        if studioPhase != .active {
            palette.background.ignoresSafeArea()
        } else if canShowStudio {
            VStack(spacing: 0) {
                if privateSession {
                    Label("Privat session. Gemmes ikke.", systemImage: "lock.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? palette.purple : palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .accessibilityHint("Samtaler og billeder ryddes, når sessionen slutter.")
                }
                Group {
                    if studioTypeSize.isAccessibilitySize { studioPicker.pickerStyle(.menu) }
                    else { studioPicker.pickerStyle(.segmented) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                studioOperationStatus
                switch studioPage {
                case .chat: studioChatPage
                case .images: studioImagesPage
                case .gallery:
                    studioGalleryPage.safeAreaInset(edge: .bottom, spacing: 0) {
                        if privateSession { privateSessionFooter }
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded { _ in resetIdleTimer() })
        } else {
            VStack(spacing: 18) {
                Image(systemName: "faceid").font(.system(size: 56)).foregroundStyle(palette.purple)
                    .accessibilityHidden(true)
                Text(ephemeralOnly ? "NSFW · Privat chat" : "Privat Studio").font(.largeTitle.bold())
                    .foregroundStyle(palette.text)
                Text(ephemeralOnly ? "Kun på din telefon. Lås op med Face ID eller Touch ID." : "Lås op én gang pr. session.")
                    .multilineTextAlignment(.center).foregroundStyle(palette.secondary)
                FadedPrimaryButton("Lås op", icon: "faceid") { authenticate() }
                    .disabled(authenticating || studioPhase != .active)
                if !status.isEmpty && !sessionUnlocked { Text(status).font(.callout).foregroundStyle(palette.secondary) }
            }.padding(24)
        }
    }

    private var privateSessionFooter: some View {
        FadedSecondaryButton("Ryd session", icon: "trash", role: .destructive) {
            panicDeletesDownloads = false
            confirmStudioPanic = true
        }
        .accessibilityHint("Fjerner denne sessions samtaler, noter og billeder. Bevarer modeller.")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FadedSpacing.edge).padding(.vertical, FadedSpacing.s)
        .background(palette.background)
    }

    private var studioPicker: some View {
        Picker("Visning i Privat Studio", selection: $studioPage) {
            ForEach(Page.allCases) { page in
                Text(page == .gallery && !studioTypeSize.isAccessibilitySize ? "Galleri" : page.rawValue).tag(page)
                    .accessibilityLabel(page.rawValue)
            }
        }
    }

    @ViewBuilder private var studioOperationStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if loadingModel && task != nil {
                ProgressView("Indlæser model i hukommelsen…")
                    .progressViewStyle(.linear).tint(palette.cyan)
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(palette.secondary) }
            if let downloadProgress {
                ProgressView(value: downloadProgress) { Text(downloadProgress.formatted(.percent)) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, FadedSpacing.edge)
    }
}
