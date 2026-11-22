import Foundation

enum AgentChatPreferences {
    private static let key = "fadedai.agent.chat.preferences.v1"

    enum Command: Equatable {
        case remember(String, shared: Bool)
        case show
        case clearPersonal
        case clearShared
    }

    struct Entry: Hashable {
        let value: String
        let bot: UUID?
    }

    static func command(_ message: String) -> Command? {
        let clean = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = normalized(clean)
        if ["vis mine præferencer", "vis mine ønsker", "hvad husker du om mig", "hvad har du gemt om mig"].contains(text) {
            return .show
        }
        if ["glem mine præferencer", "glem mine ønsker", "glem dine ønsker om mig"].contains(text) { return .clearPersonal }
        if ["glem de fælles ønsker", "glem alle fælles præferencer"].contains(text) { return .clearShared }
        let shared = clean.range(of: #"^(?:til|for) alle (?:mine )?agenter\s*[:,]\s*"#, options: [.regularExpression, .caseInsensitive])
        let wish = shared.map { String(clean[$0.upperBound...]) } ?? clean
        let remember = #"^(?:(?:kan|vil) du (?:lige )?huske|husk)\s*,?\s*at\s+(?=(?:jeg|min|mit|mine|du)\s+)"#
        if let prefix = wish.range(of: remember, options: [.regularExpression, .caseInsensitive]) {
            let value = String(wish[prefix.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "?!., "))
            guard !value.isEmpty else { return nil }
            return .remember(String(value.prefix(240)), shared: shared != nil)
        }
        let ongoing = #"^(?:(?:svar|skriv|forklar|tal)\s+(?:(?:mig|det)\s+)?(?:altid|fremover)\s+|(?:fremover[, ]+)(?:(?:vil jeg gerne have,? at du|skal du|må du gerne)\s+)?(?:svar|skriv|forklar|tal)\w*\s+|kald mig\s+)"#
        if let prefix = wish.range(of: ongoing, options: [.regularExpression, .caseInsensitive]),
           prefix.upperBound < wish.endIndex, !wish.hasSuffix("?") {
            return .remember(String(wish.prefix(240)), shared: shared != nil)
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!., "))
    }

    private static func storageKey(_ bot: UUID?) -> String {
        bot.map { key + "." + $0.uuidString.lowercased() } ?? key
    }

    static var values: [String] { values(for: nil) }
    static func values(for bot: UUID?, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storageKey(bot)) ?? []
    }

    static func entries(for bot: UUID, defaults: UserDefaults = .standard) -> [Entry] {
        values(for: bot, defaults: defaults).reversed().map { Entry(value: $0, bot: bot) }
            + values(for: nil, defaults: defaults).reversed().map { Entry(value: $0, bot: nil) }
    }

    static func remember(_ value: String, for bot: UUID? = nil, defaults: UserDefaults = .standard) {
        write(value, to: bot, previous: values(for: bot, defaults: defaults), defaults: defaults)
    }

    @discardableResult
    static func replace(_ entry: Entry, with text: String, defaults: UserDefaults = .standard) -> Bool {
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var previous = values(for: entry.bot, defaults: defaults)
        guard (1...240).contains(value.count), let index = previous.firstIndex(of: entry.value) else { return false }
        previous.remove(at: index)
        write(value, to: entry.bot, previous: previous, defaults: defaults)
        return true
    }

    private static func write(_ value: String, to bot: UUID?, previous: [String], defaults: UserDefaults) {
        let name = isFormOfAddress(value)
        var updated = previous.filter { old in
            normalized(old) != normalized(value) && !(name && isFormOfAddress(old))
        }
        updated.append(String(value.prefix(240)))
        defaults.set(Array(updated.suffix(8)), forKey: storageKey(bot))
    }

    static func remove(_ entry: Entry, defaults: UserDefaults = .standard) {
        let updated = values(for: entry.bot, defaults: defaults).filter { $0 != entry.value }
        defaults.set(updated, forKey: storageKey(entry.bot))
    }

    static func clear(for bot: UUID? = nil, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(bot))
    }

