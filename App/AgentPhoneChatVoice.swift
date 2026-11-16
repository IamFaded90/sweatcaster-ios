import AVFAudio
import FadedAIWhisperRuntime
import SwiftUI

extension AgentPhoneChat {
    var voiceActions: some View {
        HStack {
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
                Button("Diktér med Apple") { dictateWithApple() }
                if AgentWhisper.ready {
                    Button("Diktér med Whisper") { dictateWithWhisper() }
                } else {
                    Button("Hent Whisper · ca. 60 MB") { installWhisper() }.disabled(whisper.installing)
                }
                Button("Start håndfri samtale") {
                    guard cleanDraft.isEmpty, !currentModel.isEmpty, running == nil else {
                        notice = "Send eller ryd den nuværende besked, før du starter håndfri samtale."
                        return
                    }
                    handsFree = true
                    listenHandsFree()
                }
                Button("Vælg og hør stemme") { stopVoice(); showVoice = true }
                if !whisper.segments.isEmpty {
                    Button("Se seneste diktering med tider") { showTranscript = true }
                }
            }
            .disabled(whisper.active || whisper.processing || appleDictation.active || handsFree || running != nil)
            if handsFree {
                if waitingForVoice {
                    Button("Afbryd og tal", systemImage: "mic") { speech.stop() }
                }
                Button("Stop samtale", systemImage: "stop.circle") { stopVoice() }
            } else if whisper.active {
                Button("Stop og skriv tekst", systemImage: "stop.circle") { finishWhisper() }
            } else if appleDictation.active {
                Button("Stop diktering", systemImage: "stop.circle") { appleDictation.stop() }
            }
            if whisper.processing { ProgressView("Whisper skriver…") }
            else if whisper.installing { ProgressView("Henter Whisper…") }
            else if appleDictation.active || whisper.active {
                Text(dictationLanguage == "en-US" ? "Lytter på engelsk…" : "Lytter på dansk…")
            }
        }
        .font(.caption)
    }

    var voiceSettings: some View {
        AgentVoicePicker(botID: bot.id, name: bot.name, inheritedVoice: bot.voice, rate: bot.voiceRate ?? 1,
                         selection: $voiceOverride, language: $spokenLanguage)
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

    func installWhisper() {
        Task {
            do {
                try await whisper.install()
                notice = "Whisper er klar og kan bruges i flytilstand."
            } catch { notice = "Whisper kunne ikke hentes. Tjek netværket og den ledige plads." }
        }
    }

    func dictateWithWhisper() {
        speech.stop()
        voiceRun = UUID()
        listeningTask = Task {
            do { try await whisper.start(whenFull: finishWhisper) }
            catch { if !Task.isCancelled { notice = "Whisper kunne ikke bruge mikrofonen. Tjek iPhone-tilladelser." } }
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
                if text.isEmpty { notice = "Whisper hørte ingen ord." }
                else if draft == prefix {
                    draft = String(([prefix, text].filter { !$0.isEmpty }.joined(separator: " ")).prefix(web ? 500 : 1_200))
                } else { notice = "Tekstfeltet blev ændret under diktering. Optagelsen findes under Seneste diktering." }
            } catch is CancellationError {
                return
            } catch {
                if voiceRun == run, phase == .active { notice = "Whisper kunne ikke skrive optagelsen. Prøv igen." }
            }
        }
    }

    func listenHandsFree() {
        guard handsFree, phase == .active, !appleDictation.active else { return }
        let run = UUID()
        voiceRun = run
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
        waitingForVoice = false
        voiceSilence?.cancel()
        listeningTask?.cancel()
        appleDictation.stop()
        whisper.cancel()
        speech.stop()
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
