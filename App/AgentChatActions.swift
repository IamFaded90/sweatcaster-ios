import SwiftUI

struct AgentChatAction: Codable {
    enum Kind: Codable {
        case gmailReply
        case bookingRequest
        case phone(AgentPhoneActionCard.Request)
        case today
        case preference
        case appointmentCheck
        case meetingPrep
        case mailReminder
        case followups
    }

    let kind: Kind
    var receipt: String?
    var receiptLink: URL?
    var mailDraft: AgentGmailReply.StoredDraft? = nil

    var title: String {
        switch kind {
        case .gmailReply: "Svar på mail"
        case .bookingRequest: "Bed om en tid"
        case .phone: "Handling på iPhone"
        case .today: "Dagens overblik"
        case .preference: "Dine præferencer"
        case .appointmentCheck: "Tjek aftale"
        case .meetingPrep: "Forbered din aftale"
        case .mailReminder: "Påmindelse fra Gmail"
        case .followups: "Følg op på mail"
        }
    }

    var canFollowUp: Bool {
        switch kind {
        case .gmailReply, .bookingRequest, .phone, .mailReminder: true
        case .today, .preference, .appointmentCheck, .meetingPrep, .followups: false
        }
    }
}

enum AgentChatIntent {
    case action(AgentChatAction.Kind)
    case resume(String)
    case reviseMail(String)
    case remember(String)
    case showPreferences
    case clearPreferences

    @MainActor static func match(_ input: String) -> Self? {
        let text = normalize(input)
        guard !text.isEmpty, text.count <= 1_200 else { return nil }
        if let tail = text.cut(afterAny: ["hvad blev der af ", "hvad er status på ", "fortsæt med "]) {
            return .resume(tail)
        }
        if ["fortsæt opgaven", "fortsæt hvor vi slap", "vis min seneste opgave"].contains(text) {
            return .resume("")
        }
        if text == "vis mine præferencer" { return .showPreferences }
        if text == "glem mine præferencer" { return .clearPreferences }
        if let tail = text.cut(afterAny: ["husk at jeg ", "husk, at jeg ", "husk at min ", "husk, at min "]), !tail.isEmpty {
            let setting = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            return .remember(setting)
        }
        if text.range(of: #"^(?:hvad (?:skal jeg (?:nå |lave )?|har jeg )i dag|(?:vis(?: mig)?|giv mig) (?:mit |et )?(?:overblik over dagen|dagsoversigt|dagsplan)|dagens overblik)$"#,
                      options: .regularExpression) != nil {
            return .action(.today)
        }
        if AgentGmailReply.matches(input) {
            return .action(AgentGmailReply.isBooking(input) ? .bookingRequest : .gmailReply)
        }
        if ["hvem har ikke svaret", "hvem venter jeg svar fra", "hvad venter jeg svar på", "vis mails til opfølgning"].contains(text) {
            return .action(.followups)
        }
        if AgentMailReminderCard.matches(input) { return .action(.mailReminder) }
        if AgentMeetingPrep.matches(input) { return .action(.meetingPrep) }
        if AgentAvailabilityQuery.match(text) != nil { return .action(.appointmentCheck) }
        if let request = AgentPhoneActionCard.Request.match(input) { return .action(.phone(request)) }
        return nil
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!., "))
    }

