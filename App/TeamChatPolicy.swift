import Foundation

struct TeamSavedGroup: Codable, Identifiable {
    static let limit = 20
    let id: UUID
    let name: String
    let members: [UUID]

    var isValid: Bool {
        (1...60).contains(name.unicodeScalars.count) && !name.contains("\0")
            && (2...6).contains(members.count) && Set(members).count == members.count
    }
}

enum TeamChatPolicy {
    enum PhoneFact {
        case time, date, weekday

        func answer(now: Date = .now, calendar: Calendar = .current) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "da_DK")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            switch self {
            case .time:
                formatter.dateFormat = "HH:mm"
                return "Klokken er \(formatter.string(from: now))."
            case .date:
                formatter.dateFormat = "d. MMMM yyyy"
                return "I dag er det \(formatter.string(from: now))."
            case .weekday:
                formatter.dateFormat = "EEEE"
                return "I dag er det \(formatter.string(from: now))."
            }
        }
    }

    static func phoneFact(for message: String) -> PhoneFact? {
        let text = message.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.! "))
        switch text {
        case "klokken", "klokken nu", "hvad er klokken", "hvad er klokken nu", "hvad er klokken lige nu",
             "hvad er klokken her", "hvad er klokken på min iphone", "hvad er kl", "hvad er kl nu", "hvad er kl lige nu",
             "hvad er kl. nu", "hvad er klokkeslættet",
             "kan du sige hvad klokken er", "kan du sige, hvad klokken er": return .time
        case "hvad er datoen", "hvad er datoen i dag", "hvilken dato er det", "hvilken dato er det i dag": return .date
        case "hvilken dag er det i dag", "hvilken ugedag er det", "hvilken ugedag er det i dag", "hvad dag er det i dag": return .weekday
        default: return nil
        }
    }

    static func instructions(at position: Int) -> String {
        if position == 0 {
            return "Du giver holdets hovedsvar. Besvar brugerens spørgsmål kort og konkret. Spørg om én nødvendig oplysning, hvis noget er uklart."
        }
        let angles = ["Find en konkret fejl eller en vigtig undtagelse.", "Foreslå ét anderledes, brugbart alternativ.",
                      "Peg på én praktisk risiko og en måde at undgå den.", "Find det mest nyttige næste skridt, der mangler.",
                      "Brug dit speciale til at fylde ét vigtigt hul."]
        return "Du gennemgår holdets svar. \(angles[min(position - 1, angles.count - 1)]) " +
            "Skriv kun din nye pointe i højst to sætninger. Skriv kun PAS, hvis du ikke har noget nyt."
    }

    static func contribution(_ reply: String, after previous: [String]) -> String? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        let sentence = words.joined(separator: " ")
        let pass = ["pas", "jeg passer", "ingen tilføjelse", "ingen ændringer", "jeg har ikke noget at tilføje",
                    "jeg har intet at tilføje", "jeg er enig", "helt enig"]
        guard !pass.contains(sentence), !previous.contains(where: { duplicate(words, tokens($0)) }) else { return nil }
        return text
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func duplicate(_ first: [String], _ second: [String]) -> Bool {
        if first == second { return true }
        guard first.count >= 12, second.count >= 12 else { return false }
        let markers = Set(["ikke", "aldrig", "ingen", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"])
        let significant: ([String]) -> [String] = { $0.filter { word in
            markers.contains(word) || word.contains(where: \.isNumber)
        } }
        guard significant(first) == significant(second) else { return false }
        let triples: ([String]) -> Set<String> = { words in
            Set((0..<(words.count - 2)).map { words[$0...($0 + 2)].joined(separator: " ") })
        }
        let a = triples(first), b = triples(second)
        return Double(a.intersection(b).count) / Double(max(a.count, b.count)) >= 0.80
    }
}
