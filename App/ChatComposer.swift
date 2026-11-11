// Owns the fixed chat input, attachments, model menu and local speech controls.

import AVFAudio
import Foundation
import SwiftUI

struct ChatComposer<Content: View>: View {
    @Environment(\.fadedPalette) private var palette
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FadedRadius.card)
        VStack(alignment: .leading, spacing: FadedSpacing.xs) { content }
            .padding(.horizontal, FadedSpacing.s).padding(.vertical, FadedSpacing.xs)
            .background(palette.card, in: shape)
            .overlay { shape.strokeBorder(palette.border).allowsHitTesting(false) }
    }
}

extension ChatView {
    var quickModelPicker: some View { chatModelSelectionButton }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let deleted = removedTurns.last, deleted.expiresAt > ContinuousClock.now { undoBar }
            if let chatNotice { Text(chatNotice).font(.caption).foregroundStyle(palette.secondary) }
            if case .reply(_)? = speechBox.playback {
                HStack {
                    Label("Læser op på telefonen", systemImage: "speaker.wave.2").font(.subheadline)
                    Spacer(minLength: FadedSpacing.s)
                    Button("Stop oplæsning", systemImage: "stop.circle") { speechBox.stop() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
            ChatComposer {
                if let photo = stagedPhoto {
                    HStack(spacing: FadedSpacing.s) {
                        Image(uiImage: photo.preview).resizable().scaledToFill()
                            .frame(width: 36, height: 36).clipped().clipShape(.rect(cornerRadius: FadedRadius.small))
                            .accessibilityHidden(true)
                        Button("Analysér billede", action: analyzeStagedPhoto)
                            .frame(minHeight: 44).disabled(task != nil)
                        Spacer(minLength: 0)
                        Button("Fjern billede", systemImage: "xmark") { stagedPhoto = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let attachedNote {
                    HStack {
                        Label("Note: \(String(attachedNote.prefix(80)))", systemImage: "note.text")
                            .lineLimit(1)
                            .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button("Fjern note", systemImage: "xmark") { self.attachedNote = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let attachedQuote {
                    HStack {
                        Label("Citat: \(String(attachedQuote.prefix(80)))", systemImage: "quote.opening")
                            .lineLimit(1).font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                        Spacer()
                        Button("Fjern citat", systemImage: "xmark") { self.attachedQuote = nil }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Button("Flere handlinger", systemImage: "plus") {
                        composerFocused = false
                        choosingNote = false
                        newNote = ""
                        showComposerTools = true
                    }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(task != nil)
                    TextField("Skriv en besked…", text: $draft, axis: .vertical)
                        .lineLimit(1...4).frame(minHeight: 44).focused($composerFocused)
                        .dropDestination(for: StudioPhotoInput.self) { items, _ in acceptDroppedPhotos(items) }
                        .accessibilityHint("Træk et billede hertil for at analysere det")
                    dictationAction.disabled(task != nil)
                    sendControl
                }
                if let problem = dictation.problem { Text(problem).font(.caption).foregroundStyle(palette.secondary) }
            }

            HStack(alignment: .firstTextBaseline) {
                let destination = demo ? "Demo" : effectiveReplySource.rawValue
                let routeLabel = chatRouteModelTitle.map { "\(destination) · \($0)" } ?? destination
                Label(routeLabel, systemImage: demo ? "testtube.2" : effectiveReplySource.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(demo || !palette.isDark ? palette.secondary : sourceColor(effectiveReplySource))
                    .accessibilityLabel("Sendes til \(routeLabel)")
                if effectiveReplySource == .phone, phoneBatteryLevel >= 0, phoneBatteryLevel < 0.20,
                   PhoneModels.liteModeActive(for: phoneModel), resolvedRoute.modelID == PhoneModels.effectiveModelID(phoneModel) {
                    Label("Lite Mode", systemImage: "battery.25percent").font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Text("\(transportMessage.unicodeScalars.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(transportMessage.unicodeScalars.count > 2000 ? palette.coralText : palette.secondary)
                    .fixedSize()
            }
            if let modelRoutingNotice { FadedDetailText(modelRoutingNotice) }
            if !demo, effectiveReplySource == .phone, !PhoneModels.isReady(resolvedRoute.modelID ?? phoneModel) {
                FadedDetailText("Telefonmodellen er ikke klar. Din kladde bliver gemt.")
                FadedSecondaryButton("Åbn lokale modeller", icon: "iphone") { showPhoneModelSetup = true }
                    .disabled(task != nil)
            }
            if let sourceNote {
                Text(sourceNote).font(.caption).foregroundStyle(palette.secondary)
                pcRecoveryAction
            }
        }
        .padding(.horizontal, FadedSpacing.m).padding(.vertical, 6)
        .background(palette.background)
    }

    @ViewBuilder private var pcRecoveryAction: some View {
        if effectiveReplySource == .pc, !modelsLoading, task == nil {
            if (api == nil || pcEngineOffline), PhoneModels.isReady(PhoneModels.effectiveModelID(phoneModel)) {
                FadedSecondaryButton("Brug Telefon imens", icon: "iphone") { chooseModelForNextMessage(.phone) }
            } else if !canSendToSource, api is LiveAPI, !legacyChat {
                FadedSecondaryButton("Åbn PC-modeller", icon: "desktopcomputer") {
                    composerFocused = false
                    showPCModelSetup = true
                }
            }
        }
    }

    private var sendControl: some View {
        let sending = task != nil
        let allowed = sending || (stagedPhoto == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transportMessage.unicodeScalars.count <= 2000 && canSendToSource)
        return Button {
            if sending { stop() }
            else { send() }
        } label: {
            Image(systemName: sending ? "stop.fill" : (effectiveReplySource == .pc && canQueuePC ? "tray.and.arrow.down" : "arrow.up"))
                .font(.body.weight(.bold)).foregroundStyle(allowed ? FadedColors.deep : palette.secondary)
                .frame(width: 38, height: 38)
                .background(allowed ? palette.lime : palette.raised, in: RoundedRectangle(cornerRadius: FadedRadius.medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sending ? "Stop modtagelse" : (demo ? "Send testbesked" :
            (effectiveReplySource == .pc && canQueuePC ? "Sæt besked i udbakke til PC" : "Send til \(effectiveReplySource.rawValue)")))
        .disabled(!allowed)
    }

    private var dictationAction: some View {
        Button {
            if dictation.active { dictation.stop() }
            else {
                speechBox.stop()
                let prefix = draft.isEmpty ? "" : draft + " "
                Task { await dictation.start { draft = prefix + $0 } }
            }
        } label: {
            Image(systemName: dictation.active ? "stop.circle" : "mic")
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
    }

    private var voiceBots: [VillageBot] {
        (try? JSONDecoder().decode([VillageBot].self, from: MigratedAppData.shared.villageBots)) ?? []
    }

    var voiceControls: some View {
        let bots = voiceBots
        let hasBotVoice = bots.contains { $0.id.uuidString == voiceBotID }
        return DisclosureGroup("Oplæsning på telefonen") {
            Toggle("Læs færdige svar op", isOn: $voiceMode)
            if !bots.isEmpty {
                Picker("Botstemme", selection: $voiceBotID) {
                    Text("Valgt telefonstemme").tag("")
                    ForEach(bots) { bot in Text(bot.name).tag(bot.id.uuidString) }
                }
            }
            if !hasBotVoice {
                Picker("Oplæsningssprog", selection: $preferredVoiceLanguage) {
                    Text("Dansk").tag("da-DK")
                    Text("Engelsk").tag("en-US")
                }.onChange(of: preferredVoiceLanguage) { preferredVoiceID = "" }
                chatVoicePicker.id(availableVoiceRevision)
                Slider(value: $preferredVoiceRate, in: 0.7...1.3, step: 0.05).accessibilityLabel("Talehastighed")
                FadedDetailText("Tempo · \(preferredVoiceRate.formatted(.number.precision(.fractionLength(2))))×")
            }
            if let voice = chatSpeechVoice.0, voice.voiceTraits.contains(.isPersonalVoice) {
                FadedDetailText("Prøven følger stemmens sprog. Ved andet svar-sprog bruger chatten en passende systemstemme.")
            }
            Button(speechBox.playback == .preview ? "Stop stemmeprøve" : "Prøv stemme",
                   systemImage: speechBox.playback == .preview ? "stop.circle" : "play.circle", action: toggleVoicePreview)
                .frame(minHeight: 44)
            if case .reply(_)? = speechBox.playback {
                Button("Stop oplæsning", systemImage: "stop.circle") { speechBox.stop() }.frame(minHeight: 44)
            }
        }
        .onChange(of: preferredVoiceID) { stopVoicePreview() }
        .onChange(of: voiceBotID) { stopVoicePreview() }
        .onDisappear(perform: stopVoicePreview)
    }

    private var chatVoicePicker: some View {
        let voices = LocalSpeechVoice.options(language: preferredVoiceLanguage, includePersonalVoices: true)
        let selected = Binding(get: { voices.contains { $0.identifier == preferredVoiceID } ? preferredVoiceID : "" },
                               set: { preferredVoiceID = $0 })
        return Picker("Telefonstemme", selection: selected) {
            Text("Bedste tilgængelige").tag("")
            ForEach(voices, id: \.identifier) { voice in Text(LocalSpeechVoice.label(voice)).tag(voice.identifier) }
        }
    }

    func speak(_ text: String, turnID: UUID) {
        guard chatScenePhase == .active, !dictation.active,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let (voice, rate) = chatSpeechVoice
        let replyLanguage = aiLanguage == "Dansk" ? "da-DK" : aiLanguage == "Engelsk" ? "en-US" : nil
        let playbackVoice: AVSpeechSynthesisVoice?
        if let voice, voice.voiceTraits.contains(.isPersonalVoice), let replyLanguage,
           voice.language.split(separator: "-").first != replyLanguage.split(separator: "-").first {
            playbackVoice = LocalSpeechVoice.preferred(language: replyLanguage)
        } else {
            playbackVoice = voice
        }
        playChatSpeech(text, voice: playbackVoice, rate: rate, as: .reply(turnID))
    }

    private var chatSpeechVoice: (AVSpeechSynthesisVoice?, Double) {
        let bot = voiceBots.first { $0.id.uuidString == voiceBotID }
        let voice = LocalSpeechVoice.resolve(identifier: bot?.voice ?? preferredVoiceID,
                                             language: bot?.language ?? preferredVoiceLanguage)
        return (voice, bot.map { $0.voiceRate ?? 1 } ?? preferredVoiceRate)
    }

    private func toggleVoicePreview() {
        if speechBox.playback == .preview { speechBox.stop(); return }
        dictation.stop()
        let (voice, rate) = chatSpeechVoice
        let sample = LocalSpeechVoice.previewSentence(language: voice?.language ?? preferredVoiceLanguage)
        playChatSpeech(sample, voice: voice, rate: rate, as: .preview)
    }

    private func stopVoicePreview() {
        if speechBox.playback == .preview { speechBox.stop() }
    }

    private func playChatSpeech(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double, as playback: SpeechBox.Playback) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate.isFinite ? min(1.3, max(0.7, rate)) : 1)
        speechBox.play(utterance, as: playback)
    }
}
