import AVFAudio
import FadedAIWhisperRuntime
import SwiftUI
import UniformTypeIdentifiers

extension AgentPhoneChat {
    func selectRequestedAdamVoiceIfAvailable() async {
        let key = PhoneModels.agentVoiceKey(bot.id)
        guard bot.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "adam",
              bot.voice == "da-DK", voiceOverride.isEmpty,
              UserDefaults.standard.object(forKey: key) == nil, let api else { return }
        guard let choices = try? await api.agentPCVoices(), choices.contains(.roestMic),
              voiceOverride.isEmpty, UserDefaults.standard.object(forKey: key) == nil else { return }
        voiceOverride = AgentPCVoice.roestMic.rawValue
    }

    var voiceActions: some View {
        let isDanish = AgentWhisper.languageCode(dictationLanguage) == "da"
        let installedModels = whisper.installedModels
        let offlineReady = !AgentWhisper.availableModels(for: dictationLanguage, installed: installedModels.contains).isEmpty
        return HStack {
            Menu("Stemme", systemImage: "mic") {
                Picker("Jeg taler", selection: $dictationLanguage) {
                    Text("Dansk").tag("da-DK")
                    Text("Engelsk").tag("en-US")
                }
                Picker("Pause før håndfri afsendelse", selection: $voicePauseSeconds) {
                    Text("Kort · 1,4 sek.").tag(1.4)
                    Text("Normal · 2,5 sek.").tag(2.5)
                    Text("God tid · 4 sek.").tag(4.0)
                }
                if offlineReady {
                    Button(isDanish ? "Diktér dansk offline" : "Diktér engelsk offline") { dictateWithWhisper() }
                }
                if isDanish, !installedModels.contains(.danish) {
                    Button("Hent dansk offline-model · 264 MB") { installWhisper(.danish) }
                        .disabled(whisper.installing)
                }
                if !installedModels.contains(.base) {
                    Button("Hent lille offline-model · 60 MB") { installWhisper(.base) }
                        .disabled(whisper.installing)
                }
                if isDanish, !installedModels.contains(.small) {
                    Button("Hent flersproget offline-model · 190 MB") { installWhisper(.small) }
                        .disabled(whisper.installing)
                }
                Button("Diktér med Apple") { dictateWithApple() }
                Button("Start håndfri samtale") { startHandsFree(offline: false) }
                if offlineReady {
                    Button("Håndfri med offline diktering") { startHandsFree(offline: true) }
                }
                Button("Vælg og hør stemme") { stopVoice(); showVoice = true }
                if !whisper.segments.isEmpty {
                    Button("Se seneste diktering med tider") { showTranscript = true }
                }
                if api != nil, keepHistory {
                    Button("Transskribér en optagelse på PC", systemImage: "waveform") {
                        showRecordingTranscript = true
                    }
                }
                ForEach(installedModels, id: \.rawValue) { model in
                    Button("Slet \(model.title)", systemImage: "trash", role: .destructive) {
                        whisper.deletionChoice = model
                    }.disabled(whisper.installing)
                }
            }
            .disabled(whisper.starting || whisper.active || whisper.processing || appleDictation.active || handsFree || running != nil)
            if handsFree {
                if waitingForVoice {
                    Button("Afbryd og tal", systemImage: "mic") {
                        if kokoro.loading || kokoro.playing {
                            kokoro.stop()
                            finishPCReading()
                        } else { speech.stop() }
                    }
                }
                Button("Stop samtale", systemImage: "stop.circle") { stopVoice() }
            } else if whisper.active {
                Button("Stop og skriv tekst", systemImage: "stop.circle") { finishWhisper() }
            } else if appleDictation.active {
                Button("Stop diktering", systemImage: "stop.circle") { appleDictation.stop() }
            }
            if whisper.processing { ProgressView("Whisper skriver…") }
            else if whisper.installing {
                ProgressView("Henter Whisper…")
                Button("Stop hentning", action: whisper.cancelInstallation).frame(minHeight: 44)
            }
            else if appleDictation.active || whisper.active {
                Text(dictationLanguage == "en-US" ? "Lytter på engelsk…" : "Lytter på dansk…")
            }
        }
        .font(.caption)
        .confirmationDialog("Slet offline-modellen?", isPresented: Binding(
            get: { whisper.deletionChoice != nil }, set: { if !$0 { whisper.deletionChoice = nil } }
        ), presenting: whisper.deletionChoice) { model in
            Button("Slet \(model.title)", role: .destructive) { deleteWhisperModel(model) }
        } message: { _ in
            Text("Modelfilen fjernes fra telefonen og kan hentes igen.")
        }
    }

