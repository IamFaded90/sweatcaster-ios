import Foundation

struct PersonalMediaLink: Codable, Equatable, Identifiable {
    let id: UUID
    let botID: UUID
    let imageName: String
    let prompt: String
    let musicID: String
    let musicTitle: String
    let musicArtist: String
    let created: Date
    struct Store {
        var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/media-links.json")
        func load() throws -> [PersonalMediaLink] {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            let data = try Data(contentsOf: file)
            guard data.count < 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode([PersonalMediaLink].self, from: data)
        }
        func remember(_ value: PersonalMediaLink) throws {
            var values = try load().filter { $0.id != value.id }; values.append(value)
            try write(Array(values.suffix(500)))
        }
        func remove(_ id: UUID) throws { try write(load().filter { $0.id != id }) }
        private func write(_ values: [PersonalMediaLink]) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
        }
    }
}

enum PersonalHubRecall {
    enum Kind: String { case conversation = "Samtale", image = "Billede", music = "Musik", file = "Fil", creative = "Kreativt forløb", film = "Film", task = "Opgave" }
    struct Record: Identifiable {
        let id: String
        let kind: Kind
        let title: String
        let text: String
        var botID: UUID?
        var relatedMusicID: String?
        var ephemeral = false
    }
    static func matches(_ query: String, records: [Record], botID: UUID? = nil) -> [Record] {
        let tokens = words(query)
        let relation = tokens.contains("musik") && tokens.contains("billede")
        let allowed = records.enumerated().filter { _, item in
            !item.ephemeral && (botID == nil || item.botID == nil || item.botID == botID)
                && (!relation || (item.kind == .image && item.relatedMusicID != nil))
        }
        func score(_ item: Record) -> Int {
            if tokens.isEmpty { return 1 }
            let title = words(item.title), content = words(item.text + " " + item.kind.rawValue)
            return tokens.intersection(title).count * 5 + tokens.intersection(content).count * 2
        }
        return Array(allowed.filter { score($0.element) > 0 }.sorted {
            score($0.element) == score($1.element) ? $0.offset > $1.offset : score($0.element) > score($1.element)
        }.prefix(40).map(\.element))
    }
    static func command(_ input: String) -> String? {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^(?:hvilken|hvad hed).*\b(?:sang|nummer|musik)\b.*\b(?:billede|billedet|foto|fotoet)\b"#, options: .regularExpression) != nil { return input }
        let prefix = #"^find (?:i|blandt) mine (?:ting|filer|billeder|projekter|samtaler)\s*[: ]*"#
        if let range = text.range(of: prefix, options: .regularExpression) { return String(text[range.upperBound...]) }
        return nil
    }
    static func gmailQuery(_ question: String) -> String {
        if question.contains(":") { return String(question.prefix(500)) }
        let ignored = Set("hvad hvem hvor hvornår jeg mig min mine det den har havde aftalte aftalt aftaler med til fra for siger sagde skrev email mail mails gmail seneste læs find kig kan du vi blev der at og om".split(separator: " ").map(String.init))
        let keywords = question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 2 && !ignored.contains($0) }.prefix(6)
        return keywords.map { $0 == "tandlægen" ? "tandlæge" : $0 }.joined(separator: " ")
    }
    private static func words(_ text: String) -> Set<String> {
        let stop = Set("hvad hvilken hvem hvor hed jeg min mine mit det den der med mens da vi til fra som har var og om kan du find lavede lavet når hvadfor".split(separator: " ").map(String.init))
        return Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { word -> String in
                let value = String(word)
                if ["sang", "sangen", "nummer", "nummeret", "musik"].contains(value) { return "musik" }
                if ["billede", "billedet", "foto", "fotoet"].contains(value) { return "billede" }
                return value
            }.filter { $0.count > 2 && !stop.contains($0) })
    }
}
