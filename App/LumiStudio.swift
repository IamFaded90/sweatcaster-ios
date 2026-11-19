import Foundation
import AVKit
import AVFAudio
import PhotosUI
import SwiftUI
import UIKit

/// Lumi's PC studio has dedicated routes and can open a private local image session.
@MainActor struct LumiStudio: View {
    enum SceneSheet: String, Identifiable {
        case library, new, edit, saveAs
        var id: String { rawValue }
    }

    let api: LiveAPI?
    let videoOnly: Bool
    let onVideoActivity: () -> Void
    @Environment(\.dismiss) var dismiss
    @Environment(\.fadedPalette) var palette
    @AppStorage(AppStorageKeys.lumiPendingVideoJob) private var savedVideoJobID = ""
    @State private var privateVideoJobID = ""
    @State var mode = 0
    @State var draft = ""
    @FocusState var composerFocused: Bool
    @State var imageDraft = ""
    @State var useImageTaste = true
    @State var videoDraft = ""
    @State var language = "da-DK"
    @State var dictation = ChatDictation()
    @StateObject var speech = SpeechBox()
    @StateObject var christel = ChristelPlayer()
    @State var showVoicePicker = false
    @State var voiceLanguage = "da-DK"
    @AppStorage(PhoneModels.agentVoiceKey(VillageBot.lumiID)) var voiceOverride = ""
    @State var showChristelSettings = false
    @State var showEverydayTools = false
    @State var christelReady = false
    @State var christelPCReady = false
    @Environment(\.scenePhase) var phase
    @State var messages: [LumiSceneMessage] = []
    @State var sceneCard: LumiSceneCard?
    @State var openedSceneExpiry: Date?
    @State var sceneRevision = UUID()
    @State var initiative: LumiInitiative = .together
    @State var scenes: [LumiSavedScene] = []
    @State var saveSceneTemporarily = false
    @State var libraryNotice: String?
    @State var sceneSheet: SceneSheet?
    @State var nextSceneSheet: SceneSheet?
    @State var pendingScene: LumiSavedScene?
    @State var confirmSceneSwitch = false
    @State var picture: Data?
    @State var pictureFile: URL?
    @State var pictureReference: Data?
    @State var referenceSelection: PhotosPickerItem?
    @State var imageReference: Data?
    @State var loadingReference = false
    @State private var videoReferenceSelection: PhotosPickerItem?
    @State var videoReference: Data?
    @State var loadingVideoReference = false
    @State private var videoInputToPrepare: Data?
    @State var pcImageModel = StudioPCImageModel.realvis
    @State var pcImageCatalog = StudioPCImageCatalog.checking
    @State private var pcImageRefresh = 0
    @State private var showPhoneImageStudio = false
    @State var videoPlayer: AVPlayer?
    @State var videoFile: URL?
    @State var videoResultID: UUID?
    @State var confirmVideoRemoval = false
    @State var scratchID = UUID()
    @State var studioRevision = UUID()
    @State var busy = false
    @State var notice: String?

    init(api: LiveAPI?, videoOnly: Bool = false, initialVideoReference: Data? = nil,
         onVideoActivity: @escaping () -> Void = {}) {
        self.api = api
        self.videoOnly = videoOnly
        self.onVideoActivity = onVideoActivity
        _mode = State(initialValue: videoOnly ? 2 : 0)
        _videoInputToPrepare = State(initialValue: initialVideoReference)
    }

    var inheritedVoice: String {
        VillageBot.list(from: MigratedAppData.shared.villageBots).first { $0.id == VillageBot.lumiID }?.voice ?? "da-DK"
    }

