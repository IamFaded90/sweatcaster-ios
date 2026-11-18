import AVFAudio
import FadedAIWhisperRuntime
import SwiftUI

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
                        Text("\(stamp(segment.started)) – \(stamp(segment.ended))")
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

    private func stamp(_ seconds: Double) -> String {
        let rounded = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
