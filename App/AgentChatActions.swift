import SwiftUI

struct AgentChatAction: Codable {
    enum Kind: Codable {
        case gmailReply
        case bookingRequest
        case phone(AgentPhoneActionCard.Request)
        case today
        case preference
        case workflow(String)
        case appointmentCheck
        case meetingPrep
        case mailReminder
        case followups
        case agentEmail(AgentEmailRequest)
        case instagramPost
        case instagramAccount
        case instagramPlans
        case traderaWatch
        case traderaWatches
    }

    let kind: Kind
    var receipt: String?
    var receiptLink: URL?
    var mailDraft: AgentGmailReply.StoredDraft? = nil
    var instagramDraft: AgentInstagramDraft? = nil

    var title: String {
        switch kind {
        case .gmailReply: "Svar på mail"
        case .bookingRequest: "Bed om en tid"
        case .phone: "Handling på iPhone"
        case .today: "Dagens overblik"
        case .preference: "Dine præferencer"
        case .workflow(let title): title
        case .appointmentCheck: "Tjek aftale"
        case .meetingPrep: "Forbered din aftale"
        case .mailReminder: "Påmindelse fra Gmail"
        case .followups: "Følg op på mail"
        case .agentEmail(let request): request.title
        case .instagramPost: "Instagram-opslag"
        case .instagramAccount: "Instagram-konto"
        case .instagramPlans: "Planlagte Instagram-opslag"
        case .traderaWatch: "Prisvagt på Tradera"
        case .traderaWatches: "Mine prisvagter"
        }
    }

    var canFollowUp: Bool {
        switch kind {
        case .gmailReply, .bookingRequest, .phone, .mailReminder, .agentEmail, .instagramPost, .instagramAccount,
             .instagramPlans, .traderaWatch, .traderaWatches: true
        case .today, .preference, .workflow, .appointmentCheck, .meetingPrep, .followups: false
        }
    }
}

enum AgentMailRevision {
    private static let day = #"mandag|tirsdag|onsdag|torsdag|fredag|lørdag|søndag"#
    private static let time = #"(?:\s+(?:kl(?:okken)?\.?\s*)?\d{1,2}(?:(?:[.:])\d{2})?(?:\s*(?:om formiddagen|om eftermiddagen|om aftenen))?)?"#