    var voiceSettings: some View {
        AgentVoicePicker(botID: bot.id, name: bot.name, inheritedVoice: bot.voice, rate: bot.voiceRate ?? 1,
                         api: api, selection: $voiceOverride, language: $spokenLanguage)
    }

    func dictateWithApple() {
        let prefix = draft.isEmpty ? "" : draft + " "
        speech.stop()
        let run = UUID()
        voiceRun = run
        listeningTask = Task {
            await appleDictation.start(language: dictationLanguage, contextualStrings: dictationVocabulary) { text in
                guard voiceRun == run, phase == .active else { return }
                draft = String((prefix + text).prefix(web ? 500 : 1_200))
            }
            guard voiceRun == run, !Task.isCancelled else { return }
            if let problem = appleDictation.problem { notice = problem + " Du kan også vælge Whisper i stemmemenuen." }
        }
    }

    func installWhisper(_ model: AgentWhisper.Model = .base) {
        Task {
            do {
                try await whisper.install(model)
                notice = model == .danish ? "Dansk diktering er klar i flytilstand." : "Offline-diktering er klar i flytilstand."
            } catch is CancellationError {
                notice = "Hentningen blev stoppet."
            } catch let error as URLError where error.code == .cancelled {
                notice = "Hentningen blev stoppet."
            } catch { notice = "Whisper kunne ikke hentes. Tjek netværket og den ledige plads." }
        }
    }

    private func deleteWhisperModel(_ model: AgentWhisper.Model) {
        do {
            try whisper.removeModel(model)
            notice = "Offline-modellen er slettet fra telefonen."
        } catch LocalComputeError.busy {
            notice = "Vent til den lokale opgave eller hentning er færdig."
        } catch {
            AppDiagnostics.record(error)
            notice = "Offline-modellen kunne ikke slettes."
        }
    }

    func dictateWithWhisper() {
        speech.stop()
        let run = UUID()
        let language = dictationLanguage
        voiceRun = run
        listeningTask = Task {
            do { try await whisper.start(language: language, whenFull: finishWhisper) }
            catch {
                guard voiceRun == run, !Task.isCancelled else { return }
                notice = "Whisper kunne ikke bruge mikrofonen. Tjek iPhone-tilladelser."
            }
        }
    }

    func finishWhisper() {
        let run = voiceRun
        let prefix = draft
        let language = dictationLanguage
        Task {
            guard whisper.active, !whisper.processing, voiceRun == run else { return }
            do {
                let text = try await whisper.finish(language: language)
                guard voiceRun == run, phase == .active else { return }
                if text.isEmpty {
                    if handsFreeOffline { stopVoice() }
                    notice = "Whisper hørte ingen ord."
                }
                else if draft == prefix {
                    draft = String(([prefix, text].filter { !$0.isEmpty }.joined(separator: " ")).prefix(web ? 500 : 1_200))
                    if handsFreeOffline && handsFree {
                        send(message: cleanDraft, source: .phone, model: selectedModel, asCard: answerAsCard)
                    }
                } else {
                    if handsFreeOffline { handsFree = false; handsFreeOffline = false }
                    notice = "Tekstfeltet blev ændret under diktering. Teksten findes under Seneste diktering."
                }
            } catch is CancellationError {
                return
            } catch LocalComputeError.lowMemory {
                guard voiceRun == run, phase == .active else { return }
                stopVoice()
                notice = "iPhone mangler fri hukommelse til Whisper. Prøv igen, eller hent modellen på 60 MB."
            } catch {
                if voiceRun == run, phase == .active {
                    stopVoice()
                    notice = "Whisper kunne ikke skrive optagelsen. Prøv igen."
                }
            }
        }
    }

    private func startHandsFree(offline: Bool) {
        let model = offline ? selectedModel : currentModel
        guard cleanDraft.isEmpty, !model.isEmpty, running == nil else {
            notice = "Vælg en model, og send eller ryd kladden, før du starter håndfri samtale."
            return
        }
        speech.stop()
        kokoro.stop()
        if offline { source = .phone; web = false }
        handsFreeOffline = offline
        handsFree = true
        listenHandsFree()
    }

