import Foundation
import AVKit
import AVFAudio
import PhotosUI
import SwiftUI
import UIKit

/// Lumi has a separate screen and a fixed PC route; ordinary bot chats never select her models.
@MainActor struct LumiStudio: View {
    enum SceneSheet: String, Identifiable {
        case library, new, edit, saveAs
        var id: String { rawValue }
    }

    let api: LiveAPI?
    @Environment(\.dismiss) var dismiss
    @Environment(\.fadedPalette) var palette
    @AppStorage(AppStorageKeys.lumiPendingVideoJob) var pendingVideoJobID = ""
    @State var mode = 0
    @State var draft = ""
    @FocusState var composerFocused: Bool
    @State var imageDraft = ""
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
    @State var referenceSelection: PhotosPickerItem?
    @State var imageReference: Data?
    @State var loadingReference = false
    @State var videoPlayer: AVPlayer?
    @State var videoFile: URL?
    @State var videoResultID: UUID?
    @State var confirmVideoRemoval = false
    @State var scratchID = UUID()
    @State var studioRevision = UUID()
    @State var busy = false
    @State var notice: String?

    var inheritedVoice: String {
        VillageBot.list(from: MigratedAppData.shared.villageBots).first { $0.id == VillageBot.lumiID }?.voice ?? "da-DK"
    }

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
                loadScenes()
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
                if phase == .active { loadScenes() }
                else { stopAudio() }
            }
            .onDisappear { discardStudioSession() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in loadScenes() }
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
                    Button("Slet billede på iPhone", systemImage: "trash", role: .destructive) { deletePreview(isVideo: false) }
                        .frame(minHeight: 44)
                        .disabled(busy)
                }
            } else {
                if let videoPlayer, let videoFile {
                    VideoPlayer(player: videoPlayer).frame(height: 300)
                    ShareLink(item: videoFile) {
                        Label("Gem eller del video", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    Button("Slet kopi på iPhone", systemImage: "trash", role: .destructive) { deletePreview(isVideo: true) }
                        .frame(minHeight: 44)
                        .disabled(busy)
                } else if videoResultID == nil {
                    FadedDetailText("Lav et kort klip med PC’en. Det kan tage flere minutter.")
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
                FadedDetailText("Forbind din PC for at bruge Lumi.")
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
                    .disabled(busy || (mode == 1 && loadingReference) || dictation.active || api == nil ||
                              !isValidPrompt(currentDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(14)
        .background { ChatGlassSurface(radius: 22, colors: [FadedBrand.pc, FadedBrand.blue]) }
        .fadedWorkingBeam(active: busy, pc: true)
        .padding(.vertical, 6)
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

    var referencePicker: some View {
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

}
