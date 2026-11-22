import AVFAudio
import ReplayKit
import SwiftUI
import UIKit

enum AgentScreenIntent {
    static func draftForScreenshot(_ question: String, current: String) -> String {
        let caption = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty, draft != caption, !draft.hasSuffix("\n" + caption) else { return current }
        return draft.isEmpty ? caption : current + "\n" + caption
    }

    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"\b(?:pc|computer|windows|vindue)\b"#, options: .regularExpression) != nil { return false }
        return AgentWindowIntent.matches(text) ||
            lower.range(of: #"^(?:del|vis|åbn|start) (?:min |din |en )?(?:iphone|telefon)(?:skærm| skærm| skærmdeling)$"#,
                        options: .regularExpression) != nil
    }
}

struct PhoneScreenFrameStatus: Decodable {
    let frames: Int
    let age: Double?
    let frozen: Bool

    // The PC accepts a frozen frame, or a live frame received within the last 15 seconds.
    var canRead: Bool { frames > 0 && (frozen || age.map { (0...15).contains($0) } == true) }

    var message: String {
        guard frames > 0 else { return "Venter på det første billede. Start delingen, og skift til den app, du vil spørge om." }
        if frozen { return "Det seneste billede fra din delte app er klar." }
        return canRead ? "Skærmen deles nu." : "Der er ikke kommet et nyt billede. Åbn den delte app igen, eller vælg et skærmbillede nedenfor."
    }
}

