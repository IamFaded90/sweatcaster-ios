import Foundation
import AVKit
import AVFAudio
import PhotosUI
import SwiftUI

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
                LumiSceneCardEditor(card: sceneCard, actionTitle: "Brug scenekort") { self.sceneCard = $0 }
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
        stopAudio()
        sceneCard = scene.card
        initiative = scene.initiative
        language = scene.language == "en-US" ? "en-US" : "da-DK"
        messages = scene.messages
        draft = scene.draft
        saveSceneTemporarily = scene.expiresAt != nil
        pendingScene = nil
        notice = nil
    }

    func loadScenes() {
        do {
            scenes = try LumiSceneLibrary.load()
            libraryNotice = nil
        } catch {
            libraryNotice = "Scenebiblioteket kunne ikke læses. Lås iPhone op, og prøv igen."
        }
    }

    func saveScene(_ card: LumiSceneCard) {
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

    func isValidPrompt(_ prompt: String) -> Bool {
        (1...4_000).contains(prompt.unicodeScalars.count)
    }

    func send(opening: Bool = false) {
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

    var modelHistory: [[String: String]] {
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

    func resumeVideoIfNeeded() async {
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

    func finishVideo(id: UUID, api: LiveAPI) async throws {
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
