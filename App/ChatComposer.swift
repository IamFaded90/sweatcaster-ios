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

    func composer(compact: Bool) -> some View {
        let inputLayout = compact
            ? AnyLayout(HStackLayout(spacing: FadedSpacing.xs))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: FadedSpacing.xs))
        return VStack(alignment: .leading, spacing: 6) {
            if !compact { composerNotices }
            ChatComposer {
                if !compact { composerAttachments }
                inputLayout {
                    TextField("Skriv til FadedAI…", text: $draft, axis: .vertical)
                        .lineLimit(1...(compact ? 1 : 4)).frame(minHeight: 44).focused($composerFocused)
                        .padding(.horizontal, FadedSpacing.xs)
                        .dropDestination(for: StudioPhotoInput.self) { items, _ in acceptDroppedPhotos(items) }
                        .accessibilityHint("Træk et billede hertil for at analysere det")
                    if compact {
                        composerIconButton("Skjul tastatur", icon: "keyboard.chevron.compact.down") {
                            composerFocused = false
                        }
                        sendControl
                    } else {
                        composerActions
                    }
                }
                if !compact, let problem = dictation.problem {
                    Text(problem).font(.caption).foregroundStyle(palette.secondary)
                }
            }
            if !compact { composerStatus }
        }
        .padding(.horizontal, FadedSpacing.m).padding(.vertical, 6)
        .background(palette.background)
    }

    @ViewBuilder private var composerNotices: some View {
        if let deleted = removedTurns.last, deleted.expiresAt > ContinuousClock.now { undoBar }
        if let chatNotice { Text(chatNotice).font(.caption).foregroundStyle(palette.secondary) }
        if case .reply(_)? = speechBox.playback {
            HStack(spacing: FadedSpacing.s) {
                if speechBox.isSpeaking {
                    AgentToolWave(status: "Læser op").accessibilityHidden(true)
                }
                Text(speechBox.voiceName.map { "Oplæsning · \($0)" } ?? "Oplæsning på iPhone")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
                Spacer(minLength: FadedSpacing.s)
                Button("Stop oplæsning", systemImage: "stop.circle") { speechBox.stop() }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    @ViewBuilder private var composerAttachments: some View {
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
    }

    @ViewBuilder private var composerStatus: some View {
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

    private var composerActions: some View {
        HStack(spacing: 0) {
            ChatResponseDepthButton(length: $aiLength).disabled(task != nil)
            ChatPhoneContextButton(onOpen: { composerFocused = false }, onChooseNote: contextAttachment)
                .disabled(demo || task != nil)
            composerIconButton("Vedhæft eller åbn chatværktøjer", icon: "paperclip", action: openAttachmentTools)
                .disabled(task != nil)
            dictationAction.disabled(task != nil)
            composerIconButton("Chatindstillinger", icon: "slider.horizontal.3", action: openComposerSettings)
            Spacer(minLength: 0)
            sendControl
        }
    }

    private func composerIconButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 38, height: 38)
                .fadedGlassSurface()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contextAttachment: ((String) -> Void)? {
        guard effectiveReplySource != .grok else { return nil }
        return { excerpt in
            let destination = effectiveReplySource
            guard destination != .grok, task == nil else { return }
            attachedNote = excerpt
            noteDestination = destination
        }
    }

    private func openAttachmentTools() {
        composerFocused = false
        choosingNote = false
        newNote = ""
        showComposerTools = true
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
                .frame(width: 38, height: 38)
                .fadedGlassSurface()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
    }

    private var voiceBots: [VillageBot] {
        VillageBot.list(from: MigratedAppData.shared.villageBots)
    }

    var voiceControls: some View {
        let bots = voiceBots
        let hasBotVoice = bots.contains { $0.id.uuidString == voiceBotID }
        let selectedVoice = chatSpeechVoice.0
        let effectiveVoice = LocalSpeechVoice.forReply(selectedVoice, language: configuredReplySpeechLanguage)
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
                }.onChange(of: preferredVoiceLanguage) {
                    if selectedVoice?.voiceTraits.contains(.isPersonalVoice) != true { preferredVoiceID = "" }
                    stopVoicePreview()
                }
                chatVoicePicker.id(availableVoiceRevision)
                Slider(value: $preferredVoiceRate, in: 0.7...1.3, step: 0.05).accessibilityLabel("Talehastighed")
                FadedDetailText("Tempo · \(preferredVoiceRate.formatted(.number.precision(.fractionLength(2))))×")
            }
            if let selectedVoice, let effectiveVoice, selectedVoice.identifier != effectiveVoice.identifier {
                FadedDetailText("Svar på \(effectiveVoice.language.hasPrefix("da") ? "dansk" : "engelsk") læses op med \(effectiveVoice.name).")
            } else if let effectiveVoice {
                FadedDetailText("Oplæsningsstemme · \(LocalSpeechVoice.label(effectiveVoice))")
            }
            if selectedVoice?.voiceTraits.contains(.isPersonalVoice) == true {
                FadedDetailText("Din personlige stemme bruges til svar på stemmens eget sprog.")
            } else if !hasBotVoice, !LocalSpeechVoice.options(language: preferredVoiceLanguage).contains(where: { $0.quality != .default }) {
                FadedDetailText(LocalSpeechVoice.downloadHint)
            }
            NavigationLink {
                Form { PersonalVoiceSettings() }
                    .navigationTitle("Personlig stemme")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("Personlig stemme", systemImage: "person.wave.2")
                    .frame(minHeight: 44)
            }
            Button(speechBox.playback == .preview ? "Stop stemmeprøve" : "Prøv oplæsningen",
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
        let personal = LocalSpeechVoice.personalVoices
        let system = LocalSpeechVoice.options(language: preferredVoiceLanguage)
        let selected = Binding(get: { (personal + system).contains { $0.identifier == preferredVoiceID } ? preferredVoiceID : "" },
                               set: { preferredVoiceID = $0 })
        return Picker("Telefonstemme", selection: selected) {
            Text("Bedste tilgængelige").tag("")
            if !personal.isEmpty {
                Section("Personlige stemmer") {
                    ForEach(personal, id: \.identifier) { voice in Text(LocalSpeechVoice.label(voice)).tag(voice.identifier) }
                }
            }
            Section("Stemmer på iPhone") {
                ForEach(system, id: \.identifier) { voice in Text(LocalSpeechVoice.label(voice)).tag(voice.identifier) }
            }
        }
    }

    func speak(_ text: String, turnID: UUID) {
        guard chatScenePhase == .active, !dictation.active,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let spoken = LocalSpeechVoice.replyText(text)
        let (voice, rate) = chatSpeechVoice
        let replyLanguage = configuredReplySpeechLanguage ?? LocalSpeechVoice.detectedReplyLanguage(spoken)
        let playbackVoice = LocalSpeechVoice.forReply(voice, language: replyLanguage)
        playChatSpeech(spoken, voice: playbackVoice, rate: rate, as: .reply(turnID))
    }

    private var chatSpeechVoice: (AVSpeechSynthesisVoice?, Double) {
        let bot = voiceBots.first { $0.id.uuidString == voiceBotID }
        let voice = LocalSpeechVoice.resolve(identifier: bot?.voice ?? preferredVoiceID,
                                             language: bot?.language ?? preferredVoiceLanguage)
        return (voice, bot.map { $0.voiceRate ?? 1 } ?? preferredVoiceRate)
    }

    private var configuredReplySpeechLanguage: String? {
        switch aiLanguage {
        case "Dansk": "da-DK"
        case "Engelsk": "en-US"
        default: nil
        }
    }

    private func toggleVoicePreview() {
        if speechBox.playback == .preview { speechBox.stop(); return }
        dictation.stop()
        let (voice, rate) = chatSpeechVoice
        let playbackVoice = LocalSpeechVoice.forReply(voice, language: configuredReplySpeechLanguage)
        let sampleLanguage = playbackVoice?.language ?? configuredReplySpeechLanguage ?? preferredVoiceLanguage
        let sample = LocalSpeechVoice.previewSentence(language: sampleLanguage)
        playChatSpeech(sample, voice: playbackVoice, rate: rate, as: .preview)
    }

    private func stopVoicePreview() {
        if speechBox.playback == .preview { speechBox.stop() }
    }

    private func playChatSpeech(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double, as playback: SpeechBox.Playback) {
        speechBox.play(LocalSpeechVoice.utterance(text, voice: voice, rate: rate), as: playback)
    }
}

private struct ChatResponseDepthButton: View {
    @Binding var length: String
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var previousLength: String?

    private var isDeep: Bool { length == "Grundig" }

    var body: some View {
        Button {
            if isDeep {
                length = previousLength ?? "Kort"
                previousLength = nil
            } else {
                previousLength = length
                length = "Grundig"
            }
        } label: {
            HStack(spacing: FadedSpacing.xs) {
                Image(systemName: "sparkles")
                if !typeSize.isAccessibilitySize { Text("Dyb").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(isDeep && palette.isDark ? palette.lime : palette.text)
            .padding(.horizontal, FadedSpacing.xs)
            .frame(minWidth: 40, minHeight: 34)
            .background(isDeep ? palette.lime.opacity(0.14) : palette.raised, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dyb")
        .accessibilityValue(length)
        .accessibilityHint("Skifter mellem grundige svar og din tidligere svarlængde.")
        .accessibilityAddTraits(isDeep ? .isSelected : [])
        .onChange(of: length) { _, value in
            if value != "Grundig" { previousLength = nil }
        }
    }
}

private struct ChatPhoneContextButton: View {
    let onOpen: () -> Void
    let onChooseNote: ((String) -> Void)?
    @State private var presenting = false

    var body: some View {
        Button {
            onOpen()
            presenting = true
        } label: {
            Label("Kontekst fra iPhone", systemImage: "cable.connector")
                .labelStyle(.iconOnly)
                .frame(width: 38, height: 38)
                .fadedGlassSurface()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Åbner Apple-forbindelser, Fotos og Filer.")
        .sheet(isPresented: $presenting) {
            NavigationStack {
                ConnectionsView(title: "iPhone-kontekst", onChooseNote: chooseAndDismiss)
                    .toolbar { Button("Luk") { presenting = false } }
            }
        }
    }

    private var chooseAndDismiss: ((String) -> Void)? {
        guard let onChooseNote else { return nil }
        return { excerpt in
            onChooseNote(excerpt)
            presenting = false
        }
    }
}
