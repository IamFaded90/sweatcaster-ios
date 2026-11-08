// Chat model routing, composer controls and the PC outbox interface.

import Foundation
import SwiftUI
import UIKit

extension ChatView {
    func goBack() {
        composerFocused = false
        stop()
        if let onBack { onBack() }
        else { dismiss() }
    }

    func goToPrivateStudio() {
        guard task == nil else { return }
        dictation.stop()
        composerFocused = false
        openPrivateStudio?()
    }

    var sourcePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { sourceChips }
            VStack(alignment: .leading, spacing: 6) { sourceChips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Svar fra")
        .disabled(task != nil)
    }

    private var sourceChips: some View {
        ForEach(ReplySource.allCases, id: \.self) { source in
            FadedChip(source.rawValue, accent: sourceColor(source),
                      selected: effectiveReplySource == source && (!usesAutomaticRouting || automaticSelection != nil), icon: source.icon) {
                chooseSource(source)
            }
        }
    }

    private var automaticRoutingAvailable: Bool { autoRouterEnabled && !demo }
    private var usesAutomaticRouting: Bool { automaticRoutingAvailable && manualRoute == nil }

    private var automaticSelection: ModelRouter.Selection? {
        if let inFlightAutoRoute { return inFlightAutoRoute }
        guard usesAutomaticRouting else { return nil }
        let readyPhones = phoneRoutingCandidates
        let phones = PhoneModels.liteModeActive(for: phoneModel)
            ? readyPhones.filter { $0.defaultChoice } : readyPhones
        return ModelRouter.choose(text: draft, candidates: phones + pcRoutingCandidates)
    }

    var resolvedRoute: ResolvedRoute {
        if let automaticSelection {
            return ResolvedRoute(source: automaticSelection.candidate.location == .phone ? .phone : .pc,
                                 modelID: automaticSelection.candidate.id, automatic: automaticSelection)
        }
        let source = manualRoute?.source ?? replySource
        let modelID: String?
        switch source {
        case .phone: modelID = manualRoute?.modelID ?? PhoneModels.effectiveModelID(phoneModel)
        case .pc:
            let requested = manualRoute?.modelID ?? (selectedModel.isEmpty ? nil : selectedModel)
            modelID = requested.flatMap { id in api == nil || models.contains(where: { $0.id == id }) ? id : nil }
        case .grok: modelID = nil
        }
        return ResolvedRoute(source: source, modelID: modelID, automatic: nil)
    }

    var effectiveReplySource: ReplySource { resolvedRoute.source }
    var effectivePCModelID: String? { effectiveReplySource == .pc ? resolvedRoute.modelID : nil }

    private var phoneRoutingCandidates: [ModelRouter.Candidate] {
        let favorites = Set(phoneFavorites.split(separator: "|").map(String.init))
        let preferred = PhoneModels.effectiveModelID(phoneModel)
        let entries = PhoneModels.catalog.map { ($0.id, $0.name) } + [("apple", "Apple Foundation Models"), ("imported", "Importeret model")]
        return entries.compactMap { id, name in
            guard PhoneModels.isReady(id) else { return nil }
            return ModelRouter.Candidate(id: id, name: name, location: .phone, ready: true,
                                         favorite: favorites.contains(id), defaultChoice: id == preferred)
        }
    }

    private var pcRoutingCandidates: [ModelRouter.Candidate] {
        guard let live = api as? LiveAPI, !legacyChat else { return [] }
        let favorite = PCModelSelection.saved(for: live)
        return models.map { entry in
            let capabilities = Set(entry.capabilities.map { $0.lowercased() })
            return ModelRouter.Candidate(id: entry.id, name: entry.label, location: .pc, ready: PCModelSelection.usable(entry),
                                         favorite: entry.id == favorite, defaultChoice: entry.id == pcDefaultModelID || entry.loaded,
                                         code: capabilities.contains("code") || capabilities.contains("coding"),
                                         longContext: capabilities.contains("long_context"))
        }
    }