@MainActor struct AgentScreenShareView: View {
    private typealias Status = PhoneScreenFrameStatus
    let api: LiveAPI?
    let bot: VillageBot
    let useScreenshot: ((Data, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var configuration: PhoneBroadcastConfiguration?
    @State private var status: Status?
    @State private var question = ""
    @State private var answer = ""
    @State private var notice: String?
    @State private var asking = false
    @State private var voice = false
    @State private var dictation = ChatDictation()
    @StateObject private var speech = SpeechBox()
    @StateObject private var pcSpeech = ChristelPlayer()
    @State private var voiceDraft = ""
    @State private var voiceJob: Task<Void, Never>?
    @State private var answerJob: Task<Void, Never>?
    @State private var answerRun = UUID()
    @State private var microphoneJob: Task<Void, Never>?
    @State private var microphoneRun = UUID()
    @State private var speakingTurn = false
    @State private var stopping = false
    @State private var connectionJob: Task<Void, Never>?
    @State private var connectionRun = UUID()
    @State private var connecting = false
    @State private var connectionFailed = false
    @State private var screenControl: Task<Void, Never>?
    @State private var screenshot: Data?
    @State private var loadingScreenshot = false
    @State private var readingScreenshot = false

    init(api: LiveAPI?, bot: VillageBot, prompt: String, useScreenshot: ((Data, String) -> Void)? = nil) {
        self.api = api
        self.bot = bot
        self.useScreenshot = useScreenshot
        // The toolbar shortcut has no question yet. Keep any question typed in chat, even while the PC is offline.
        let initial = prompt == "Se lige min skærm" ? "" : prompt
        _question = State(initialValue: initial)
    }

    private struct Started: Decodable {
        let id: String
        let uploadToken: String
        let expires: Double
        let path: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Del din iPhone med " + bot.name, systemImage: "iphone").font(.title2.bold())
                            Text("Start skærmdeling nedenfor, og gå over i den app, du vil have hjælp til. Vend tilbage for at spørge, eller slå samtale til.")
                            if configuration != nil {
                                PhoneBroadcastPicker().frame(width: 64, height: 64)
                                    .accessibilityLabel("Start iPhone-skærmdeling med FadedAI")
                                if connecting { ProgressView("Genopretter forbindelsen…") }
                                if connectionFailed {
                                    FadedSecondaryButton("Prøv forbindelsen igen", icon: "arrow.clockwise") { reconnect() }
                                }
                            } else if stopping {
                                Text("Skærmdelingen er afsluttet.")
                                FadedSecondaryButton("Start igen", icon: "arrow.clockwise") { stopping = false; reconnect() }
                            } else if connecting { ProgressView("Forbinder til PC’en…") }
                            else if api != nil, PhoneBroadcastConfiguration.hasSharedContainer {
                                FadedSecondaryButton("Prøv forbindelsen igen", icon: "arrow.clockwise") { reconnect() }
                            }
                            else if api == nil { Text("Forbind din iPhone til FadedAI på PC’en for at dele skærmen med agenten.") }
                            if let status, !connecting, !connectionFailed {
                                Text(status.message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if configuration != nil {
                        Toggle("Tal med " + bot.name + ", mens du deler", isOn: $voice)
                        if voice {
                            Text(asking ? "Læser skærmen…" : speakingTurn ? "Agenten svarer…" : "Mikrofonen lytter efter dit spørgsmål.")
                                .font(.footnote)
                        }
                    }
                    if configuration != nil || screenshot != nil {
                        TextField("Hvad vil du vide om skærmen?", text: $question, axis: .vertical)
                            .lineLimit(2...5).padding(14).fadedGlassSurface()
                    }
                    if configuration != nil {
                        FadedPrimaryButton("Spørg " + bot.name, icon: "text.bubble") { ask(question) }
                            .disabled(asking || connecting || connectionFailed || status?.canRead != true || question.unicodeScalars.count > 500 || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if asking { ProgressView("Læser den delte skærm…") }
                        if !answer.isEmpty {
                            FadedCard { Text(answer).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        }
                        FadedSecondaryButton("Stop skærmdeling", icon: "stop.circle") { stop() }
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    screenshotCard
                    if let problem = dictation.problem { Text(problem).foregroundStyle(.secondary) }
                }.padding(FadedSpacing.edge)
            }.background { FadedBackground() }
                .navigationTitle("Del min skærm").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { stop(); dismiss() } } }
        }
        .privacySensitive()
        .sheet(isPresented: $readingScreenshot) {
            if let screenshot { LocalImageAnalysisView(data: screenshot, onChooseNote: nil, api: api, initialPrompt: question) }
        }
        .task { reconnect() }
        .onChange(of: phase) { _, next in setPaused(next != .background) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in setPaused(true) }
        .onChange(of: voice) { _, enabled in
            if enabled { listen() } else {
                voiceJob?.cancel(); stopListening(); speech.stop(); pcSpeech.stop(); speakingTurn = false
            }
        }
        .onChange(of: voiceDraft) { _, text in
            voiceJob?.cancel()
            guard voice, !asking, !speakingTurn, speech.playback == nil, !pcSpeech.playing, !pcSpeech.loading else { return }
            voiceJob = Task {
                do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if ["stop deling", "stop skærmdeling", "afslut deling"].contains(text.lowercased()) { stop() }
                else { ask(text) }
            }
        }
        .onChange(of: dictation.active) { _, active in
            if !active, dictation.problem != nil { voice = false; return }
            if !active { listen() }
        }
        .onReceive(speech.$playback) { playback in if playback == nil { resumeAfterSpeech() } }
        .onReceive(pcSpeech.$playing) { playing in if !playing { resumeAfterSpeech() } }
        .onReceive(pcSpeech.$loading) { loading in if !loading { resumeAfterSpeech() } }
        .onReceive(pcSpeech.$notice) { problem in
            if problem != nil {
                notice = "Oplæsningen kunne ikke starte. Svaret står i samtalen."
                resumeAfterSpeech()
            }
        }
        .onDisappear { stop() }
    }

    private var screenshotCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Brug et skærmbillede").font(.headline)
                ChatPhotoPicker(photo: $screenshot, loading: $loadingScreenshot,
                                onError: { notice = $0 }, addTitle: "Vælg skærmbillede")
                if let screenshot {
                    if let useScreenshot {
                        FadedSecondaryButton("Vedhæft i chatten med " + bot.name, icon: "bubble.left.and.bubble.right") {
                            stop()
                            useScreenshot(screenshot, question)
                            dismiss()
                        }.disabled(loadingScreenshot)
                    }
                    FadedSecondaryButton("Læs skærmbilledet", icon: "text.viewfinder") {
                        readingScreenshot = true
                    }.disabled(loadingScreenshot)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reconnect() {
        guard api != nil, !stopping else { return }
        let previous = connectionJob
        previous?.cancel()
        let run = UUID()
        connectionRun = run
        connecting = true
        connectionFailed = false
        notice = nil
        connectionJob = Task {
            // Finish any scoped create/cleanup before a replacement can invalidate it.
            _ = await previous?.result
            guard !Task.isCancelled, !stopping, connectionRun == run else { return }
            await beginAndPoll(run: run)
        }
    }

    private func beginAndPoll(run: UUID) async {
        guard let api else { return }
        defer { if connectionRun == run { connecting = false } }
        do {
            if configuration == nil {
                for attempt in 0..<3 {
                    do {
                        configuration = try await createConfiguration(api: api)
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard retryable(error), attempt < 2 else { throw error }
                        notice = "PC’en svarer ikke endnu. Prøver igen…"
                        try await Task.sleep(for: .seconds(1 << attempt))
                    }
                }
            }
            try Task.checkCancellation()
            guard let config = configuration, !stopping else { return }
            var failures = 0
            while !Task.isCancelled, configuration?.id == config.id {
                do {
                    let fresh: Status = try await api.moduleJSON("phone-screen/" + config.id, timeout: 10)
                    try Task.checkCancellation()
                    guard configuration?.id == config.id else { return }
                    status = fresh
                    if failures > 0 || connecting { notice = nil }
                    connecting = false
                    failures = 0
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    try Task.checkCancellation()
                    if case APIError.http(409, _) = error {
                        discardConfiguration(id: config.id)
                        await endSession(config.id, api: api)
                    }
                    failures += 1
                    guard retryable(error), failures < 4 else { throw error }
                    connecting = true
                    notice = "Forbindelsen blev afbrudt. Genopretter skærmhjælpen…"
                    try await Task.sleep(for: .seconds(1 << (failures - 1)))
                }
            }
        } catch is CancellationError { return }
        catch {
            if !Task.isCancelled, connectionRun == run, !stopping {
                connectionFailed = true
                voice = false
                stopListening()
                if let setupError = error as? PhoneBroadcastConfiguration.SetupError {
                    notice = setupError.localizedDescription
                } else {
                    notice = Self.explanation(error, fallback: "Skærmhjælpen kunne ikke få forbindelse. Tjek, at FadedAI kører på PC’en, og prøv igen.")
                }
            }
        }
    }

    private static func explanation(_ error: Error, fallback: String) -> String {
        if case .http(_, let problem)? = error as? APIError, let message = problem?.message, !message.isEmpty { return message }
        if case .transport? = error as? APIError { return APIError.offline.title }
        if case .offline? = error as? APIError { return APIError.offline.title }
        return fallback
    }

    private func createConfiguration(api: LiveAPI) async throws -> PhoneBroadcastConfiguration {
        guard PhoneBroadcastConfiguration.hasSharedContainer else {
            throw PhoneBroadcastConfiguration.SetupError.sharedContainerUnavailable
        }
        // An unstructured create is allowed to return its id after cancellation, so
        // the canceled view can still delete exactly the session it just created.
        let creation = Task { () async throws -> Started in
            try await api.moduleJSON("phone-screen", upload: JSONEncoder().encode(["bot_id": bot.id.uuidString]), timeout: 15)
        }
        let start = try await creation.value
        do {
            try Task.checkCancellation()
            guard !stopping, start.path == "/api/modules/v1/phone-screen/\(start.id)/frame",
                  UUID(uuidString: start.id) != nil,
                  let url = URL(string: api.server.origin.absoluteString + start.path) else { throw APIError.malformed }
            let config = PhoneBroadcastConfiguration(id: start.id, endpoint: url, token: start.uploadToken, expires: start.expires)
            try config.save()
            try Task.checkCancellation()
            return config
        } catch {
            if PhoneBroadcastConfiguration.read()?.id == start.id { PhoneBroadcastConfiguration.clear() }
            await endSession(start.id, api: api)
            throw error
        }
    }

    private func endSession(_ id: String, api: LiveAPI) async {
        guard UUID(uuidString: id) != nil else { return }
        let cleanup = Task {
            struct Receipt: Decodable { let stopped: Bool }
            let _: Receipt? = try? await api.moduleJSON("phone-screen/" + id + "/stop", upload: Data("{}".utf8), timeout: 8)
        }
        _ = await cleanup.result
    }

    private func retryable(_ error: Error) -> Bool {
        if case APIError.http(let code, _) = error { return code == 408 || code == 429 || code >= 500 }
        if case APIError.offline = error { return true }
        if case APIError.transport = error { return true }
        if case APIError.malformed = error { return false }
        return error is URLError
    }

    private func discardConfiguration(id: String) {
        guard configuration?.id == id else { return }
        voice = false
        voiceJob?.cancel()
        cancelQuestion()
        stopListening()
        speech.stop()
        pcSpeech.stop()
        speakingTurn = false
        if PhoneBroadcastConfiguration.read()?.id == id { PhoneBroadcastConfiguration.clear() }
        configuration = nil
        status = nil
    }

    private func setPaused(_ paused: Bool) {
        guard var config = configuration, let api, !stopping else { return }
        guard PhoneBroadcastConfiguration.read()?.id == config.id else { stop(); return }
        config.paused = paused
        do {
            try config.save()
        } catch {
            stop()
            notice = "Skærmdelingen blev stoppet. " + error.localizedDescription
            return
        }
        configuration = config
        let previous = screenControl
        screenControl = Task {
            _ = await previous?.result
            guard !Task.isCancelled, let latest = configuration, latest.id == config.id else { return }
            struct State: Decodable { let frozen: Bool }
            let _: State? = try? await api.moduleJSON("phone-screen/" + latest.id + (latest.paused ? "/freeze" : "/resume"),
                                                    upload: Data("{}".utf8))
        }
    }

    private func ask(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let config = configuration, let api, !asking, !connectionFailed, !clean.isEmpty, clean.unicodeScalars.count <= 500 else { return }
        guard !connecting, status?.canRead == true else {
            question = clean
            notice = connecting ? "Venter på forbindelsen til PC’en." : status?.message
            return
        }
        asking = true
        let run = UUID()
        answerRun = run
        notice = nil
        voiceJob?.cancel()
        stopListening()
        answerJob = Task {
            let background = ScreenBackgroundLease {
                guard self.answerRun == run else { return }
                self.answerJob?.cancel()
                self.notice = "iPhone satte skærmhjælpen på pause. Åbn FadedAI, og stil spørgsmålet igen."
            }
            defer {
                background.end()
                if answerRun == run {
                    asking = false
                    answerJob = nil
                    resumeAfterSpeech()
                }
            }
            do {
                struct Reply: Decodable { let reading: String; let capturedAt: Double }
                let reply: Reply = try await api.moduleJSON("phone-screen/" + config.id + "/ask",
                    upload: JSONEncoder().encode(["question": clean]), timeout: 125)
                try Task.checkCancellation()
                guard answerRun == run, configuration?.id == config.id else { return }
                answer = reply.reading
                if voice { speak(reply.reading) }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { notice = Self.explanation(error, fallback: "Kunne ikke læse skærmen. Prøv igen, eller vælg et skærmbillede.") } }
        }
    }

    private func cancelQuestion() {
        answerRun = UUID()
        answerJob?.cancel()
        answerJob = nil
        asking = false
        answer = ""
    }

    private func listen() {
        guard voice, configuration != nil, !asking, !speakingTurn, microphoneJob == nil,
              !dictation.active, speech.playback == nil, !pcSpeech.playing, !pcSpeech.loading else { return }
        voiceDraft = ""
        let run = UUID()
        microphoneRun = run
        microphoneJob = Task {
            defer { if microphoneRun == run { microphoneJob = nil } }
            guard !Task.isCancelled, microphoneRun == run, voice, configuration != nil,
                  !asking, !speakingTurn, speech.playback == nil, !pcSpeech.playing, !pcSpeech.loading else { return }
            await dictation.start(conversation: true) { self.voiceDraft = $0 }
        }
    }

    private func stopListening() {
        microphoneRun = UUID()
        microphoneJob?.cancel()
        microphoneJob = nil
        dictation.stop()
    }

    private func resumeAfterSpeech() {
        // @Published emits before assigning. Read the final playback state on the
        // next actor turn rather than reopening the microphone during TTS setup.
        Task { @MainActor in
            guard speech.playback == nil, !pcSpeech.playing, !pcSpeech.loading else { return }
            speakingTurn = false
            listen()
        }
    }

    private func speak(_ text: String) {
        speakingTurn = true
        stopListening()
        let id = AgentVoiceSelection.identifier(for: bot)
        if let local = DownloadedAgentVoice.selected(id) {
            pcSpeech.playDownloaded(text: text, voice: local, agentID: bot.id,
                                   language: bot.language ?? "da-DK", rate: bot.voiceRate ?? 1)
        } else if let pcVoice = AgentPCVoice(rawValue: id), let api {
            let spoken = text.count > 450 ? String(text.prefix(450)) + " Resten står i samtalen." : text
            pcSpeech.playAgentVoice(text: spoken, voice: pcVoice, agentID: bot.id, pc: api)
        } else if let selected = AgentVoiceSelection.resolve(identifier: id, language: bot.language ?? "da-DK") {
            speech.play(LocalSpeechVoice.utterance(text, voice: selected, rate: bot.voiceRate ?? 1), as: .preview, agentID: bot.id)
        } else {
            voice = false
            speakingTurn = false
            notice = "Vælg en stemme til agenten for at høre svaret. Svaret står her i samtalen."
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        voice = false
        voiceJob?.cancel()
        cancelQuestion()
        screenControl?.cancel()
        connectionJob?.cancel()
        connectionRun = UUID()
        connecting = false
        connectionFailed = false
        stopListening()
        speech.stop()
        pcSpeech.stop()
        speakingTurn = false
        if let config = configuration, let api {
            Task { await endSession(config.id, api: api) }
        }
        if let config = configuration, PhoneBroadcastConfiguration.read()?.id == config.id {
            PhoneBroadcastConfiguration.clear()
        }
        configuration = nil
        status = nil
    }
}

@MainActor private final class ScreenBackgroundLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(expired: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "FadedAI skærmhjælp") { [weak self] in
            Task { @MainActor in
                guard let self, self.identifier != .invalid else { return }
                self.end()
                expired()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private struct PhoneBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let folders = Bundle.main.builtInPlugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        view.preferredExtension = folders.compactMap(Bundle.init(url:)).first {
            ($0.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
        }?.bundleIdentifier
        view.showsMicrophoneButton = false
        return view
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
