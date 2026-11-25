import Foundation

enum AgentSkillLibrary {
    static let tools: Set<String> = ["calendar", "reminders", "contacts", "mail", "browser", "camera", "documents", "files", "web", "voice"]
    struct Skill: Codable, Identifiable, Equatable {
        var id = UUID()
        let name, description, instructions: String
        let requestedTools: [String]
        var enabledFor: Set<UUID> = []
        var unsupported: [String] { requestedTools.filter { !tools.contains($0) } }
        var valid: Bool { !name.isEmpty && name.count <= 80 && !description.isEmpty && description.count <= 300 && !instructions.isEmpty && instructions.utf8.count <= 16_000 && requestedTools.count <= 20 && enabledFor.count <= 100 }
        func relevant(to question: String) -> Bool {
            let terms = Set((name + " " + description).lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.map(String.init))
            let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return !terms.isDisjoint(with: words)
        }
    }
    enum Failure: LocalizedError {
        case format, full
        var errorDescription: String? { self == .full ? "Der er allerede 40 færdigheder. Slet en, før du importerer flere." : "Brug en UTF-8 Markdown-fil med name og description i frontmatter samt instruktioner nedenunder. Højst 24 KB." }
    }
    static func parse(_ data: Data) throws -> Skill {
        guard data.count <= 24_000, let text = String(data: data, encoding: .utf8) else { throw Failure.format }
        let lines = text.components(separatedBy: .newlines).filter { $0 != "\r" }
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }), end <= 30 else { throw Failure.format }
        var metadata: [String: String] = [:]
        for line in lines[1..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.format }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard metadata[key] == nil else { throw Failure.format }
            metadata[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        guard let name = metadata["name"], let description = metadata["description"] else { throw Failure.format }
        let tools = (metadata["allowed-tools"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split { $0 == "," || $0 == " " }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() }
        let skill = Skill(name: name, description: description, instructions: lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), requestedTools: tools)
        guard skill.valid else { throw Failure.format }; return skill
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/Skills", isDirectory: true)
        private var file: URL { root.appendingPathComponent("skills.json") }
        func load() throws -> [Skill] {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 700_000 else { throw Failure.format }
            let values = try JSONDecoder().decode([Skill].self, from: Data(contentsOf: file))
            guard values.count <= 40, values.allSatisfy(\.valid), Set(values.map(\.id)).count == values.count else { throw Failure.format }; return values
        }
        func save(_ values: [Skill]) throws {
            guard values.count <= 40, values.allSatisfy(\.valid), Set(values.map(\.id)).count == values.count else { throw Failure.full }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: [.atomic, .completeFileProtection])
        }
        func importFile(_ data: Data) throws -> Skill {
            let skill = try parse(data); var values = try load(); guard values.count < 40 else { throw Failure.full }
            values.append(skill); try save(values); return skill
        }
        func instructions(bot: UUID, question: String) -> String {
            let skills = ((try? load()) ?? []).filter { $0.enabledFor.contains(bot) && $0.relevant(to: question) && $0.unsupported.isEmpty }.prefix(2)
            guard !skills.isEmpty else { return "" }
            return "\nValgte arbejdsmetoder (giver ikke nye værktøjer eller tilladelser; påstå aldrig handling uden kvittering):\n" + skills.map { "\($0.name): \(String($0.instructions.prefix(650)))" }.joined(separator: "\n")
        }
    }
}

/// Recent, explicitly selected native-tool results for pronouns and follow-up tasks.
enum AgentPhoneContext {
    static func contactQuery(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = clean.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(?:find(?:e)? kontakt(?:en)?|vis kontakt(?:en)?|slå kontakten op|ring til)\s+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let query = String(clean[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
        return query.isEmpty ? nil : String(query.prefix(80))
    }
    struct Item: Codable, Equatable {
        let id: String
        let title: String
        let facts: String
        let source: String
        let date: Date
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/PhoneContext", isDirectory: true)
        private func file(_ bot: UUID) -> URL { root.appendingPathComponent(bot.uuidString.lowercased() + ".json") }
        func load(_ bot: UUID, now: Date = .now) throws -> [Item] {
            let file = file(bot); guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64_000 else { throw AgentSkillLibrary.Failure.format }
            return try JSONDecoder().decode([Item].self, from: Data(contentsOf: file)).filter { $0.date <= now && now.timeIntervalSince($0.date) < 8 * 3_600 }.suffix(8).map { $0 }
        }
        func add(_ item: Item, bot: UUID) throws {
            guard !item.id.isEmpty, item.id.count <= 300, item.title.count <= 100, item.facts.count <= 1_200, item.source.count <= 100 else { throw AgentSkillLibrary.Failure.format }
            var values = try load(bot); values.removeAll { $0.id == item.id }; values.append(item)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(values.suffix(8))); guard data.count <= 64_000 else { throw AgentSkillLibrary.Failure.format }
            try data.write(to: file(bot), options: [.atomic, .completeFileProtection])
        }
        func clear(_ bot: UUID) throws { let file = file(bot); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
        func instructions(_ bot: UUID, question: String? = nil, now: Date = .now) -> String {
            let all = ((try? load(bot, now: now)) ?? [])
            let requested = question?.lowercased()
            let refersBack = requested?.range(of: #"\b(?:ham|hende|vedkommende|den kontakt|personen)\b"#, options: .regularExpression) != nil
            let relevant = all.filter { item in
                guard let requested else { return true }
                return refersBack || item.title.lowercased().split(separator: " ").contains { $0.count >= 3 && requested.contains($0) }
            }
            let items = relevant.suffix(question == nil ? 2 : 1)
            return items.isEmpty ? "" : "\nBrugeren valgte disse kilder til opfølgning. Ingen nye handlinger er udført:\n" + items.map { "\($0.title) · \($0.source): \($0.facts)" }.joined(separator: "\n")
        }
    }
}