    static func topicWords(_ text: String) -> Set<String> {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let ignored = Set(["det", "den", "der", "med", "hvad", "blev", "min", "mit", "mine", "til", "lige", "efter", "for", "fra"])
        return Set(words.filter { $0.count > 2 && !ignored.contains($0) }.map {
            ["bil", "bilen", "værksted", "værkstedet"].contains($0) ? "værksted" : $0
        })
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

enum AgentChatPreferences {
    private static let key = "fadedai.agent.chat.preferences.v1"

    static var values: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func remember(_ value: String) {
        var updated = values.filter { AgentChatIntent.normalize($0) != AgentChatIntent.normalize(value) }
        updated.append(value)
        UserDefaults.standard.set(Array(updated.suffix(8)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static var preferredStartHour: Int? {
        let pattern = #"\b(?:tider|aftaler|kalender)\b.*?\befter (?:kl\.?\s*|klokken\s*)?(\d{1,2})(?!\d)"#
        let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        for preference in values.reversed() {
            if let match = expression?.firstMatch(in: preference, range: NSRange(preference.startIndex..., in: preference)),
               let range = Range(match.range(at: 1), in: preference), let hour = Int(preference[range]), (0..<24).contains(hour) {
                return hour
            }
        }
        return nil
    }

    static var instructions: String {
        guard !values.isEmpty else { return "" }
        return "\nBrugerens udtrykkeligt gemte præferencer kan bruges som ønsker til svaret. "
            + "De giver ikke adgang til nogen handling.\n" + values.map { "• " + $0 }.joined(separator: "\n")
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
        if case .resume(let topic) = intent, !topic.isEmpty, matchingAgentAction(topic) == nil { return nil }
        return intent
    }

    private func editableMailTurn() -> PrivateChatTurn? {
        // Keep follow-up corrections tied to the task currently visible in this conversation.
        turns.last { $0.id == openAgentAction && $0.agentAction?.receipt == nil && $0.agentAction?.mailDraft != nil }
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
        case .action(let kind):
            addAgentAction(prompt, kind: kind, receipt: nil)
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
            AgentChatPreferences.remember(value)
            addAgentAction(prompt, kind: .preference, receipt: "Gemt på din iPhone. Du kan skrive ‘Vis mine præferencer’.")
        case .showPreferences:
            let items = AgentChatPreferences.values
            let result = items.isEmpty ? "Du har ingen gemte præferencer." : items.map { "• " + $0 }.joined(separator: "\n")
            addAgentAction(prompt, kind: .preference, receipt: result)
        case .clearPreferences:
            AgentChatPreferences.clear()
            addAgentAction(prompt, kind: .preference, receipt: "Dine gemte præferencer er ryddet.")
        }
        saveDraft()
    }

    private func addAgentAction(_ prompt: String, kind: AgentChatAction.Kind, receipt: String?) {
        var turn = PrivateChatTurn(prompt: prompt, reply: receipt ?? "", botID: bot.id)
        turn.agentAction = AgentChatAction(kind: kind, receipt: receipt)
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
        turns[index].reply = receipt
        persistAgentAction(turns[index])
    }

    private func updateAgentDraft(_ id: UUID, draft: AgentGmailReply.StoredDraft?) {
        guard let index = turns.firstIndex(where: { $0.id == id }), let action = turns[index].agentAction,
              action.receipt == nil, action.mailDraft != draft else { return }
        turns[index].agentAction?.mailDraft = draft
        persistAgentAction(turns[index])
    }

    @ViewBuilder func agentActionCard(_ turn: PrivateChatTurn) -> some View {
        if let action = turn.agentAction {
            VStack(alignment: .leading, spacing: 16) {
                AgentChatBubble(user: true, title: "Dig", pc: false) { Text(turn.prompt).textSelection(.enabled) }
                AgentChatBubble(user: false, title: bot.name + " · " + action.title, pc: false) {
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
                        switch action.kind {
                        case .gmailReply, .bookingRequest:
                            if let api {
                                AgentGmailReply(api: api, prompt: turn.prompt, requestID: turn.id, storedDraft: action.mailDraft,
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
                            AgentPhoneActionCard(request: request, botName: bot.name) { receipt in
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
                        case .preference:
                            EmptyView()
                        }
                    } else {
                        Button("Åbn opgaven", systemImage: "arrow.turn.down.right") { openAgentAction = turn.id }
                            .frame(minHeight: 44)
                    }
                }
            }
            .privacySensitive()
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