    func chooseSource(_ source: ReplySource, modelID: String? = nil) {
        guard task == nil else { return }
        if automaticRoutingAvailable {
            manualRoute = ManualRoute(source: source, modelID: modelID)
        } else {
            replySource = source
            if source == .pc, let modelID, let live = api as? LiveAPI {
                selectedModel = modelID
                PCModelSelection.set(modelID, for: live)
            }
        }
    }

    private func sourceColor(_ source: ReplySource) -> Color {
        switch source {
        case .phone: palette.green
        case .pc: palette.cyan
        case .grok: palette.purple
        }
    }

    private var sourceNote: String? {
        guard !demo else { return nil }
        return switch effectiveReplySource {
        case .phone: nil
        case .pc:
            api != nil ? nil : canQueuePC
                ? "PC’en kan ikke nås. Udbakken sender automatisk, når denne PC er tilbage."
                : "Forbind til PC’en for at sende."
        case .grok: cloudKeyAvailable
            ? "Beskeden og de seneste Grok-udvekslinger sendes til xAI. Forbrug kan koste penge."
            : "Gem en xAI-nøgle under Chatindstillinger for at sende til Grok."
        }
    }

    private var canSendToSource: Bool { canSend(to: resolvedRoute) }

    func canSend(to route: ResolvedRoute) -> Bool {
        if demo { return true }
        if usesAutomaticRouting && route.automatic == nil { return false }
        return switch route.source {
        case .phone: PhoneModels.isReady(route.modelID ?? phoneModel)
        case .pc: (api != nil && !modelsLoading) || canQueuePC
        case .grok: cloudKeyAvailable
        }
    }

    var canQueuePC: Bool {
        api == nil && !demo && pcTargetAddress != nil && pcQueueTargetID != nil
            && PCChatOutbox.confirmedOffline(pcConnectionError)
    }

    private func matchesQueueTarget(_ entry: PCChatOutbox.Entry) -> Bool {
        pcQueueTargetID != nil && entry.targetID == pcQueueTargetID
    }