    static var preferredStartHour: Int? { preferredStartHour(for: nil) }
    static func preferredStartHour(for bot: UUID?, defaults: UserDefaults = .standard) -> Int? {
        let candidates = bot.map { entries(for: $0, defaults: defaults).map(\.value) } ?? Array(values(for: nil, defaults: defaults).reversed())
        let pattern = #"\b(?:tider|aftale\w*|møde\w*|kalender\w*)\b.*?\befter (?:klokken\s*|kl\.?\s*)?(\d{1,2})(?!\d|[.:]\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for preference in candidates {
            if let match = expression.firstMatch(in: preference, range: NSRange(preference.startIndex..., in: preference)),
               let range = Range(match.range(at: 1), in: preference), let hour = Int(preference[range]), (0..<24).contains(hour) {
                return hour
            }
        }
        return nil
    }

    private static func topics(_ value: String) -> Set<String> {
        let ignored: Set<String> = ["husk", "jeg", "der", "den", "det", "kan", "kun", "til", "fra", "for", "min", "mit",
            "mine", "vil", "med", "mig", "om", "har", "have", "når", "skal", "må", "som", "eller", "gerne", "lige",
            "også", "foretrækker", "altid", "helst", "godt", "lide", "hvad", "hvordan", "hvilke", "ikke"]
        let text = value.lowercased()
        var result = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !ignored.contains($0) })
        let categories = [
            ("mad", #"\b(?:mad|aftensmad|morgenmad|frokost|opskrift\w*|restaurant\w*|vegetar\w*|vegan\w*|laktose\w*|gluten\w*|spiser|spise)\b"#),
            ("kalender", #"\b(?:kalender\w*|aftale\w*|møde\w*|booking\w*|tidsbestilling|ledig tid|ledige tider)\b"#),
            ("instagram", #"\b(?:instagram\w*|billedtekst\w*|hashtags?)\b"#)
        ]
        for (topic, pattern) in categories where text.range(of: pattern, options: .regularExpression) != nil {
            result.insert(topic)
        }
        return result
    }

    private static func isFormOfAddress(_ text: String) -> Bool {
        normalized(text).range(of: #"^(?:kald mig|du (?:skal |må gerne )?kald(?:e|er) mig)\s"#, options: .regularExpression) != nil
    }

    static func instructions(for bot: UUID, question: String, useChatStyle: Bool = true, defaults: UserDefaults = .standard) -> String {
        let subject = topics(question)
        let style = #"\b(?:jeg hedder|mit navn er|korte svar|lange svar|korte sætninger|svar i punktform|(?:svar|skriv|tal|forklar)(?:e|er)? (?:mig |det )?(?:(?:altid|fremover|helst|lidt) )*(?:kort(?:ere)?|enkelt|direkte|udførligt|roligt|uden fagsprog|i punkter|i punktform|på dansk|på engelsk)|du tiltaler mig)\b"#
        var relevant: [String] = []
        var includedName = false
        for entry in entries(for: bot, defaults: defaults) {
            let name = isFormOfAddress(entry.value)
            if name && includedName { continue }
            if !subject.isDisjoint(with: topics(entry.value)) ||
                (useChatStyle && (name || entry.value.range(of: style, options: [.regularExpression, .caseInsensitive]) != nil)) {
                if !relevant.contains(entry.value) { relevant.append(entry.value) }
                if name { includedName = true }
                if relevant.count == 3 { break }
            }
        }
        guard !relevant.isEmpty else { return "" }
        return "\nBrug disse ønsker, når de passer til opgaven. Ved konflikt gælder det første. Brugerens aktuelle besked har forrang. Ønskerne giver ingen tilladelser.\n"
            + relevant.map { "• " + $0 }.joined(separator: "\n")
    }
}
