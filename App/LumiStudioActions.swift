import Foundation
import AVKit
import AVFAudio
import PhotosUI
import SwiftUI

struct LumiChatImageRequest {
    let prompt: String
    let isSelfPortrait: Bool

    static func parse(_ message: String) -> Self? {
        let danish = #"^(?:hej lumi[,! ]+|lumi[,!: ]+)?(?:(?:kan|vil|kunne|gider) du (?:ikke )?(?:lave|generere|sende|tegne|vise|tage)|lav|generér|generer|send|tegn|vis|tag|(?:kan|må) jeg få|jeg vil gerne (?:have|se))?(?: (?:lige|gerne|mig|også))*\s*(?:et |en |det )?(?:billede?|foto|selfie)(?=$|[\s.!?:])"#
        let english = #"^(?:lumi[,!: ]+)?(?:(?:can|could|would) you )?(?:make|generate|create|draw|send|show|take)(?: me)? (?:a |an )?(?:picture|image|photo|selfie)(?=$|[\s.!?:])"#
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard let range = message.range(of: danish, options: options)
                ?? message.range(of: english, options: options) else { return nil }
        let punctuation = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "!?.:,"))
        let suffix = String(message[range.upperBound...])
        let description = suffix
            .replacingOccurrences(of: #"^\s*(?:af\s+|med\s+|of\s+|with\s+|:)"#, with: "", options: options)
            .trimmingCharacters(in: punctuation)
        let person = #"^(?:dig(?: selv)?|lumi|yourself|you)(?=$|[\s,!?.])"#
        let subject = description.range(of: person, options: options)
        let otherSubject = suffix.range(of: #"^\s*(?:af|of)\s+"#, options: options) != nil
        let selfie = message[range].lowercased().hasSuffix("selfie") && !otherSubject
        guard subject != nil || selfie else { return Self(prompt: description, isSelfPortrait: false) }
        let detail = subject.map { String(description[$0.upperBound...]).trimmingCharacters(in: punctuation) } ?? description
        let identity = Self.portraitPrompt
        return Self(prompt: detail.isEmpty ? identity : identity + " Composition and setting: " + detail, isSelfPortrait: true)
    }

    static let portraitPrompt = "Create a self-portrait of Lumi, the fictional character in the supplied portrait. Preserve her facial features, hair, and identity."

    static func referencePortrait() -> Data? {
        guard let url = VillageProductionArt.url("portrait-lumi"),
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
              let data = StudioPhotoInput.downsample(bytes),
              (1...1_000_000).contains(data.count) else { return nil }
        return data
    }
}