    var pendingVideoJobID: String {
        get { videoOnly ? privateVideoJobID : savedVideoJobID }
        nonmutating set {
            if videoOnly { privateVideoJobID = newValue }
            else { savedVideoJobID = newValue }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !videoOnly {
                    Picker("Vælg", selection: $mode) {
                        Text("Samtale").tag(0)
                        Text("Billeder").tag(1)
                        Text("Video").tag(2)
                    }.pickerStyle(.segmented)
                }

                ScrollViewReader { scroll in
                    ScrollView {
                        studioContent
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollPhaseChange { _, phase in
                        if videoOnly && phase == .interacting { onVideoActivity() }
                    }
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
            .navigationTitle(videoOnly ? "Privat video" : "Lumi")
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .simultaneousGesture(TapGesture().onEnded { onVideoActivity() },
                                 including: videoOnly ? .all : .subviews)
            .onChange(of: videoDraft) {
                if videoOnly { onVideoActivity() }
            }
            .onChange(of: videoReferenceSelection) {
                if videoOnly { onVideoActivity() }
            }
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
            .sheet(isPresented: $showPhoneImageStudio) {
                OfflineStudio(api: nil, sessionUnlocked: .constant(false), initialPage: .images,
                              initialBotID: VillageBot.lumiID, ephemeralOnly: true, imageOnly: true)
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
                if !videoOnly && phase == .active { await refreshChristelPC() }
            }
            .task {
                if !videoOnly {
                    refreshChristel()
                    loadScenes()
                }
                if let source = videoInputToPrepare {
                    videoInputToPrepare = nil
                    applyVideoReference(source)
                }
                await resumeVideoIfNeeded()
            }
            .task(id: nextSceneExpiry) { await waitForSceneExpiry() }
            .sheet(isPresented: $showVoicePicker) {
                AgentVoicePicker(botID: VillageBot.lumiID, name: "Lumi", inheritedVoice: inheritedVoice, rate: 1,
                                 api: api, selection: $voiceOverride, language: $voiceLanguage)
            }
            .onChange(of: mode) {
                composerFocused = false
                stopAudio()
            }
            .onChange(of: phase) {
                if phase == .active {
                    if !videoOnly { loadScenes() }
                }
                else { stopAudio() }
            }
            .onDisappear { discardStudioSession() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                if !videoOnly { loadScenes() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in stopAudio() }
        }
    }

    var studioContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == 0 {
                AgentSpeakingStage(bot: .lumi(), listening: dictation.active)
                sceneControls
                voiceControls
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { item in messageCard(item) }
                }
                Color.clear.frame(height: 1).id("latest-lumi-message")
            } else if mode == 1 {
                lumiImageControls
                if let picture, let image = UIImage(data: picture) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityLabel("Billede lavet af Lumi")
                    if let pictureFile, let comparison = StudioImageComparisonSource(result: pictureFile, bytes: pictureReference) {
                        StudioImageComparison(source: comparison, result: image).id(pictureFile)
                    }
                }
                if let pictureFile {
                    ShareLink(item: pictureFile) {
                        Label("Gem eller del billede", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    Button("Slet billede på iPhone", systemImage: "trash", role: .destructive) { deletePreview(isVideo: false) }
                        .frame(minHeight: 44)
                        .disabled(busy)
                }
            } else {
                videoReferenceControls
                if let videoPlayer, let videoFile {
                    VideoPlayer(player: videoPlayer).frame(height: 300)
                    ShareLink(item: videoFile) {
                        Label("Gem eller del video", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    Button("Slet kopi på iPhone", systemImage: "trash", role: .destructive) { deletePreview(isVideo: true) }
                        .frame(minHeight: 44)
                        .disabled(busy)
                }
                if videoResultID != nil {
                    Button("Slet video fra PC og iPhone", systemImage: "trash", role: .destructive) {
                        confirmVideoRemoval = true
                    }
                    .frame(minHeight: 44)
                    .disabled(busy || api == nil)
                    .confirmationDialog("Slet videoen?", isPresented: $confirmVideoRemoval) {
                        Button("Slet video", role: .destructive, action: deleteVideoResult)
                    } message: {
                        Text("Det genererede resultat slettes. Kopier, du selv har eksporteret, bliver liggende.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var promptComposer: some View {
        let currentDraft = promptDraft(for: mode)
        let placeholder = mode == 0 ? "Skriv til Lumi" : mode == 1 ? "Beskriv dit billede" : "Beskriv din video"
        let action = mode == 0 ? "Send" : mode == 1 ? "Lav billede" : "Lav video"
        let icon = mode == 0 ? "arrow.up" : mode == 1 ? "photo" : "film"
        return VStack(alignment: .leading, spacing: 6) {
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(palette.coralText)
                    .accessibilityAddTraits(.updatesFrequently)
            } else if api == nil {
                FadedDetailText(mode == 1 ? "Forbind PC’en, eller vælg Lav billeder på iPhone." : "Forbind din PC for at fortsætte.")
            }
            if busy { FadedThinkingIndicator(title: mode == 0 ? "Lumi svarer på PC’en…" : "Arbejder på PC’en…") }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: currentDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .frame(minHeight: 44)
                    .textFieldStyle(.plain)
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
                    .disabled(busy || (mode == 1 && (loadingReference || !pcImageCatalog.allows(pcImageModel))) ||
                              (mode == 2 && loadingVideoReference) ||
                              dictation.active || api == nil ||
                              !isValidPrompt(currentDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), for: mode))
            }
        }
        .padding(14)
        .background { ChatGlassSurface(radius: 22, colors: [FadedBrand.pc, FadedBrand.blue]) }
        .fadedWorkingBeam(active: busy, pc: true)
        .padding(.vertical, 6)
    }

    private var lumiImageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let api {
                StudioPCImageModelPicker(selection: $pcImageModel, catalog: pcImageCatalog) {
                    pcImageRefresh += 1
                }
                .disabled(busy)
                PCImageEngineStatusRow(api: api, refreshCount: pcImageRefresh)
                if let blocker = pcImageCatalog.blocker(for: pcImageModel) {
                    FadedDetailText(blocker)
                }
                referencePicker
                if let style = AgentImageTasteStyle.selected(for: VillageBot.lumiID) {
                    Toggle("Brug min billedstil · " + style.title, isOn: $useImageTaste).disabled(busy)
                }
            }
            FadedSecondaryButton("Lav billeder på iPhone", icon: "iphone") {
                composerFocused = false
                showPhoneImageStudio = true
            }
            .disabled(busy)
        }
        .task(id: "\(api?.queueTargetID ?? ""):\(pcImageRefresh)") {
            guard let api else { return }
            pcImageCatalog = .checking
            let catalog = await StudioPCImageCatalog.inspect(api)
            if !Task.isCancelled { pcImageCatalog = catalog }
        }
    }

    func messageCard(_ message: LumiSceneMessage) -> some View {
        AgentChatBubble(user: message.role == .user,
                        title: message.role == .user ? "Dig" : "Lumi · PC", pc: true) {
            ChatTranscriptView(reply: message.text)
            if message.role == .assistant { replyAudio(message.text, language: message.language) }
        }
    }

    func refreshChristel() {
        christelReady = ChristelConfiguration.load() != nil
        Task { await refreshChristelPC() }
    }

    func refreshChristelPC() async {
        let available = (try? await api?.christelConfigured()) == true
        if !Task.isCancelled { christelPCReady = available }
    }

    func replyAudio(_ text: String, language: String) -> some View {
        let locale = LocalSpeechVoice.detectedReplyLanguage(text) ?? language
        let identifier = voiceOverride.isEmpty ? inheritedVoice : voiceOverride
        let pcVoice = AgentPCVoice(rawValue: identifier)
        let voice = AgentVoiceSelection.resolve(identifier: identifier, language: locale)
        let name = pcVoice?.name ?? voice?.name
        return VStack(alignment: .leading, spacing: 2) {
            Button(name.map { "Læs med " + $0 } ?? "Vælg en stemme", systemImage: "speaker.wave.2") {
                dictation.stop()
                let text = LocalSpeechVoice.replyText(text)
                if let pcVoice {
                    speech.stop()
                    guard let api else { notice = "Forbind PC’en, eller vælg en iPhone-stemme."; return }
                    christel.playAgentVoice(text: text, voice: pcVoice, agentID: VillageBot.lumiID, pc: api)
                    return
                }
                christel.stop()
                guard let voice else { notice = AgentVoiceSelection.unavailable; showVoicePicker = true; return }
                speech.play(LocalSpeechVoice.utterance(text, voice: voice, rate: 1),
                            as: .preview, agentID: VillageBot.lumiID)
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

    var voiceControls: some View {
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
            Button("Vælg og hør Lumis stemme", systemImage: "person.wave.2") {
                stopAudio()
                showVoicePicker = true
            }
            .frame(minHeight: 44)
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

    func stopAudio() {
        dictation.stop()
        speech.stop()
        christel.stop()
    }

    private var videoReferenceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedDetailText("Lav et kort klip fra en beskrivelse. Tilføj et billede, hvis det skal være klippets første billede.")
            mediaReferencePicker(selection: $videoReferenceSelection, reference: $videoReference,
                                 loading: $loadingVideoReference, forVideo: true)
            if let picture, videoReference == nil {
                FadedSecondaryButton("Brug Lumis seneste billede", icon: "photo.badge.plus") {
                    videoReferenceSelection = nil
                    applyVideoReference(picture)
                }.disabled(busy)
            }
        }
    }

    private func applyVideoReference(_ source: Data) {
        guard let data = StudioPhotoInput.downsample(source), (1...1_000_000).contains(data.count) else {
            notice = "Billedet til video kunne ikke åbnes."
            return
        }
        videoReference = data
    }

    var referencePicker: some View {
        mediaReferencePicker(selection: $referenceSelection, reference: $imageReference,
                             loading: $loadingReference, forVideo: false)
    }

    private func mediaReferencePicker(selection: Binding<PhotosPickerItem?>, reference: Binding<Data?>,
                                      loading: Binding<Bool>, forVideo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let data = reference.wrappedValue, let preview = UIImage(data: data) {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                        .accessibilityLabel("Valgt referencebillede")
                }
                PhotosPicker(selection: selection, matching: .images) {
                    Label(reference.wrappedValue == nil ? "Tilføj referencebillede" : "Skift referencebillede",
                          systemImage: "photo.badge.plus").frame(minHeight: 44)
                }
                .disabled(busy)
                if loading.wrappedValue { ProgressView() }
                if reference.wrappedValue != nil || loading.wrappedValue {
                    Button("Fjern referencebillede", systemImage: "xmark") {
                        selection.wrappedValue = nil
                        reference.wrappedValue = nil
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(busy)
                }
            }
            if reference.wrappedValue != nil {
                Text(forVideo ? "Referencebilledet sendes til din parrede PC, når du trykker Lav video."
                      : "Referencebilledet sendes til din parrede PC, når du trykker Lav billede.")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
        }
        .task(id: selection.wrappedValue) {
            guard let item = selection.wrappedValue else { loading.wrappedValue = false; return }
            reference.wrappedValue = nil
            loading.wrappedValue = true
            defer { if selection.wrappedValue == item { loading.wrappedValue = false } }
            do {
                guard let input = try await item.loadTransferable(type: StudioPhotoInput.self),
                      (1...1_000_000).contains(input.data.count) else { throw APIError.input }
                try Task.checkCancellation()
                if selection.wrappedValue == item { reference.wrappedValue = input.data }
            } catch {
                if !Task.isCancelled && selection.wrappedValue == item {
                    notice = "Referencebilledet kunne ikke åbnes."
                }
            }
        }
    }

}