    var outboxPanel: some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Udbakke til PC")
                ForEach(outboxEntries) { entry in
                    let inFlight = activeOutboxIDs.contains(entry.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.prompt).lineLimit(2)
                        Text(outboxStatus(entry, inFlight: inFlight))
                            .font(.caption).foregroundStyle(palette.secondary)
                        if !inFlight {
                            Menu("Udbakkehandlinger", systemImage: "ellipsis.circle") {
                                Button("Kopiér besked", systemImage: "doc.on.doc") { copyText(entry.prompt) }
                                Button("Fjern fra udbakken", systemImage: "trash", role: .destructive) {
                                    removeFromOutbox(entry)
                                }
                            }.frame(minHeight: 44)
                        }
                    }.padding(.vertical, 3)
                }
                if api == nil, let reconnectPC {
                    FadedSecondaryButton("Tjek forbindelse", icon: "arrow.clockwise", action: reconnectPC)
                } else if let live = api as? LiveAPI, outboxEntries.contains(where: { $0.state == .waiting && matchesQueueTarget($0) }) {
                    FadedSecondaryButton("Send ventende", icon: "paperplane") {
                        Task { await PCChatOutbox().deliverReady(using: live) }
                    }.disabled(!activeOutboxIDs.isEmpty || task != nil)
                }
            }
        }
    }

    private func outboxStatus(_ entry: PCChatOutbox.Entry, inFlight: Bool) -> String {
        if !matchesQueueTarget(entry) { return "PC-forbindelsen er ændret. Beskeden sendes ikke." }
        if entry.state == .waiting { return "Sendes, når denne PC er tilbage." }
        return inFlight ? "PC-beskeden behandles…" : "Kontrollér på PC’en. Denne besked gensendes aldrig automatisk."
    }

    func reloadOutbox() {
        guard !demo, let address = pcTargetAddress else {
            outboxEntries = []
            activeOutboxIDs = []
            return
        }
        let outbox = PCChatOutbox()
        do {
            let stored = try outbox.entries(for: address)
            outboxEntries = stored.filter { $0.state != .completed || !matchesQueueTarget($0) }
            activeOutboxIDs = Set(stored.map(\.id).filter { PCChatOutbox.isDelivering($0) })
            guard loaded, task == nil else { return }
            let completed = stored.filter { $0.state == .completed && matchesQueueTarget($0) && !PCChatOutbox.isDelivering($0.id) }
            guard !completed.isEmpty else { return }
            var imported = Set<UUID>()
            let existing = Set(turns.map(\.id))
            for entry in completed {
                let reply = safeText(entry.reply ?? "", complete: true)
                let turn = ChatTurn(id: entry.id, prompt: entry.prompt, reply: reply,
                                    notice: reply.isEmpty ? "PC’en afsluttede beskeden uden svartekst." : nil,
                                    source: "PC", createdAt: entry.createdAt)
                if entry.sessionID == sessionID {
                    if !existing.contains(entry.id) { turns.append(turn) }
                    imported.insert(entry.id)
                } else if ChatArchive.appendOutboxTurn(turn, to: entry.sessionID) {
                    imported.insert(entry.id)
                }
            }
            guard save() else { return }
            try outbox.remove(imported, for: address)
            if !chatSearch.isEmpty { archivedTurns = ChatArchive.turns() }
        } catch { AppDiagnostics.record(error); chatNotice = "Udbakken kunne ikke læses eller opdateres." }
    }

    private func removeFromOutbox(_ entry: PCChatOutbox.Entry) {
        do { try PCChatOutbox().remove([entry.id], for: entry.address) }
        catch { AppDiagnostics.record(error); chatNotice = "Beskeden kunne ikke fjernes fra udbakken." }
    }

    func scrollChat(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let deleted = removedTurns.last, deleted.expiresAt > ContinuousClock.now { undoBar }
            if let chatNotice { Text(chatNotice).font(.caption).foregroundStyle(palette.secondary) }
            VStack(alignment: .leading, spacing: 6) {
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
                    dictationAction.disabled(task != nil)
                    sendControl
                }
                if let problem = dictation.problem { Text(problem).font(.caption).foregroundStyle(palette.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(palette.border) }

            HStack(alignment: .firstTextBaseline) {
                Label("Sendes til: \(demo ? "Demo" : effectiveReplySource.rawValue)", systemImage: demo ? "testtube.2" : effectiveReplySource.icon)
                    .font(.caption.weight(.semibold)).foregroundStyle(demo || !palette.isDark ? palette.secondary : sourceColor(effectiveReplySource))
                if effectiveReplySource == .phone, phoneBatteryLevel >= 0, phoneBatteryLevel < 0.20,
                   PhoneModels.liteModeActive(for: phoneModel), resolvedRoute.modelID == PhoneModels.effectiveModelID(phoneModel) {
                    Label("Lite Mode", systemImage: "battery.25percent").font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 4)
                Text("\(transportMessage.unicodeScalars.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(transportMessage.unicodeScalars.count > 2000 ? palette.coralText : palette.secondary)
            }
            if automaticRoutingAvailable { automaticRouteMenu }
            if !demo, effectiveReplySource == .phone, !PhoneModels.isReady(resolvedRoute.modelID ?? phoneModel) {
                FadedDetailText("Telefonmodellen er ikke klar. Din kladde bliver gemt.")
                FadedSecondaryButton("Åbn lokale modeller", icon: "iphone") { showPhoneModelSetup = true }
                    .disabled(task != nil)
            }
            if let sourceNote { Text(sourceNote).font(.caption).foregroundStyle(palette.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var sendControl: some View {
        let sending = task != nil
        let allowed = sending || (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transportMessage.unicodeScalars.count <= 2000 && canSendToSource)
        return Button {
            if sending { stop() }
            else { send() }
        } label: {
            Image(systemName: sending ? "stop.fill" : (effectiveReplySource == .pc && canQueuePC ? "tray.and.arrow.down" : "arrow.up"))
                .font(.body.weight(.bold)).foregroundStyle(Color.black)
                .frame(width: 40, height: 40).background(palette.lime.opacity(allowed ? 1 : 0.45), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sending ? "Stop modtagelse" : (demo ? "Send testbesked" :
            (effectiveReplySource == .pc && canQueuePC ? "Sæt besked i udbakke til PC" : "Send til \(effectiveReplySource.rawValue)")))
        .disabled(!allowed)
    }

    private var automaticRouteMenu: some View {
        Menu {
            if manualRoute != nil {
                Button("Brug Auto igen", systemImage: "sparkles") { manualRoute = nil }
            }
            Menu("Telefon", systemImage: "iphone") {
                Button("Min telefonmodel") { chooseSource(.phone) }
                ForEach(phoneRoutingCandidates, id: \.id) { entry in
                    Button(entry.name) { chooseSource(.phone, modelID: entry.id) }
                }
            }
            Menu("PC", systemImage: "desktopcomputer") {
                Button("Valgt PC-model") { chooseSource(.pc) }
                ForEach(models) { entry in
                    Button(entry.label) { chooseSource(.pc, modelID: entry.id) }
                }
            }
            Button("Grok · Cloud", systemImage: "cloud") { chooseSource(.grok) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(automaticRouteLabel).multilineTextAlignment(.leading)
                Image(systemName: "chevron.down").accessibilityHidden(true)
            }.font(.caption).foregroundStyle(palette.secondary).frame(minHeight: 44)
        }
        .accessibilityHint("Skift model for denne besked")
        .disabled(task != nil)
    }

    private var automaticRouteLabel: String {
        if let automaticSelection {
            return "Auto-valgt: \(automaticSelection.candidate.name) - \(automaticSelection.reason)"
        }
        if manualRoute != nil { return "Manuelt valg til denne besked: \(effectiveReplySource.rawValue)" }
        if ModelRouter.intent(for: draft) == .cardCollection { return "Kortsamlingen kræver en klar PC-forbindelse." }
        return "Auto fandt ingen klar model. Tryk for at vælge selv."
    }

    var composerToolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if choosingNote {
                        noteChoices
                    } else {
                        if openImageStudio != nil {
                            FadedSecondaryButton("Lav billede", icon: "photo") {
                                imageHandoff = draft
                                showComposerTools = false
                            }
                        }
                        if openPrivateStudio != nil {
                            FadedSecondaryButton("Åbn privat chat", icon: "lock.shield") {
                                privateHandoff = true
                                showComposerTools = false
                            }
                        }
                        FadedSecondaryButton("Vedhæft note", icon: "note.text") { choosingNote = true }
                        NavigationLink {
                            ConnectionsView(onChooseNote: effectiveReplySource == .grok ? nil : { excerpt in
                                guard effectiveReplySource != .grok else { return }
                                attachedNote = excerpt
                                noteDestination = effectiveReplySource
                                showComposerTools = false
                            })
                        } label: {
                            Label("Forbindelser", systemImage: "link")
                                .frame(minHeight: 44)
                        }
                            .disabled(demo)
                        DisclosureGroup("Flere chatværktøjer") {
                            promptTemplates
                            Button("Vis nyeste besked", systemImage: "arrow.down") {
                                scrollRequest += 1
                                showComposerTools = false
                            }.frame(minHeight: 44)
                            Button("Ryd kladde", role: .destructive) {
                                draft = ""
                                attachedNote = nil
                                attachedQuote = nil
                                showComposerTools = false
                            }.frame(minHeight: 44).disabled(draft.isEmpty && attachedNote == nil && attachedQuote == nil)
                        }
                    }
                }.padding(20)
            }
            .background { FadedBackground() }
            .navigationTitle(choosingNote ? "Vedhæft note" : "Chatværktøjer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { showComposerTools = false } }
        }
        .presentationDetents(choosingNote ? [.large] : [.medium, .large])
    }

    private var noteChoices: some View {
        let excerpts = notes.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Vælg et uddrag. Det følger næste besked til \(effectiveReplySource.rawValue).").foregroundStyle(palette.secondary)
            if excerpts.isEmpty {
                FadedEmptyState(icon: "note.text", title: "Ingen noter", detail: "Tilføj en note i appen, og prøv igen.")
            } else {
                ForEach(Array(excerpts.prefix(30).enumerated()), id: \.offset) { item in
                    let excerpt = String(item.element.prefix(600))
                    Button {
                        attachedNote = excerpt
                        noteDestination = effectiveReplySource
                        showComposerTools = false
                    } label: {
                        Text(verbatim: excerpt).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(FadedButtonStyle(kind: .secondary))
                }
            }
            DisclosureGroup("Tilføj en lokal note") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Skriv en kort note…", text: $newNote, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button("Gem note på telefonen", action: saveNote)
                        .frame(minHeight: 44)
                        .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newNote.count > 600)
                }.padding(.top, 6)
            }
        }
    }

    private func saveNote() {
        let clean = newNote.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 600 else { return }
        do {
            try MigratedAppData.shared.saveNotes(notes.isEmpty ? clean : clean + "\n" + notes)
            newNote = ""
        } catch { AppDiagnostics.record(error); chatNotice = "Noten kunne ikke gemmes." }
    }

    func finishComposerTools() {
        newNote = ""
        if privateHandoff {
            privateHandoff = false
            goToPrivateStudio()
            return
        }
        guard let imageHandoff else { return }
        self.imageHandoff = nil
        dictation.stop()
        openImageStudio?(imageHandoff)
    }

    private var promptTemplates: some View {
        Menu("Skabeloner") {
            ForEach(PromptExample.examples) { example in
                Button(example.text) {
                    draft = example.text
                    showComposerTools = false
                }
            }
        }.frame(minHeight: 44)
    }

    private var dictationAction: some View {
        Button {
            if dictation.active { dictation.stop() }
            else {
                let prefix = draft.isEmpty ? "" : draft + " "
                Task { await dictation.start { draft = prefix + $0 } }
            }
        } label: {
            Image(systemName: dictation.active ? "stop.circle" : "mic")
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel(dictation.active ? "Stop diktering" : "Dikter chatbesked")
    }

    @ViewBuilder var modelControls: some View {
        if modelsLoading { LoadingSkeleton(label: "Henter modeller…") }
        if let modelsError {
            if api == nil, let reconnectPC {
                FadedDetailText(modelsError)
                FadedSecondaryButton("Forbind til PC", icon: "desktopcomputer", action: reconnectPC)
            } else {
                RetryNotice(message: modelsError) { Task { await loadModels() } }
            }
        }
        if legacyChat { Text("Chat bruger PC’ens standardmodel via v1.").font(.caption) }
        if !models.isEmpty {
            Picker("AI-model", selection: Binding(get: { effectivePCModelID ?? "" }, set: { chooseSource(.pc, modelID: $0) })) {
                ForEach(models) { model in
                    Text(model.label).tag(model.id)
                }
            }.disabled(task != nil || modelsLoading).frame(minHeight: 48)
        }
    }

    var aiBoostControls: some View {
        DisclosureGroup("AI Boost · 30 forbedringer") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Tone", selection: $aiTone) {
                    ForEach(["Naturlig", "Varm", "Professionel", "Direkte", "Legende"], id: \.self) { Text($0) }
                }
                Picker("Svarlængde", selection: $aiLength) {
                    ForEach(["Meget kort", "Kort", "Mellem", "Grundig"], id: \.self) { Text($0) }
                }
                Picker("Sprog", selection: $aiLanguage) {
                    ForEach(["Dansk", "Engelsk", "Følg beskeden"], id: \.self) { Text($0) }
                }
                Picker("Kreativitet", selection: $aiCreativity) {
                    ForEach(["Præcis", "Balanceret", "Kreativ"], id: \.self) { Text($0) }
                }
                Toggle("Brug punktform", isOn: $aiBullets)
                Toggle("Giv eksempler", isOn: $aiExamples)
                Toggle("Start med et resumé", isOn: $aiSummary)
                Toggle("Slut med næste handling", isOn: $aiActions)
                Toggle("Spørg ved uklarhed", isOn: $aiClarify)
                Toggle("Brug enkelt sprog", isOn: $aiSimple)
                Toggle("Undgå fagsprog", isOn: $aiNoJargon)
                Toggle("Vis trin for trin", isOn: $aiSteps)
                Toggle("Brug tabel ved sammenligning", isOn: $aiTables)
                Toggle("Fortæl når noget er usikkert", isOn: $aiUncertainty)
                Toggle("Nævn et modargument", isOn: $aiCounterpoint)
                Toggle("Vis antagelser", isOn: $aiAssumptions)
                Toggle("Bed om kilder ved research", isOn: $aiSources)
                Toggle("Korte kodekommentarer", isOn: $aiCodeComments)
                Toggle("Bevar præcise navne", isOn: $aiPreserveNames)
                Toggle("Tillad få emojis", isOn: $aiEmojis)
                Toggle("Brug korte overskrifter", isOn: $aiHeadings)
                Toggle("Slut med kontrolspørgsmål", isOn: $aiRecapQuestion)
                Toggle("Foreslå relevante genveje", isOn: $aiSuggestions)
                Toggle("Fremhæv risici", isOn: $aiRisks)
                Toggle("Vis fordele og ulemper", isOn: $aiProsCons)
                Toggle("Lav tjekliste ved opgaver", isOn: $aiChecklist)
                Toggle("Vis klokkeslæt", isOn: $aiTimestamps)
                Toggle("Vis antal ord", isOn: $aiWordCount)
                Toggle("Vis værktøjsaktivitet", isOn: $aiShowTools)
            }.padding(.top, 8)
        }
    }

    func loadModels() async {
        modelsLoading = true
        defer { if !Task.isCancelled { modelsLoading = false } }
        modelsError = nil
        legacyChat = false
        guard let live = api as? LiveAPI else {
            models = []
            selectedModel = ""
            pcDefaultModelID = ""
            if !demo { modelsError = "Forbind til din PC i Indstillinger." }
            return
        }
        do {
            let catalog = try await live.v2Models()
            guard !Task.isCancelled else { return }
            let available = catalog.models.filter(PCModelSelection.usable)
            models = available
            pcDefaultModelID = catalog.default_model_id
            let preferred = PCModelSelection.saved(for: live)
            selectedModel = available.first(where: { $0.id == preferred })?.id
                ?? available.first(where: { $0.id == catalog.default_model_id })?.id ?? available.first?.id ?? ""
            if available.isEmpty { modelsError = "PC’en har ingen tilgængelige chatmodeller." }
        } catch V2Failure.http(status: 404, code: _, message: _) {
            AppDiagnostics.record(V2Failure.http(status: 404, code: nil, message: nil))
            guard !Task.isCancelled else { return }
            models = []
            selectedModel = ""
            pcDefaultModelID = ""
            legacyChat = true
        } catch {
            AppDiagnostics.record(error)
            if !Task.isCancelled {
                models = []
                selectedModel = ""
                pcDefaultModelID = ""
                modelsError = error is V2Failure ? v2Message(error) : "Kunne ikke hente modeller. Tjek forbindelsen til PC’en."
            }
        }
    }
}