    func listenHandsFree() {
        guard handsFree, phase == .active, !appleDictation.active,
              !whisper.starting, !whisper.active, !whisper.processing else { return }
        let run = UUID()
        voiceRun = run
        if handsFreeOffline {
            let language = dictationLanguage
            listeningTask = Task {
                do { try await whisper.start(language: language, silenceAfter: voicePauseSeconds, whenFull: finishWhisper) }
                catch {
                    guard voiceRun == run, !Task.isCancelled else { return }
                    stopVoice()
                    notice = "Whisper kunne ikke bruge mikrofonen. Tjek iPhone-tilladelser."
                }
            }
            return
        }
        listeningTask = Task {
            await appleDictation.start(language: dictationLanguage, contextualStrings: dictationVocabulary) { text in
                guard handsFree, voiceRun == run, phase == .active else { return }
                draft = String(text.prefix(web ? 500 : 1_200))
                voiceSilence?.cancel()
                voiceSilence = Task {
                    let pause = voicePauseSeconds.isFinite ? min(4, max(1.4, voicePauseSeconds)) : 2.5
                    try? await Task.sleep(for: .milliseconds(Int(pause * 1_000)))
                    guard !Task.isCancelled, handsFree, voiceRun == run, phase == .active, !cleanDraft.isEmpty else { return }
                    appleDictation.stop()
                    send()
                }
            }
            guard voiceRun == run, !Task.isCancelled else { return }
            if let problem = appleDictation.problem {
                stopVoice()
                notice = problem
            }
        }
    }

    func stopVoice() {
        voiceRun = UUID()
        handsFree = false
        handsFreeOffline = false
        waitingForVoice = false
        voiceSilence?.cancel()
        listeningTask?.cancel()
        appleDictation.stop()
        whisper.cancel()
        speech.stop()
        kokoro.stop()
        pcVoiceReplyID = nil
    }

    func finishPCReading() {
        pcVoiceReplyID = nil
        if waitingForVoice && handsFree && kokoro.notice == nil {
            waitingForVoice = false
            listenHandsFree()
        }
    }

    func readReply(_ turn: PrivateChatTurn) {
        if speech.playback == .reply(turn.id) {
            speech.stop()
            return
        }
        if pcVoiceReplyID == turn.id, kokoro.playing || kokoro.loading {
            kokoro.stop()
            finishPCReading()
            return
        }
        let text = LocalSpeechVoice.replyText(turn.reply)
        let identifier = voiceOverride.isEmpty ? bot.voice : voiceOverride
        if let local = DownloadedAgentVoice.selected(identifier) {
            speech.stop()
            pcVoiceReplyID = turn.id
            kokoro.playDownloaded(text: text, voice: local, agentID: bot.id,
                                  language: LocalSpeechVoice.detectedReplyLanguage(text) ?? "da-DK", rate: bot.voiceRate ?? 1)
            notice = kokoro.notice ?? "Læser med " + local.label
            return
        }
        if let voice = AgentPCVoice(rawValue: identifier) {
            guard let api, !handsFreeOffline else {
                stopVoice()
                notice = "Vælg en iPhone-stemme til offline samtale, eller forbind PC’en."
                return
            }
            speech.stop()
            pcVoiceReplyID = turn.id
            notice = "Læser med " + voice.label
            kokoro.playAgentVoice(text: text, voice: voice, agentID: bot.id, pc: api)
            return
        }
        kokoro.stop()
        let locale = LocalSpeechVoice.detectedReplyLanguage(text) ?? bot.language ?? "da-DK"
        guard let voice = AgentVoiceSelection.resolve(identifier: identifier, language: locale) else {
            stopVoice()
            notice = AgentVoiceSelection.unavailable
            return
        }
        notice = "Læser med " + LocalSpeechVoice.label(voice)
        speech.play(LocalSpeechVoice.utterance(text, voice: voice, rate: bot.voiceRate ?? 1), as: .reply(turn.id), agentID: bot.id)
    }

