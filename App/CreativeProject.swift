import Foundation

struct CreativeProject: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case invitation = "Invitation", poster = "Plakat", room = "Agentrum", story = "Historie"
        var id: Self { self }
    }
    struct Draft: Codable, Equatable { let title, text, imagePrompt: String }
    var id = UUID()
    let botID: UUID
    var kind = Kind.invitation
    var brief = ""
    var title = ""
    var text = ""
    var imagePrompt = ""
    var imageName: String?
    var hasVoice = false
    var hasPDF = false
    var voiceID: String?
    var publishedRoomID: UUID?
    var musicID: String?
    var musicTitle: String?
    var musicArtist: String?
    var updated = Date.now
    static func request(_ text: String, botID: UUID) -> Self? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = clean.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(?:lav(?:e)?|skab(?:e)?) (?:mig )?(?:en |et )?(invitation|plakat|kreativt forløb)\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var value = Self(botID: botID); value.brief = String(clean.prefix(2_000))
        value.kind = clean[range].localizedCaseInsensitiveContains("plakat") ? .poster : .invitation
        return value
    }
    static func draft(_ answer: String) throws -> Draft {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let bytes = cleaned.data(using: .utf8), bytes.count < 40_000 else { throw Failure.invalid }
        let draft = try JSONDecoder().decode(Draft.self, from: bytes)
        guard !draft.title.isEmpty, draft.title.count <= 160, !draft.text.isEmpty,
              draft.text.count <= 8_000, !draft.imagePrompt.isEmpty, draft.imagePrompt.count <= 1_000 else { throw Failure.invalid }
        return draft
    }
    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Forslaget kunne ikke bruges. Du kan skrive eller rette teksten selv og fortsætte." }
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/CreativeProjects", isDirectory: true)
        func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
        func asset(_ id: UUID, name: String) -> URL? {
            guard ["narration.wav", "project.pdf"].contains(name) else { return nil }
            return folder(id).appendingPathComponent(name)
        }
        func save(_ value: CreativeProject) throws {
            guard value.title.count <= 160, value.text.count <= 12_000, value.brief.count <= 2_000, value.imagePrompt.count <= 1_000 else { throw Failure.invalid }
            try FileManager.default.createDirectory(at: folder(value.id), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: folder(value.id).appendingPathComponent("project.json"), options: .atomic)
        }
        func list(botID: UUID? = nil) throws -> [CreativeProject] {
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }.prefix(100).compactMap { directory in
                    let file = directory.appendingPathComponent("project.json")
                    guard let data = try? Data(contentsOf: file), data.count < 100_000,
                          let value = try? JSONDecoder().decode(CreativeProject.self, from: data),
                          value.id.uuidString.lowercased() == directory.lastPathComponent,
                          botID == nil || value.botID == botID else { return nil }
                    return value
                }.sorted { $0.updated > $1.updated }
        }
        func remove(_ id: UUID) throws {
            let target = folder(id).standardizedFileURL
            guard target.deletingLastPathComponent().path == root.standardizedFileURL.path else { throw Failure.invalid }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }
}
