import Foundation

enum AgentShoppingRequest: Codable, Equatable {
    case view
    case add([String])

    static func match(_ prompt: String) -> Self? {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.localizedCaseInsensitiveContains("indkøbsliste") else { return nil }
        let prefix = #"^(?:(?:kan|vil) du (?:lige )?)?"#
        let list = #"(?:(?:min|vores) )?indkøbsliste(?:n)?"#
        if raw.range(of: prefix + #"(?:vis(?:e)?(?: mig)? |læs(?:e)? |hvad (?:står|er|mangler) (?:der )?på )"# + list + #"[.?! ]*$"#,
                     options: [.regularExpression, .caseInsensitive]) != nil { return .view }
        let patterns = [prefix + #"(?:tilføj(?:e)?|skriv(?:e)?|sæt(?:te)?|føj(?:e)?) (.+?) (?:på|til) "# + list + #"[.?! ]*$"#,
                        prefix + #"(?:lav(?:e)?|opret(?:te)?) (?:en |min )?indkøbsliste(?: med|:)\s*(.+?)[.?! ]*$"#,
                        #"^indkøbsliste:\s*(.+?)[.?! ]*$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            let parts = raw[range].replacingOccurrences(of: #"(?<!\d),|,(?!\d)|[;\n]|\s+og\s+"#, with: "\n",
                                                       options: [.regularExpression, .caseInsensitive])
            var seen = Set<String>()
            let items = parts.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
            if !items.isEmpty { return .add(items) }
        }
        return nil
    }

    static func key(_ item: String) -> String {
        item.lowercased().replacingOccurrences(of: #"^køb\s+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func titles(in reminder: String) -> [String] {
        let raw = reminder.replacingOccurrences(of: #"^køb\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        if case .add(let items) = match(raw) { return items }
        return [raw]
    }

    func destinationIDs(named: [String], writable: Set<String>, standard: String?) -> [String] {
        let editable = named.filter(writable.contains)
        switch self {
        case .add:
            if editable.isEmpty, let standard, writable.contains(standard) { return [standard] }
            return editable
        case .view:
            var ids = editable
            if editable.isEmpty, let standard { ids.append(standard) }
            for id in named where !ids.contains(id) { ids.append(id) }
            if let standard, !ids.contains(standard) { ids.append(standard) }
            return ids
        }
    }
}

struct AgentShoppingRow: Sendable {
    let title: String
    let marker: String?
    let done: Bool
    var isShopping: Bool { marker?.hasPrefix("fadedai://shopping/") == true || title.lowercased().hasPrefix("køb ") }
}

struct AgentShoppingPlan {
    struct Entry {
        let title: String
        let marker: String
    }
    let additions: [Entry]
    let existing: [String]

    init(original: [String], selected: Set<String>, requestID: UUID, rows: [AgentShoppingRow], defaultList: Bool) {
        let open = Set(rows.filter { !$0.done && (!defaultList || $0.isShopping) }
            .flatMap { AgentShoppingRequest.titles(in: $0.title) }.map(AgentShoppingRequest.key))
        let markers = Set(rows.compactMap(\.marker))
        var additions: [Entry] = []
        var existing: [String] = []
        for (index, title) in original.enumerated() where selected.contains(title) {
            let marker = "fadedai://shopping/" + requestID.uuidString.lowercased() + "/" + String(index)
            if open.contains(AgentShoppingRequest.key(title)) || markers.contains(marker) {
                existing.append(title)
            } else {
                additions.append(Entry(title: title, marker: marker))
            }
        }
        self.additions = additions
        self.existing = existing
    }
}

enum AgentUnitPrice {
    private struct Offer {
        let text: String
        let unit: String
        let price: Decimal
        let amount: Decimal
    }

    static func answer(_ prompt: String) -> String? {
        let text = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("billigst") || text.hasPrefix("sammenlign") else { return nil }
        let start = #"^(?:(?:hvad|hvilket|hvilket tilbud|hvilken pakke) er billigst|sammenlign(?: de to tilbud)?)\b[\s,:–-]*"#
        guard let prefix = text.range(of: start, options: .regularExpression) else { return nil }
        let tail = String(text[prefix.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "?.! "))
        let parts = tail.replacingOccurrences(of: #",?\s+(?:eller|mod|med|kontra|vs\.?)\s+"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
        guard parts.count == 2, let first = offer(parts[0]), let second = offer(parts[1]) else { return nil }
        guard first.unit == second.unit else { return "De to tilbud skal have samme slags enhed. Brug vægt, rumfang eller antal for begge." }
        let a = first.price * second.amount
        let b = second.price * first.amount
        let winner = a == b ? "De koster det samme pr. " + first.unit + "." :
            (a < b ? first.text : second.text) + " er billigst pr. " + first.unit + "."
        let format = Decimal.FormatStyle(locale: Locale(identifier: "da_DK")).precision(.fractionLength(2...4))
        func detail(_ offer: Offer) -> String {
            let value = (offer.price / offer.amount).formatted(format)
            return offer.text + " → " + value + " kr./" + offer.unit
        }
        return [winner, detail(first), detail(second)].joined(separator: "\n")
    }

    private static func offer(_ text: String) -> Offer? {
        let number = #"(\d{1,3}(?:\.\d{3}){1,2}(?:,\d{1,3})?|\d{1,8}(?:[,.]\d{1,3})?)"#
        let quantity = number + #"\s*(kg|kilo|g|gram|ml|cl|dl|l|liter|stk\.?|styk|stykker)"#
        let money = number + #"\s*(?:kr\.?|kroner|dkk)"#
        let quantityFirst = "^" + quantity + #"\s+(?:(?:til|for)\s+)?"# + money + "$"
        let priceFirst = "^" + money + #"\s+for\s+"# + quantity + "$"
        func find(_ pattern: String) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        }
        let weightFirst = find(quantityFirst)
        guard let match = weightFirst ?? find(priceFirst) else { return nil }
        let ns = text as NSString
        func decimal(_ n: Int) -> Decimal? {
            var value = ns.substring(with: match.range(at: n))
            if value.range(of: #"^\d{1,3}(?:\.\d{3})+(?:,\d{1,3})?$"#, options: .regularExpression) != nil {
                value = value.replacingOccurrences(of: ".", with: "")
            }
            return Decimal(string: value.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
        }
        guard let amount = decimal(weightFirst == nil ? 2 : 1), amount > 0, let price = decimal(weightFirst == nil ? 1 : 3) else { return nil }
        let unit = ns.substring(with: match.range(at: weightFirst == nil ? 3 : 2))
        let scale: Decimal
        let label: String
        switch unit {
        case "g", "gram": scale = 1000; label = "kg"
        case "kg", "kilo": scale = 1; label = "kg"
        case "ml": scale = 1000; label = "l"
        case "cl": scale = 100; label = "l"
        case "dl": scale = 10; label = "l"
        case "l", "liter": scale = 1; label = "l"
        default: scale = 1; label = "stk."
        }
        return Offer(text: text, unit: label, price: price, amount: amount / scale)
    }
}