    func kokoroMenu(_ turn: PrivateChatTurn, api: LiveAPI) -> some View {
        Menu("Engelsk oplæsning på PC", systemImage: "waveform") {
            if kokoro.playing || kokoro.loading {
                Button("Stop Kokoro", systemImage: "stop.circle") { kokoro.stop() }
            }
            Button("Heart · Kokoro") { readKokoro(turn, voice: "af_heart", api: api) }
            Button("Michael · Kokoro") { readKokoro(turn, voice: "am_michael", api: api) }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
    }

    private func readKokoro(_ turn: PrivateChatTurn, voice: String, api: LiveAPI) {
        stopVoice()
        kokoro.playKokoro(text: LocalSpeechVoice.replyText(turn.reply), voice: voice, agentID: bot.id, pc: api)
    }

    private var dictationVocabulary: [String] {
        [bot.name, "FadedAI", "Landsbyen", "Fortnite", "The Finals"]
    }

}

struct AgentDictationTranscript: View {
    let segments: [LocalWhisperEngine.Segment]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Self.stamp(segment.started)) – \(Self.stamp(segment.ended))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(verbatim: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .textSelection(.enabled)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Seneste diktering")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .privacySensitive()
        }
    }

    static func stamp(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return String(format: "%d:%02d,%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

struct AgentRecordingTranscript: View {
    struct Recording: Decodable {
        struct Cue: Decodable {
            let start, end: Double
            let text: String
            let channel: Int?
        }
        let separateChannels: Bool
        let cues: [Cue]
    }
    let api: LiveAPI
    let language: String
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var separate = false
    @State private var selection: URL?
    @State private var busy = false
    @State private var recording: Recording?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Én mikrofon på hver lydkanal", isOn: $separate)
                    Button("Vælg optagelse", systemImage: "waveform") { showPicker = true }
                } footer: {
                    Text("Vælg en WAV- eller M4A-fil på højst 45 sekunder. Din parrede PC genkender talen på \(language == "en" ? "engelsk" : "dansk"). Slå kanalvalg til, hvis mikrofonerne blev optaget hver for sig.")
                }
                .disabled(busy)
                if busy { ProgressView("PC’en lytter til optagelsen…") }
                if let notice { Text(verbatim: notice) }
                if let recording {
                    Section(recording.separateChannels ? "Separate lydkanaler" : "Samlet lyd") {
                        if recording.cues.isEmpty { Text("Ingen tydelig tale i optagelsen.") }
                        ForEach(Array(recording.cues.enumerated()), id: \.offset) { _, cue in
                            VStack(alignment: .leading, spacing: 4) {
                                let time = "\(AgentDictationTranscript.stamp(cue.start)) – \(AgentDictationTranscript.stamp(cue.end))"
                                Text(verbatim: cue.channel.map { "Kanal \($0) · " + time } ?? time)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(verbatim: cue.text).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Lyd til tekst")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: ["wav", "m4a"].compactMap { UTType(filenameExtension: $0) }) { result in
                switch result {
                case .success(let url): selection = url
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { notice = "Filen kunne ikke åbnes." }
                }
            }
            .task(id: selection) {
                guard let url = selection else { return }
                busy = true
                recording = nil
                notice = nil
                defer { busy = false; selection = nil }
                do {
                    let result = try await transcribe(url)
                    try Task.checkCancellation()
                    recording = result
                } catch {
                    guard !Task.isCancelled else { return }
                    if case APIError.http(404, _) = error { notice = "Opdatér FadedAI på PC’en for at læse optagelser." }
                    else if case let APIError.http(_, problem) = error, let message = problem?.message { notice = message }
                    else if case LocalFileStore.Failure.tooLarge = error { notice = "Vælg en optagelse på højst 18 MB." }
                    else { notice = AppErrorPresentation(error).title }
                }
            }
            .privacySensitive()
        }
    }

    private func transcribe(_ url: URL) async throws -> Recording {
        let kind = url.pathExtension.lowercased()
        guard ["wav", "m4a"].contains(kind) else { throw APIError.input }
        let content = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try LocalFileStore.readBytes(from: url, maximumBytes: 18_000_000)
        }.value
        try Task.checkCancellation()
        let endpoint = api.server.origin.appending(path: "api/modules/v1/agent-recording/" + kind)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "language", value: language),
                                  .init(name: "separate", value: separate ? "true" : "false")]
        guard let target = components?.url else { throw APIError.input }
        var request = api.request(target, method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = content
        request.timeoutInterval = 175
        let (body, response) = try await api.loggedData(for: request)
        try api.checked(response, expected: 200, data: body)
        guard body.count < 192_000 else { throw APIError.malformed }
        let result = try JSONDecoder().decode(Recording.self, from: body)
        guard result.cues.allSatisfy({ cue in
            let validChannel = result.separateChannels ? (cue.channel == 1 || cue.channel == 2) : cue.channel == nil
            return validChannel && cue.start >= 0 && cue.start < cue.end && cue.end <= 45
        }) else { throw APIError.malformed }
        return result
    }
}
