import Foundation
import AVFAudio
import SwiftUI

extension LumiStudio {
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
        let identifier = AgentVoiceSelection.lumiIdentifier(profile: inheritedVoice, override: voiceOverride,
                                                           pcVoiceAvailable: lumiPCVoiceReady)
        let pcVoice = AgentPCVoice(rawValue: identifier)
        let voice = AgentVoiceSelection.resolve(identifier: identifier, language: locale)
        let local = DownloadedAgentVoice.selected(identifier)
        let name = local?.name ?? pcVoice?.name ?? voice?.name
        return VStack(alignment: .leading, spacing: 2) {
            Button(name.map { "Læs med " + $0 } ?? "Vælg en stemme", systemImage: "speaker.wave.2") {
                dictation.stop()
                let text = LocalSpeechVoice.replyText(text)
                speech.stop()
                if let local {
                    christel.playDownloaded(text: text, voice: local, agentID: VillageBot.lumiID, language: locale)
                    return
                }
                if let pcVoice {
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
                Picker("Svar på", selection: $language) {
                    Text("Dansk").tag("da-DK")
                    Text("English").tag("en-US")
                }
                .disabled(dictation.active)
                Spacer()
                Button(dictation.active ? "Stop" : "Diktér", systemImage: dictation.active ? "stop.circle" : "mic") {
                    if dictation.active {
                        dictation.finishInput()
                    } else {
                        speech.stop()
                        christel.stop()
                        let locale = language
                        let revision = sceneRevision
                        Task {
                            guard phase == .active, mode == 0, sceneRevision == revision else { return }
                            await dictation.startInChat(language: locale, draft: { draft }) { if sceneRevision == revision { draft = $0 } }
                        }
                    }
                }
                .frame(minHeight: 44)
                .accessibilityLabel(dictation.microphoneLabel)
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
                ProgressView("Gør oplæsningen klar…").font(.caption)
            }
            if let notice = christel.notice {
                FadedDetailText(notice)
            }
            if let status = dictation.offlineStatus { FadedDetailText(status) }
            else if let problem = dictation.problem {
                Text(problem).font(.caption).foregroundStyle(palette.secondary)
            } else if dictation.hasTranscript {
                Text("Du kan rette teksten, før du sender.").font(.caption).foregroundStyle(palette.secondary)
            }
        }
    }
}
