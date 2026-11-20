import Foundation

enum AgentChatIntent {
    case action(AgentChatAction.Kind)
    case windowHelp
    case phoneScreen
    case sales
    case surprise
    case builtTools
    case appointmentChange
    case gmailCleanup
    case pcRepair
    case agentComputer(String)
    case milestone(AgentMilestone)
    case chooseTaste
    case taste(AgentTasteRequest)
    case resume(String)
    case reviseMail(String)
    case scheduleInstagram(AgentInstagramTiming)
    case remember(String)
    case rememberForAll(String)
    case showPreferences
    case clearPreferences
    case clearSharedPreferences

    @MainActor static func match(_ input: String) -> Self? {
        let text = normalize(input)
        guard !text.isEmpty, text.count <= 1_200 else { return nil }
        if let milestone = AgentMilestone.match(input) { return .milestone(milestone) }
        if AgentAppointmentChangeIntent.matches(input) { return .appointmentChange }
        if AgentGmailCleanupIntent.matches(input) { return .gmailCleanup }
        if let goal = AgentComputerIntent.goal(input) { return .agentComputer(goal) }
        if AgentPCRepairIntent.matches(input) { return .pcRepair }
        if AgentScreenIntent.matches(input) { return .phoneScreen }
        if AgentSalesIntent.matches(input) { return .sales }
        if VillageSurpriseIntent.matches(input) { return .surprise }
        if AgentToolBuildIntent.matches(text) { return .builtTools }
        if text.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(?:tag(?:e)? over på|overtag(?:e)?|betjen(?:e)?|styr(?:e)?) min (?:pc|computer)\b"#, options: .regularExpression) != nil {
            return .windowHelp
        }
        if AgentWindowIntent.matches(input) { return .windowHelp }
        if ["lær min smag", "lær min smag at kende", "prøv to og vælg"].contains(text) { return .chooseTaste }
        if let request = AgentTasteRequest.parse(text) { return .taste(request) }
        if let request = AgentTraderaIntent.match(text) { return .action(request) }
        if let tail = text.cut(afterAny: ["hvad blev der af ", "hvad er status på ", "fortsæt med "]) {
            return .resume(tail)
        }
        if ["fortsæt opgaven", "fortsæt hvor vi slap", "vis min seneste opgave"].contains(text) {
            return .resume("")
        }
        if let command = AgentChatPreferences.command(input) {
            switch command {
            case .remember(let value, let shared): return shared ? .rememberForAll(value) : .remember(value)
            case .show: return .showPreferences
            case .clearPersonal: return .clearPreferences
            case .clearShared: return .clearSharedPreferences
            }
        }
        if text.range(of: #"^(?:hvad (?:skal jeg (?:nå |lave )?|har jeg )i dag|(?:vis(?: mig)?|giv mig) (?:mit |et )?(?:overblik over dagen|dagsoversigt|dagsplan)|dagens overblik)$"#,
                      options: .regularExpression) != nil || matchesTodayOverview(text) {
            return .action(.today)
        }
        if let request = AgentInstagramIntent.match(text) { return .action(request) }
        if text.range(of: #"^(?:(?:kan|vil) du (?:lige |godt )?)?(?:post(?:e)?|udgiv(?:e)?|planlæg(?:ge)?) (?:den|det|opslaget|kladden)\b"#, options: .regularExpression) != nil,
           let timing = AgentInstagramTiming.requested(in: text) { return .scheduleInstagram(timing) }
        if let request = AgentEmailRequest.match(text) { return .action(.agentEmail(request)) }
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

    static func matchesTodayOverview(_ text: String) -> Bool {
        let pattern = #"^(?:(?:kan|vil) du (?:lige )?)?(?:(?:vis(?:e)?(?: mig)?|giv(?:e)? mig|lav(?:e)?(?: mig)?) (?:mit |et |en )?(?:overblik over (?:min dag|hele dagen)|dagsoversigt|dagsplan)|hvad (?:skal jeg huske|har jeg på programmet|er der på min dagsplan) i dag|hvilke planer har jeg i dag|har jeg noget jeg skal i dag)$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func topicWords(_ text: String) -> Set<String> {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let ignored = Set(["det", "den", "der", "med", "hvad", "blev", "min", "mit", "mine", "til", "lige", "efter", "for", "fra"])
        return Set(words.filter { $0.count > 2 && !ignored.contains($0) }.map {
            ["bil", "bilen", "værksted", "værkstedet"].contains($0) ? "værksted" : $0
        })
    }
}

private extension String {
    func cut(afterAny prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: hasPrefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
