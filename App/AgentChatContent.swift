import SwiftUI
import UIKit

extension AgentPhoneChat {
    var modelCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Svar fra", selection: Binding(get: { source }, set: { selected in
                    source = selected
                    if selected == .composio && !cloudModels.contains(where: { $0.id == selectedComposioModel }) {
                        selectedComposioModel = cloudModels.first?.id ?? ""
                    }
                    rememberedSource = selected.rawValue
                })) {
                    Text("iPhone").tag(Source.phone)
                    if !pcModels.isEmpty { Text("PC").tag(Source.pc) }
                    if !cloudModels.isEmpty { Text("Cloud").tag(Source.composio) }
                }
                .pickerStyle(.segmented)
                .disabled(running != nil)
                if source == .composio {
                    Picker("Cloudmodel", selection: $selectedComposioModel) {
                        ForEach(cloudModels) { Text($0.title).tag($0.id) }
                    }.disabled(running != nil)
                    FadedDetailText("Virker over internet med PC’en slukket. Forbrug afhænger af kontoen.")
                } else if source == .pc {
                    Picker("PC-model", selection: Binding(get: { selectedPCModel }, set: { id in
                        selectedPCModel = id
                        rememberedPCModel = id
                    })) {
                        ForEach(pcModels) { model in Text(model.title).tag(model.id) }
                    }
                    .disabled(running != nil)
                } else if models.isEmpty {
                    FadedDetailText("Vælg eller hent en telefonmodel, før du chatter offline.")
                } else {
                    Picker("Telefonmodel", selection: Binding(get: { selectedModel }, set: { id in
                        selectedModel = id
                        rememberedModel = id
                    })) {
                        ForEach(models) { model in Text(model.title).tag(model.id) }
                    }
                    .disabled(running != nil)
                }
                FadedSecondaryButton("Lokale modeller", icon: "arrow.down.circle") {
                    modelBeforeSettings = preferredModel
                    showModels = true
                }
                    .disabled(running != nil)
                FadedSecondaryButton("Klar uden PC · chat, billeder og stemmer", icon: "iphone") {
                    stopVoice(); showOfflineSetup = true
                }.disabled(running != nil)
                if keepHistory {
                    ComposioCloudSetup(api: api).disabled(running != nil)
                    NvidiaCloudSetup(api: api).disabled(running != nil)
                    OpenRouterCloudSetup(api: api).disabled(running != nil)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func turnCard(_ turn: PrivateChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentChatBubble(user: true, title: "Dig", pc: false) {
                if let photo = sentPhotos[turn.id] { ChatPhotoPreview(data: photo) }
                Text(turn.prompt).textSelection(.enabled)
                    .contextMenu {
                        if keepHistory, turn.agentAction == nil, turn.imageName == nil, sentPhotos[turn.id] == nil, turn.documentSources == nil {
                            Button("Husk det, jeg skrev", systemImage: "brain") {
                                do { let item = try AgentMemory.Store(botID: bot.id).remember(turn.prompt, sourceTurnID: turn.id); interactiveTool = .memory([item.id]) }
                                catch { notice = error.localizedDescription }
                            }.disabled(running != nil)
                        }
                        Button("Redigér besked", systemImage: "pencil") { edit(turn) }.disabled(running != nil)
                        if !turn.reply.isEmpty && sentPhotos[turn.id] == nil && turn.documentSources == nil { retryMenu(turn) }
                    }
            }
            if !turn.reply.isEmpty {
                AgentChatBubble(user: false,
                                title: [bot.name, turn.source, turn.replyModelName].compactMap { $0 }.joined(separator: " · "),
                                pc: turn.source == "PC") {
                    if turn.imageName != nil { generatedImage(turn) }
                    if let card = turn.replyCard {
                        Text(ChatTranscriptView.inlineText(card.title, allowsLinks: keepHistory)).font(.headline)
                        ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                            Text(ChatTranscriptView.inlineText(item, allowsLinks: keepHistory))
                        }
                    } else {
                        ChatTranscriptView(reply: turn.reply)
                    }
                    if let sources = turn.webSources, !sources.isEmpty {
                        DisclosureGroup("Kilder · \(sources.count)") {
                            ForEach(sources.filter(\.isWeb)) { source in
                                Link(destination: source.url) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.title)
                                        Text(source.readPage ? "Side læst" : "Søgeuddrag")
                                            .font(.caption).foregroundStyle(palette.secondary)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                    if let sources = turn.documentSources, sources.contains(where: { $0.deadline != nil }) {
                        ForEach(sources) { source in
                            if let deadline = source.deadline {
                                AgentDocumentReminderButton(source: source, deadline: deadline, botName: bot.name,
                                                            showsEvidence: sources.count > 1)
                            }
                        }
                    } else if let sources = turn.documentSources, !sources.isEmpty {
                        DisclosureGroup("Dokumentkilder") {
                            ForEach(sources) { source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "[\(source.id)] \(source.name)")
                                    if let page = source.page { Text("Side \(page)").font(.caption) }
                                    if let excerpt = source.excerpt {
                                        Text(verbatim: excerpt).font(.subheadline).textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    if keepHistory, running == nil, turn.documentSources != nil || sentPhotos[turn.id] != nil {
                        AgentResultActions(text: turn.reply, contextID: turn.id, botName: bot.name)
                    }
                    if running == nil || turns.last?.id != turn.id { HStack {
                        let playing = speech.playback == .reply(turn.id) ||
                            (pcVoiceReplyID == turn.id && (kokoro.playing || kokoro.loading))
                        Button(playing ? "Stop oplæsning" : "Læs op", systemImage: playing ? "stop.circle" : "speaker.wave.2") {
                            readReply(turn)
                        }
                        .frame(minHeight: 44)
                        Button("Kopiér", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.reply }
                            .frame(minHeight: 44)
                        Button("Oversæt til dansk", systemImage: "character.bubble") { translating = turn }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        if let api, keepHistory { kokoroMenu(turn, api: api) }
                        if api != nil, keepHistory {
                            Button("Lav Gmail-kladde", systemImage: "envelope") { gmailDraft = turn }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    } }
                    if keepHistory, let sources = turn.memorySources, !sources.isEmpty {
                        Button("Hukommelse · \(sources.count) kilder", systemImage: "brain") { interactiveTool = .memory(sources) }.font(.caption).frame(minHeight: 44)
                    }
                }
            } else if running != nil {
                AgentChatBubble(user: false, title: bot.name, pc: turn.source == "PC") {
                    FadedThinkingIndicator(title: "Svarer…").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice { FadedDetailText(notice) }
            if running != nil { FadedThinkingIndicator(title: "\(bot.name) svarer…") }
            if running == nil || handsFree {
                voiceActions
                handsFreeStatus
            }
            if running == nil {
                personalFollowUp
                ChatPhotoPicker(photo: $attachedPhoto, loading: $loadingPhoto, onError: { notice = $0 })
                if attachedPhoto != nil {
                    if source == .pc { FadedDetailText("Fotoet sendes til den parrede PC.") }
                    else if let id = PhoneModels.preferredVisionModel(preferred: selectedModel) {
                        FadedDetailText("Billedanalyse på iPhone · " + PhoneModels.textModelName(id))
                    } else {
                        FadedDetailText(PhoneModels.readyVisionModelIDs.isEmpty
                            ? "Billedtekst på iPhone · hent en billedmodel for at spørge om motivet."
                            : "Billedmodellen mangler fri hukommelse lige nu.")
                        Button("Offlineopsætning") { showOfflineSetup = true }
                    }
                }
                if keepHistory && source != .composio {
                    HStack {
                        Button("Dokumenter", systemImage: "doc.text") { showDocuments = true }
                            .frame(minHeight: 44)
                        if let nextDocument {
                            Text(verbatim: nextDocument.name).lineLimit(1)
                            Button("Fjern fra næste besked", systemImage: "xmark.circle") { self.nextDocument = nil }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .font(.caption)
                }
                HStack {
                    Button(web ? "Nettet er valgt" : "Brug nettet", systemImage: "globe") {
                        if api == nil && !composioCloud.enabled { showPhoneConnections = true }
                        else {
                            web.toggle()
                            if web { nextDocument = nil }
                        }
                    }
                        .tint(web ? palette.cyan : palette.secondary)
                    Button(answerAsCard ? "Kort valgt" : "Svar som kort", systemImage: "rectangle.on.rectangle") { answerAsCard.toggle() }
                        .tint(answerAsCard ? palette.cyan : palette.secondary)
                }
                .font(.caption)
                if web {
                    FadedDetailText("Bruger Wi-Fi eller mobildata. Uden PC bruges Composio og tjenestens eventuelle saldo.")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Skriv til \(bot.name)…", text: $draft, axis: .vertical)
                    .lineLimit(1...4).frame(minHeight: 44)
                    .textFieldStyle(.plain).padding(.horizontal, 12)
                    .focused($composerFocused)
                if composerFocused {
                    Button("Skjul tastatur", systemImage: "keyboard.chevron.compact.down") { composerFocused = false }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .fadedGlassSurface()
                }
                if running != nil {
                    Button("Stop svar", systemImage: "stop.fill") { running?.cancel() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                } else {
                    Button("Send", systemImage: "arrow.up") { send() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .buttonStyle(FadedButtonStyle(kind: .primary))
                        .disabled((attachedPhoto == nil && (cleanDraft.isEmpty || cleanDraft.count > (web ? 500 : 1_200) ||
                                  (currentModel.isEmpty && !hasStandaloneAgentCommand && !shouldCheckGmail(cleanDraft) && chatIntent(cleanDraft) == nil &&
                                   !canAskAboutSharedCalendar(cleanDraft) && !canAskAboutDocumentDeadline(cleanDraft)))) ||
                                  (attachedPhoto != nil && cleanDraft.count > 1_200) ||
                                  loadingPhoto || whisper.active || whisper.processing)
                }
            }
        }
        .padding(14)
        .background { ChatGlassSurface(radius: 22, colors: source == .pc
            ? [FadedBrand.pc, FadedBrand.blue] : [FadedBrand.mint, FadedColors.purple]) }
        .fadedWorkingBeam(active: running != nil, pc: source == .pc)
        .padding(.horizontal, FadedSpacing.edge).padding(.vertical, 8)
    }
}