    static func matches(_ instruction: String) -> Bool {
        let text = AgentChatIntent.normalize(instruction)
        if ["gør det kortere", "gør svaret kortere", "gør kladden kortere", "skriv det kortere"].contains(text) { return true }
        return text.hasPrefix("ret kladden, så der står ") || text.hasPrefix("skriv i stedet, at ")
            || text.range(of: "^("+day+")"+time+#"\s+i stedet\b"#, options: .regularExpression) != nil
    }

    static func apply(_ instruction: String, to body: String) -> String? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if let prefix = ["ret kladden, så der står ", "skriv i stedet, at "].first(where: { lower.hasPrefix($0) }) {
            let replacement = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !replacement.isEmpty else { return nil }
            let sentence = replacement.prefix(1).uppercased() + replacement.dropFirst()
            return "Hej,\n\n" + sentence + (sentence.last?.isPunctuation == true ? "" : ".") + "\n\nVenlig hilsen"
        }
        var result = body
        if let change = lower.range(of: " i stedet"), lower.range(of: "^("+day+")"+time+"$", options: .regularExpression,
                                                                range: lower.startIndex..<change.lowerBound) != nil {
            let replacement = String(lower[..<change.lowerBound])
            let pattern = try? NSRegularExpression(pattern: #"(?i)\b(?:"# + day + #")\b"# + time)
            let matches = pattern?.matches(in: body, range: NSRange(body.startIndex..., in: body)) ?? []
            guard matches.count == 1, let match = Range(matches[0].range, in: body) else { return nil }
            let newText = body[match].first?.isUppercase == true
                ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
            result.replaceSubrange(match, with: newText)
        }
        if lower.contains("kortere") {
            result = result.replacingOccurrences(of: #"(?im)^Jeg (?:vil|ville) (?:bare )?(?:lige )?skrive (?:for at sige, at |at )"#,
                                                 with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\bpasser mig fint\b"#, with: "passer fint", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\bdet kan jeg godt\b"#, with: "det kan jeg", options: .regularExpression)
            if let breakIndex = result.range(of: "\n\n"), breakIndex.upperBound < result.endIndex {
                let index = breakIndex.upperBound
                result.replaceSubrange(index...index, with: result[index].uppercased())
            }
        }
        return result == body ? nil : result
    }
}

private extension String {
    func cut(afterAny prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: hasPrefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

extension AgentPhoneChat {
    func loadModels(preferSetting: Bool = false) {
        let available = PhoneModels.textOptions.filter { PhoneModels.isReady($0.id) }
            .map { Model(id: $0.id, title: $0.name) }
        models = available
        let ids = Set(available.map(\.id))
        if preferSetting && ids.contains(preferredModel) && preferredModel != rememberedModel {
            selectedModel = preferredModel
            rememberedModel = preferredModel
        } else if !ids.contains(selectedModel) {
            selectedModel = if ids.contains(rememberedModel) { rememberedModel }
            else if ids.contains(preferredModel) { preferredModel }
            else { available.first?.id ?? "" }
        }
    }

    @ViewBuilder func agentChatEntry(_ turn: PrivateChatTurn) -> some View {
        if turn.agentAction == nil { turnCard(turn) }
        else { agentActionCard(turn).id(turn.id) }
    }

    var agentActionShortcuts: some View {
        Menu("Giv mig en opgave", systemImage: "sparkle.magnifyingglass") {
            advancedAgentShortcuts
            Button("Se mit PC-vindue", systemImage: "macwindow") {
                startAgentAction(.windowHelp, prompt: "Se lige min skærm")
            }
            Menu("Prøv to og vælg", systemImage: "slider.horizontal.3") {
                tasteChoices
            }
            Button("Hvad husker du om mig?", systemImage: "person.text.rectangle") {
                startAgentAction(.showPreferences, prompt: "Hvad husker du om mig?")
            }
            Button("Dagens overblik", systemImage: "sun.max") {
                startAgentAction(.action(.today), prompt: "Hvad skal jeg nå i dag?")
            }
            Button("Forbered næste aftale", systemImage: "calendar.badge.clock") {
                startAgentAction(.action(.meetingPrep), prompt: "Forbered min næste aftale")
            }
            Button("Følg op på mails", systemImage: "envelope.badge") {
                startAgentAction(.action(.followups), prompt: "Hvad venter jeg svar på?")
            }
            Button("Svar på mail", systemImage: "envelope") { startActionDraft("Svar ") }
            Button("Agentens e-mail", systemImage: "at") {
                startAgentAction(.action(.agentEmail(.address)), prompt: "Opret din egen e-mail")
            }
            Button("Lav Instagram-opslag", systemImage: "camera") {
                startAgentAction(.action(.instagramPost), prompt: "Lav et Instagram-opslag")
            }
            Button("Planlagte Instagram-opslag", systemImage: "calendar.badge.clock") {
                startAgentAction(.action(.instagramPlans), prompt: "Vis mine planlagte Instagram-opslag")
            }
            Button("Hold øje med en pris", systemImage: "tag") {
                startAgentAction(.action(.traderaWatch), prompt: "Hold øje med en pris på Tradera")
            }
            Button("Find tid i kalenderen", systemImage: "calendar") { startActionDraft("Find en ledig time ") }
            Button("Lav en påmindelse", systemImage: "checklist") { startActionDraft("Mind mig om at ") }
            Button("Sæt en alarm", systemImage: "alarm") { startActionDraft("Sæt en alarm ") }
        }
        .disabled(running != nil || !cleanDraft.isEmpty)
    }

    private func startActionDraft(_ text: String) {
        draft = text
        composerFocused = true
    }

    func chatIntent(_ message: String) -> AgentChatIntent? {
        guard keepHistory, !web, !answerAsCard, nextDocument == nil else { return nil }
        if editableMailTurn() != nil, AgentMailRevision.matches(message) { return .reviseMail(message) }
        guard let intent = AgentChatIntent.match(message) else { return nil }
        if case .scheduleInstagram = intent, editableInstagramTurn() == nil { return nil }
        if case .resume(let topic) = intent, !topic.isEmpty, matchingAgentAction(topic) == nil { return nil }
        return intent
    }

    private func editableMailTurn() -> PrivateChatTurn? {
        // Keep follow-up corrections tied to the task currently visible in this conversation.
        turns.last { $0.id == openAgentAction && $0.agentAction?.receipt == nil && $0.agentAction?.mailDraft != nil }
    }

    private func editableInstagramTurn() -> PrivateChatTurn? {
        let drafts = turns.filter { turn in
            guard case .instagramPost? = turn.agentAction?.kind else { return false }
            return turn.agentAction?.receipt == nil && turn.agentAction?.instagramDraft?.approvedPC == nil
        }
        return drafts.first(where: { $0.id == openAgentAction }) ?? drafts.last
    }

    private func matchingAgentAction(_ topic: String) -> PrivateChatTurn? {
        let words = AgentChatIntent.topicWords(topic)
        return turns.last { turn in
            guard turn.agentAction?.canFollowUp == true else { return false }
            return words.isEmpty || !words.isDisjoint(with: AgentChatIntent.topicWords(AgentChatIntent.normalize(turn.prompt)))
        }
    }

    func startAgentAction(_ intent: AgentChatIntent, prompt: String) {
        if handsFree { stopVoice() }
        composerFocused = false
        appleDictation.stop()
        if cleanDraft == prompt { draft = "" }
        notice = nil
        switch intent {
        case .milestone(let kind):
            interactiveTool = .milestone(kind, prompt)
        case .appointmentChange:
            interactiveTool = .appointmentChange(prompt)
        case .gmailCleanup:
            interactiveTool = .gmailCleanup(prompt)
        case .pcRepair:
            interactiveTool = .pcRepair(prompt)
        case .agentComputer(let goal):
            interactiveTool = .agentComputer(goal)
        case .phoneScreen:
            interactiveTool = .phoneScreen(prompt)
        case .sales:
            interactiveTool = .sales(prompt)
        case .surprise:
            interactiveTool = .surprise(prompt)
        case .builtTools:
            interactiveTool = .builtTools(["vis agentværktøjer", "mine agentværktøjer"].contains(prompt.lowercased()) ? "" : prompt)
        case .windowHelp:
            interactiveTool = .window(prompt)
        case .chooseTaste:
            showTasteChoices = true
        case .taste(let request):
            presentTasteTest(request)
        case .action(let kind):
            addAgentAction(prompt, kind: kind, receipt: nil)
        case .scheduleInstagram(let timing):
            guard let turn = editableInstagramTurn() else { break }
            instagramPlanRequest = .init(turn: turn.id, timing: timing)
            openAgentAction = turn.id
            notice = "Tidspunktet er udfyldt. Gennemgå opslaget, og tryk på Planlæg opslag."
        case .resume(let topic):
            if let existing = matchingAgentAction(topic) {
                agentActionRefresh = UUID()
                openAgentAction = existing.id
            } else {
                notice = "Jeg fandt ingen gemt opgave, der passer. Skriv den gerne igen."
            }
        case .reviseMail(let instruction):
            guard let turn = editableMailTurn(), let saved = turn.agentAction?.mailDraft else { break }
            if let revision = AgentMailRevision.apply(instruction, to: saved.body) {
                updateAgentDraft(turn.id, draft: .init(pcID: saved.pcID, messageID: saved.messageID,
                                                     threadID: saved.threadID, recipient: saved.recipient, body: revision))
                notice = "Kladden er opdateret. Se den igennem før du sender."
            } else {
                notice = "Jeg kunne ikke rette kladden sikkert. Skriv ‘Skriv i stedet, at …’ eller ret teksten i kortet."
            }
        case .remember(let value):
            AgentChatPreferences.remember(value, for: bot.id)
            addAgentAction(prompt, kind: .preference, receipt: "Det husker jeg. Ønsket gælder hos " + bot.name + ".")
        case .rememberForAll(let value):
            AgentChatPreferences.remember(value)
            addAgentAction(prompt, kind: .preference, receipt: "Gemt som fælles ønske til dine agenter.")
        case .showPreferences:
            addAgentAction(prompt, kind: .preference, receipt: nil)
        case .clearPreferences:
            AgentChatPreferences.clear(for: bot.id)
            addAgentAction(prompt, kind: .preference, receipt: "Dine personlige ønsker hos " + bot.name + " er fjernet.")
        case .clearSharedPreferences:
            AgentChatPreferences.clear()
            addAgentAction(prompt, kind: .preference, receipt: "Dine fælles ønsker er fjernet.")
        }
        saveDraft()
    }

    func addAgentAction(_ prompt: String, kind: AgentChatAction.Kind, receipt: String?, source: String = "iPhone", link: URL? = nil) {
        var turn = PrivateChatTurn(prompt: prompt, reply: receipt ?? "", source: source, botID: bot.id)
        turn.agentAction = AgentChatAction(kind: kind, receipt: receipt, receiptLink: link)
        turns.append(turn)
        persistAgentAction(turn)
        openAgentAction = turn.id
    }

    private func persistAgentAction(_ turn: PrivateChatTurn) {
        do {
            var saved = MigratedAppData.shared.regularStudioTurns()
            if let index = saved.firstIndex(where: { $0.id == turn.id }) { saved[index] = turn }
            else { saved.append(turn) }
            try MigratedAppData.shared.saveRegularStudioTurns(saved)
        } catch {
            AppDiagnostics.record(error)
            notice = "Opgaven vises her, men kunne ikke gemmes i samtalen."
        }
    }

    private func finishAgentAction(_ id: UUID, receipt: String, link: URL? = nil) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].agentAction?.receipt = receipt
        turns[index].agentAction?.receiptLink = link
        turns[index].agentAction?.mailDraft = nil
        turns[index].agentAction?.instagramDraft = nil
        turns[index].reply = receipt
        persistAgentAction(turns[index])
    }

    private func updateAgentDraft(_ id: UUID, draft: AgentGmailReply.StoredDraft?) {
        guard let index = turns.firstIndex(where: { $0.id == id }), let action = turns[index].agentAction,
              action.receipt == nil, action.mailDraft != draft else { return }
        turns[index].agentAction?.mailDraft = draft
        persistAgentAction(turns[index])
    }

    private func saveInstagramDraft(_ id: UUID, draft: AgentInstagramDraft) {
        guard let index = turns.firstIndex(where: { $0.id == id }), let action = turns[index].agentAction,
              action.receipt == nil, action.instagramDraft != draft else { return }
        turns[index].agentAction?.instagramDraft = draft
        persistAgentAction(turns[index])
    }

    private var trackedInstagramTurns: Set<UUID> {
        guard loaded, keepHistory, phase == .active, let api else { return [] }
        return Set(turns.compactMap { turn in
            guard let action = turn.agentAction, action.receipt == nil,
                  let draft = action.instagramDraft, draft.timing != nil,
                  draft.approvedPC == api.queueTargetID else { return nil }
            return turn.id
        })
    }

    var instagramPollingID: String {
        trackedInstagramTurns.isEmpty ? "" : (api?.queueTargetID ?? "") + bot.id.uuidString
    }

    func monitorInstagramReports() async {
        guard let api, !trackedInstagramTurns.isEmpty else { return }
        let query = [URLQueryItem(name: "bot_id", value: bot.id.uuidString)]
        while !Task.isCancelled && !trackedInstagramTurns.isEmpty {
            do {
                let jobs: AgentInstagramJobList = try await api.moduleJSON("composio/instagram/schedule", timeout: 20, query: query)
                try Task.checkCancellation()
                for job in jobs.items where job.completed && trackedInstagramTurns.contains(job.id) {
                    finishAgentAction(job.id, receipt: job.summary)
                    if job.reportText != nil { notice = "Instagram-opfølgningen ligger nu ved opslaget i chatten." }
                }
            } catch { if Task.isCancelled { return } }
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
        }
    }

    private func instagramCaption(_ subject: String) async throws -> String {
        guard !currentModel.isEmpty else { throw PhoneModelError.unavailable }
        let provider: AgentReplyDriver.Provider
        switch source {
        case .phone: provider = .phone
        case .composio: provider = .cloud
        case .pc:
            guard let api else { throw APIError.offline }
            provider = .computer(api)
        }
        let driver = AgentReplyDriver(provider: provider, model: currentModel)
        let wishes = AgentChatPreferences.instructions(for: bot.id, question: "Instagram", useChatStyle: false)
        return try await driver.respond(to: subject, original: subject, instructions:
            OfflineStudio.companionInstructions(for: bot) + wishes +
            "\nSkriv en kort dansk billedtekst til Instagram ud fra brugerens emne. Giv kun den færdige tekst.",
            history: [], usesTools: false, showsPartialText: false) { _ in }
    }

    @ViewBuilder func agentActionCard(_ turn: PrivateChatTurn) -> some View {
        if let action = turn.agentAction {
            VStack(alignment: .leading, spacing: 16) {
                AgentChatBubble(user: true, title: "Dig", pc: false) { Text(turn.prompt).textSelection(.enabled) }
                AgentChatBubble(user: false, title: bot.name + " · " + action.title, pc: turn.source == "PC") {
                    if let receipt = action.receipt {
                        Text(receipt).textSelection(.enabled)
                        if let link = action.receiptLink {
                            Link("Åbn samtalen i Gmail", destination: link).frame(minHeight: 44)
                            if let api, openAgentAction == turn.id {
                                AgentGmailThreadStatus(api: api, requestID: turn.id, automaticallyChecks: true)
                                    .id(agentActionRefresh)
                            } else if api != nil {
                                Button("Tjek om der er kommet svar", systemImage: "envelope.badge") { openAgentAction = turn.id }
                                    .frame(minHeight: 44)
                            }
                        }
                    } else if openAgentAction == turn.id {
                        agentActionContent(turn, action: action)
                    } else {
                        Button("Åbn opgaven", systemImage: "arrow.turn.down.right") { openAgentAction = turn.id }
                            .frame(minHeight: 44)
                    }
                }
            }
            .privacySensitive()
        }
    }

    @ViewBuilder private func agentActionContent(_ turn: PrivateChatTurn, action: AgentChatAction) -> some View {
        switch action.kind {
        case .gmailReply, .bookingRequest:
            if let api {
                AgentGmailReply(api: api, prompt: turn.prompt, requestID: turn.id, botID: bot.id, storedDraft: action.mailDraft,
                               onDraftChanged: { updateAgentDraft(turn.id, draft: $0) }) { address in
                    guard let link = URL(string: address), link.scheme == "https", link.host == "mail.google.com" else {
                        notice = "Gmail-kvitteringen kunne ikke verificeres. Tjek Sendt før du prøver igen."
                        return
                    }
                    let receipt: String
                    if case .bookingRequest = action.kind { receipt = "Forespørgslen er sendt via Gmail." }
                    else { receipt = "Svar sendt via Gmail." }
                    finishAgentAction(turn.id, receipt: receipt, link: link)
                }
                .id(api.queueTargetID)
            } else {
                FadedDetailText("Opgaven er gemt. Forbind PC’en for at bruge Gmail.")
                if let draft = action.mailDraft { Text(draft.body).textSelection(.enabled) }
            }
        case .phone(let request):
            AgentPhoneActionCard(request: request, botName: bot.name, botID: bot.id) { receipt in
                finishAgentAction(turn.id, receipt: receipt)
            }
        case .today:
            AgentTodayOverview(api: api, botName: bot.name)
        case .appointmentCheck:
            AgentAvailabilityCheck(api: api, prompt: AgentChatIntent.normalize(turn.prompt))
        case .meetingPrep:
            AgentMeetingPrep(prompt: turn.prompt)
        case .mailReminder:
            AgentMailReminderCard(api: api, prompt: turn.prompt, requestID: turn.id, botName: bot.name) { receipt in
                finishAgentAction(turn.id, receipt: receipt)
            }
        case .followups:
            AgentFollowupList(api: api)
        case .instagramPost:
            AgentInstagramPost(api: api, bot: bot, id: turn.id, prompt: turn.prompt,
                               draft: action.instagramDraft, suggest: instagramCaption,
                               requestedPlan: instagramPlanRequest, planApplied: { instagramPlanRequest = nil },
                               save: { saveInstagramDraft(turn.id, draft: $0) },
                               published: { finishAgentAction(turn.id, receipt: $0) })
                .id(api?.queueTargetID ?? "offline")
        case .instagramPlans:
            AgentInstagramPlanner(api: api, bot: bot).id(api?.queueTargetID ?? "offline")
        case .traderaWatch:
            AgentTraderaWatch(api: api, bot: bot, id: turn.id, prompt: turn.prompt, listOnly: false)
                .id(api?.queueTargetID ?? "offline")
        case .traderaWatches:
            AgentTraderaWatch(api: api, bot: bot, id: turn.id, prompt: turn.prompt, listOnly: true)
                .id(api?.queueTargetID ?? "offline")
        case .instagramAccount:
            AgentInstagramAccount(api: api, bot: bot) {
                startAgentAction(.action(.instagramPost), prompt: "Lav et Instagram-opslag")
            }
        case .agentEmail(let request):
            if let api {
                AgentEmailCard(api: api, bot: bot, request: request, prompt: turn.prompt)
                    .id(api.queueTargetID)
            } else {
                FadedDetailText("Forbind til din PC for at bruge agentens e-mail.")
            }
        case .preference:
            AgentPreferenceList(bot: bot)
        case .workflow:
            FadedDetailText("Der er endnu ingen kvittering for opgaven.")
        }
    }

    func saveDraft() {
        guard keepHistory, loaded else { return }
        let value = String(recoverableDraft.prefix(1200))
        guard value != MigratedAppData.shared.chatDraft(draftKey) else { return }
        do { try MigratedAppData.shared.saveChatDraft(value, sessionKey: draftKey) }
        catch { AppDiagnostics.record(error) }
    }

    func send() {
        send(message: cleanDraft, source: source, model: currentModel, useWeb: web, asCard: answerAsCard)
    }
}

private struct AgentPreferenceList: View {
    let bot: VillageBot
    @State private var entries: [AgentChatPreferences.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty { Text("Du har endnu ingen gemte ønsker her.") }
            ForEach(entries, id: \.self) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.value)
                        Text(entry.bot == nil ? "Fælles for dine agenter" : "Kun " + bot.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        AgentChatPreferences.remove(entry)
                        entries = AgentChatPreferences.entries(for: bot.id)
                    } label: {
                        Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Glem " + entry.value)
                }
            }
            FadedDetailText("Skriv fx “Svar mig fremover kort”. Skriv “Til alle agenter: Husk, at jeg foretrækker aftaler efter kl. 10” for at dele et ønske. Relevante ønsker følger med til den model, du vælger.")
        }
        .onAppear { entries = AgentChatPreferences.entries(for: bot.id) }
    }
}