extension LumiStudio {
    var sceneControls: some View {
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
                Toggle("Lumi må selv sende et portræt", isOn: Binding(get: { portraits.enabled }, set: portraits.setEnabled))
                    .font(.subheadline)
                if portraits.enabled {
                    FadedDetailText(portraits.isPreparing ? "Din PC laver Lumis portræt. Slå valget fra for at stoppe."
                                    : "Højst ét portræt i denne samtale. Lumi bruger sit eget billede på din PC.")
                }
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
                Toggle("Slet næste gemning efter 5 min.", isOn: $saveSceneTemporarily)
                    .font(.footnote)
            }
        }
        .disabled(busy || dictation.active)
    }

    var leadButton: some View {
        FadedSecondaryButton("Tag føringen", icon: "sparkles") { send(opening: true) }
            .disabled(api == nil)
    }

    var libraryButton: some View {
        FadedSecondaryButton("Scenebibliotek", icon: "books.vertical") {
            loadScenes()
            sceneSheet = .library
        }
    }

    @ViewBuilder func sceneSheetContent(_ sheet: SceneSheet) -> some View {
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
                LumiSceneCardEditor(card: sceneCard, actionTitle: "Brug scenekort") { card in
                    guard self.sceneCard?.id == sceneCard.id, !clearExpiredOpenedScene() else { return }
                    self.sceneCard = card
                }
            }
        case .saveAs:
            LumiSceneCardEditor(card: LumiSceneCard(), actionTitle: "Gem scenen") { saveScene($0) }
        }
    }

    func finishSceneSheet() {
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

    var sceneHasEdits: Bool {
        if attachedPhoto != nil || secondChatPhoto != nil { return true }
        guard let sceneCard else { return !messages.isEmpty || !draft.isEmpty }
        guard let saved = scenes.first(where: { $0.id == sceneCard.id }) else { return true }
        return !saved.matches(sceneSnapshot(sceneCard))
    }

    func sceneSnapshot(_ card: LumiSceneCard) -> LumiSavedScene {
        .snapshot(card: card, initiative: initiative, language: language, messages: messages, draft: draft)
    }

    func openScene(_ scene: LumiSavedScene) {
        guard !scene.isExpired(at: .now) else {
            pendingScene = nil
            notice = "Den midlertidige scene er udløbet."
            loadScenes()
            return
        }
        resetSceneInput()
        sceneCard = scene.card
        initiative = scene.initiative
        language = scene.language == "en-US" ? "en-US" : "da-DK"
        messages = scene.messages
        draft = scene.draft
        openedSceneExpiry = scene.expiresAt
        saveSceneTemporarily = scene.expiresAt != nil
        pendingScene = nil
        notice = nil
        pruneSceneMedia()
    }

    func loadScenes() {
        let now = Date.now
        clearExpiredOpenedScene(now: now)
        do {
            scenes = try LumiSceneLibrary.load(now: now)
            pruneSceneMedia(now: now)
            libraryNotice = nil
        } catch {
            scenes = []
            libraryNotice = "Scenebiblioteket kunne ikke læses. Lås iPhone op, og prøv igen."
        }
    }

    @discardableResult
    func clearExpiredOpenedScene(now: Date = .now) -> Bool {
        guard let expiry = openedSceneExpiry, expiry <= now else { return false }
        resetSceneInput()
        openedSceneExpiry = nil
        sceneCard = nil
        messages = []
        draft = ""
        pruneSceneMedia(now: now)
        initiative = .together
        saveSceneTemporarily = false
        if sceneSheet == .edit || sceneSheet == .saveAs { sceneSheet = nil }
        notice = "Den midlertidige scene er udløbet."
        return true
    }

    private func resetSceneInput() {
        portraits.endSession()
        sceneRevision = UUID()
        stopAudio()
        dictation.clearReview()
        attachedPhoto = nil
        secondChatPhoto = nil
        loadingChatPhoto = false
        loadingSecondChat = false
    }

    func saveScene(_ card: LumiSceneCard) {
        guard !clearExpiredOpenedScene() else { return }
        do {
            let current = try LumiSceneLibrary.load()
            guard current.count < LumiSceneLibrary.maximumScenes || current.contains(where: { $0.id == card.id }) else {
                notice = "Scenebiblioteket er fuldt. Fjern en gammel scene, før du gemmer en ny."
                return
            }
            let saved = LumiSavedScene.snapshot(card: card, initiative: initiative, language: language,
                                                messages: messages, draft: draft, temporarily: saveSceneTemporarily)
            let updated = [saved] + current.filter { $0.id != card.id }
            try LumiSceneLibrary.save(updated)
            scenes = updated
            sceneCard = card
            openedSceneExpiry = saved.expiresAt
            notice = saveSceneTemporarily ? "Scenen er gemt i 5 minutter." : "Scenen er gemt på denne iPhone."
        } catch {
            notice = "Scenen kunne ikke gemmes. Lås iPhone op, og prøv igen."
        }
    }

    func removeScene(_ id: UUID) {
        do {
            let updated = try LumiSceneLibrary.load().filter { $0.id != id }
            try LumiSceneLibrary.save(updated)
            scenes = updated
            libraryNotice = nil
            pruneSceneMedia()
        } catch {
            libraryNotice = "Scenen kunne ikke slettes. Prøv igen."
        }
    }

    func promptDraft(for mode: Int) -> Binding<String> {
        switch mode {
        case 1: $imageDraft
        case 2: $videoDraft
        default: $draft
        }
    }

    func isValidPrompt(_ prompt: String, for mode: Int) -> Bool {
        (1...(mode == 0 ? 4_000 : 1_000)).contains(prompt.unicodeScalars.count)
    }

    func send(opening: Bool = false) {
        guard let api, !busy, !dictation.active, mode != 0 || (!loadingChatPhoto && !loadingSecondChat) else { return }
        guard !opening || mode == 0 else { return }
        if mode == 0, clearExpiredOpenedScene() { return }
        portraits.interrupt()
        let portraitTurn = portraits.revision
        let selectedDraft = promptDraft(for: mode)
        let originalInput = opening ? (language == "da-DK" ? "Tag føringen" : "Take the lead")
            : selectedDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = mode == 0 && !opening ? secondChatPhoto : mode == 1 ? secondImageReference : nil
        let chatPhoto = mode == 0 && !opening ? attachedPhoto : nil
        let parsed = chatPhoto == nil ? LumiChatImageRequest.parse(originalInput) : LumiChatImageRequest.requestedWithPhoto(originalInput)
        let imageFromChat = mode == 0 && !opening ? (parsed
            ?? pair.map { _ in LumiChatImageRequest(prompt: originalInput, isSelfPortrait: false) }) : nil
        if let chatPhoto, imageFromChat == nil { sendChatPhoto(chatPhoto, via: api); return }
        let selectedMode = imageFromChat == nil ? mode : 1
        let input = imageFromChat?.prompt ?? originalInput
        if imageFromChat?.prompt.isEmpty == true {
            notice = "Hvad skal der være på billedet? Skriv fx »Lav et billede af en solnedgang ved havet«."
            return
        }
        if imageFromChat != nil && !isValidPrompt(input, for: 1) {
            notice = "Forkort billedbeskrivelsen til højst 1.000 tegn."
            return
        }
        guard isValidPrompt(input, for: selectedMode) else { return }
        let imageInput = selectedMode == 1 && useImageTaste
            ? AgentImageTasteStyle.selected(for: VillageBot.lumiID)?.applying(to: input) ?? input : input
        if selectedMode == 1 && !isValidPrompt(imageInput, for: 1) {
            notice = "Forkort beskrivelsen, eller slå billedstilen fra."
            return
        }
        let selectedImageModel = pair != nil && mode == 0 ? (pcImageCatalog.pairModel(preferred: pcImageModel) ?? pcImageModel) : pcImageModel
        if pair != nil && !selectedImageModel.isFlux { notice = "Vælg FLUX 2 på PC for at bruge begge fotos."; return }
        if selectedMode == 1 {
            if let blocker = pcImageCatalog.blocker(for: selectedImageModel) {
                notice = blocker
                return
            }
            guard imageFromChat != nil || (!loadingReference && !loadingSecondImage) else { return }
        }
        if selectedMode == 2 && loadingVideoReference { return }
        composerFocused = false
        let wantsSelfPortrait = imageFromChat?.isSelfPortrait == true
        let reference = pair != nil ? (mode == 0 ? attachedPhoto : imageReference) : wantsSelfPortrait ? LumiChatImageRequest.referencePortrait()
            : selectedMode == 1 ? (imageFromChat == nil ? imageReference : chatPhoto) : nil
        if wantsSelfPortrait && reference == nil {
            notice = "Lumis portræt kunne ikke åbnes. Prøv at lukke og åbne chatten igen."
            return
        }
        let selectedVideoReference = selectedMode == 2 ? videoReference : nil
        let replyLanguage = language
        let selectedScene = sceneCard
        let selectedSceneRevision = sceneRevision
        let selectedStudioRevision = studioRevision
        let selectedInitiative: LumiInitiative = opening ? .lumi : initiative
        dictation.clearReview()
        let previous = modelHistory
        if !opening { selectedDraft.wrappedValue = "" }
        notice = nil
        busy = true
        chatImagePending = imageFromChat != nil
        Task {
            defer { busy = false; chatImagePending = false }
            do {
                if selectedMode == 0 {
                    let reply = try await api.lumiChat(message: input, history: previous, language: replyLanguage,
                                                      scene: selectedScene, initiative: selectedInitiative, opening: opening)
                    guard studioRevision == selectedStudioRevision, !clearExpiredOpenedScene(),
                          sceneRevision == selectedSceneRevision else { return }
                    if opening { initiative = .lumi }
                    messages.append(LumiSceneMessage(role: .user, text: input, language: replyLanguage))
                    messages.append(LumiSceneMessage(role: .assistant, text: String(reply.unicodeScalars.prefix(4_000)),
                                                     language: replyLanguage))
                    if !opening { offerLumiPortrait(after: portraitTurn, api: api, language: replyLanguage) }
                } else if selectedMode == 1 {
                    let data = try await renderLumiPicture(api: api, model: selectedImageModel, prompt: imageInput,
                                                           reference: reference, pair: pair)
                    guard studioRevision == selectedStudioRevision else { return }
                    if imageFromChat != nil, clearExpiredOpenedScene() || sceneRevision != selectedSceneRevision { return }
                    if imageFromChat != nil {
                        let result = try chatPicture(data, caption: replyLanguage == "en-US" ? "Image ready." : "Billedet er klar.",
                                                     language: replyLanguage)
                        if let chatPhoto, reference == chatPhoto, attachedPhoto == chatPhoto, secondChatPhoto == pair {
                            attachedPhoto = nil; secondChatPhoto = nil
                        }
                        messages.append(LumiSceneMessage(role: .user, text: originalInput, language: replyLanguage))
                        messages.append(result)
                    } else {
                        let file = try writeStudioMedia(data, filename: "Lumi.png")
                        picture = data
                        pictureFile = file
                        pictureReference = reference
                    }
                } else {
                    let receipt: LumiVideoJob
                    do {
                        receipt = try await api.lumiStartVideo(prompt: input, reference: selectedVideoReference,
                                                               privateSession: videoOnly)
                    } catch let failure as APIError {
                        if (videoOnly || selectedVideoReference != nil), case .http(404, _) = failure {
                            throw LumiJobFailure(message: "Opdatér FadedAI på PC’en for at bruge denne videofunktion.")
                        }
                        throw failure
                    }
                    guard let id = UUID(uuidString: receipt.id) else { throw APIError.malformed }
                    if videoOnly && studioRevision != selectedStudioRevision {
                        try await api.lumiRemoveVideo(id: id)
                        return
                    }
                    pendingVideoJobID = id.uuidString
                    try await finishVideo(id: id, api: api, revision: selectedStudioRevision)
                }
            } catch {
                guard !Task.isCancelled, studioRevision == selectedStudioRevision else { return }
                if (selectedMode == 0 || imageFromChat != nil), clearExpiredOpenedScene() || sceneRevision != selectedSceneRevision { return }
                AppDiagnostics.record(error)
                if !opening && selectedDraft.wrappedValue.isEmpty && (selectedMode != 2 || pendingVideoJobID.isEmpty) {
                    selectedDraft.wrappedValue = originalInput
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

    private func sendChatPhoto(_ photo: Data, via api: LiveAPI) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1_200 else { return }
        let replyLanguage = language
        let question = text.isEmpty ? (replyLanguage == "en-US" ? "Describe the photo." : "Beskriv billedet.") : text
        let user = LumiSceneMessage(role: .user, text: question, language: replyLanguage)
        let revision = studioRevision
        let scene = sceneRevision
        messages.append(user)
        sceneMedia.sentPhotos[user.id] = photo
        attachedPhoto = nil
        draft = ""
        composerFocused = false
        notice = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await AgentChatPhotoReply.answer(photo, question: question, agent: "Lumi",
                                                                  language: replyLanguage, pc: api)
                guard studioRevision == revision, !clearExpiredOpenedScene(), sceneRevision == scene else { return }
                messages.append(LumiSceneMessage(role: .assistant, text: String(result.text.prefix(4_000)),
                                                 language: replyLanguage))
            } catch {
                guard studioRevision == revision, !clearExpiredOpenedScene(), sceneRevision == scene else { return }
                sceneMedia.sentPhotos[user.id] = nil
                messages.removeAll { $0.id == user.id }
                attachedPhoto = photo
                if draft.isEmpty { draft = text }
                show(error)
            }
        }
    }

    var modelHistory: [[String: String]] {
        LumiSceneMessage.chatHistory(messages)
    }

    func resumeVideoIfNeeded() async {
        guard !pendingVideoJobID.isEmpty else { return }
        guard let id = UUID(uuidString: pendingVideoJobID) else {
            pendingVideoJobID = ""
            return
        }
        guard let api, !busy else { return }
        mode = 2
        busy = true
        let selectedStudioRevision = studioRevision
        defer { busy = false }
        do { try await finishVideo(id: id, api: api, revision: selectedStudioRevision) }
        catch {
            guard !Task.isCancelled, studioRevision == selectedStudioRevision else { return }
            AppDiagnostics.record(error)
            if let apiError = error as? APIError, case .http(404, _) = apiError {
                pendingVideoJobID = ""
            }
            show(error)
        }
    }

    func finishVideo(id: UUID, api: LiveAPI, revision: UUID) async throws {
        guard studioRevision == revision else { return }
        var status = try await api.lumiVideoStatus(id: id)
        while status.status == "working" {
            guard studioRevision == revision else { return }
            if videoOnly && phase == .active { onVideoActivity() }
            try await Task.sleep(for: .seconds(12))
            guard studioRevision == revision else { return }
            status = try await api.lumiVideoStatus(id: id)
        }
        guard studioRevision == revision else { return }
        guard status.status == "ready" else {
            pendingVideoJobID = ""
            throw LumiJobFailure(message: status.message ?? "Videoen fejlede på PC’en.")
        }
        let data = try await api.lumiVideoFile(id: id)
        try Task.checkCancellation()
        guard studioRevision == revision else { return }
        let file = try writeStudioMedia(data, filename: "Lumi.mp4")
        videoFile = file
        videoPlayer = AVPlayer(url: file)
        videoResultID = status.removable == true ? id : nil
        pendingVideoJobID = ""
    }

    var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: StudioScratch.prefix + scratchID.uuidString, directoryHint: .isDirectory)
    }

    func writeStudioMedia(_ data: Data, filename: String) throws -> URL {
        StudioScratch.purgeOnceAtLaunch()
        let directory = scratchDirectory
        let file = directory.appending(path: filename)
        try LocalFileStore.writeBytes(data, to: file, within: directory)
        return file
    }

    func deletePreview(isVideo: Bool) {
        guard !busy, let file = isVideo ? videoFile : pictureFile else { return }
        if isVideo { videoPlayer?.pause() }
        do {
            try LocalFileStore(root: scratchDirectory).delete(file)
            if isVideo {
                videoPlayer = nil
                videoFile = nil
            } else {
                picture = nil
                pictureFile = nil
                pictureReference = nil
            }
            notice = isVideo ? "Videoen er slettet fra iPhone." : "Billedet er slettet fra iPhone."
        } catch {
            AppDiagnostics.record(error)
            notice = "Filen kunne ikke slettes. Prøv igen, mens iPhone er låst op."
        }
    }

    func deleteChatPicture(_ id: UUID) {
        guard !busy, let file = sceneMedia.pictures[id] else { return }
        do {
            try LocalFileStore(root: scratchDirectory).delete(file)
            sceneMedia.pictures[id] = nil
            messages.removeAll { $0.id == id }
        } catch {
            AppDiagnostics.record(error)
            notice = "Billedet kunne ikke slettes. Prøv igen."
        }
    }

    func deleteVideoResult() {
        guard !busy, let api, let id = videoResultID else { return }
        let revision = studioRevision
        busy = true
        Task {
            defer { busy = false }
            do {
                try await api.lumiRemoveVideo(id: id)
                guard studioRevision == revision else { return }
                videoResultID = nil
                if let videoFile {
                    videoPlayer?.pause()
                    try LocalFileStore(root: scratchDirectory).delete(videoFile)
                    videoPlayer = nil
                    self.videoFile = nil
                }
                notice = "Videoen er slettet fra PC og iPhone."
            } catch {
                guard studioRevision == revision else { return }
                AppDiagnostics.record(error)
                if videoResultID == nil {
                    notice = "Videoen er slettet på PC’en. Prøv igen at slette kopien på iPhone."
                } else { show(error) }
            }
        }
    }

    func discardStudioSession() {
        portraits.endSession()
        sceneRevision = UUID()
        studioRevision = UUID()
        if videoOnly {
            let id = UUID(uuidString: pendingVideoJobID) ?? videoResultID
            pendingVideoJobID = ""
            if let api, let id {
                Task {
                    do { try await api.lumiRemoveVideo(id: id) }
                    catch { AppDiagnostics.record(error) }
                }
            }
        }
        stopAudio()
        videoPlayer?.pause()
        videoPlayer = nil
        videoFile = nil
        videoResultID = nil
        picture = nil
        pictureFile = nil
        pictureReference = nil
        sceneMedia = LumiSceneMedia()
        attachedPhoto = nil
        imageReference = nil
        secondChatPhoto = nil
        loadingSecondChat = false
        secondImageReference = nil
        loadingSecondImage = false
        videoReference = nil
        let directory = scratchDirectory
        do { try FileManager.default.removeItem(at: directory) }
        catch let error where LocalFileStore.isMissing(error) {}
        catch { AppDiagnostics.record(error) }
    }

    func show(_ error: Error) {
        if let failure = error as? LumiJobFailure { notice = failure.message }
        else if let apiError = error as? APIError,
                case let .http(_, problem) = apiError,
                let message = problem?.message { notice = message }
        else { notice = AppErrorPresentation(error).title }
    }
}

struct LumiJobFailure: Error {
    let message: String
}
