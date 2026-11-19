import Foundation

struct AgentRoom: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, building, ready, published, failed
        var busy: Bool { self == .queued || self == .building }
        var title: String {
            switch self {
            case .queued: "Venter på PC’en"
            case .building: "PC’en tegner rummet"
            case .ready: "Klar til at prøve"
            case .published: "Gemt i landsbyen"
            case .failed: "Rummet blev ikke færdigt"
            }
        }
    }

    struct Figure: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let name, character: String
        let x, y, scale: Double
    }

    struct Hotspot: Codable, Identifiable, Equatable, Sendable {
        enum Action: String, Codable, Sendable { case details, bot }
        let id, title: String
        let x, y, w, h: Double
        let action: Action
        let botID: UUID?
    }

    struct Version: Codable, Identifiable, Equatable, Sendable {
        let revision: Int
        let instruction, artwork: String
        let width, height: Int
        let figures: [Figure]
        let hotspots: [Hotspot]
        let checks: [String]
        var id: Int { revision }
    }

    let id, botID: UUID
    let title, brief: String
    let state: State
    let created: Double
    let revision: Int
    let publishedRevision: Int?
    let versions: [Version]
    let notice: String?

    var current: Version? { versions.first { $0.revision == revision } ?? versions.last }
    var published: Version? { versions.first { $0.revision == publishedRevision } }

    func validated() throws -> AgentRoom {
        guard !title.isEmpty, title.count <= 160, brief.count <= 12_000, created.isFinite, created >= 0,
              revision >= 0, versions.count <= 24, (notice?.count ?? 0) <= 4_000,
              Set(versions.map(\.revision)).count == versions.count else { throw AgentRoomFailure.invalidData }
        for version in versions { try version.validate() }
        if (state == .ready || state == .published), versions.isEmpty { throw AgentRoomFailure.invalidData }
        if !versions.isEmpty, !versions.contains(where: { $0.revision == revision }) {
            throw AgentRoomFailure.invalidData
        }
        if let publishedRevision, !versions.contains(where: { $0.revision == publishedRevision }) {
            throw AgentRoomFailure.invalidData
        }
        return self
    }

    static func validArtwork(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension AgentRoom.Version {
    func validate() throws {
        guard revision > 0, instruction.count <= 8_000, AgentRoom.validArtwork(artwork),
              (64...4_096).contains(width), (64...4_096).contains(height), width * height <= 16_777_216,
              figures.count <= 8, hotspots.count <= 32, checks.count <= 32,
              checks.allSatisfy({ $0.count <= 1_000 }),
              Set(figures.map(\.id)).count == figures.count,
              Set(hotspots.map(\.id)).count == hotspots.count else { throw AgentRoomFailure.invalidData }
        let characters = Set(["adam", "atlas", "milo", "noah", "theo", "eva", "luna", "iris", "nova", "saga", "lumi"])
        for figure in figures {
            guard !figure.name.isEmpty, figure.name.count <= 100, characters.contains(figure.character),
                  figure.x.isFinite, figure.y.isFinite, figure.scale.isFinite,
                  (0.095...0.905).contains(figure.x), (0.7...1.65).contains(figure.scale),
                  (0.09 * figure.scale...1 - 0.09 * figure.scale).contains(figure.y) else {
                throw AgentRoomFailure.invalidData
            }
        }
        for hotspot in hotspots {
            guard !hotspot.id.isEmpty, hotspot.id.count <= 80, !hotspot.title.isEmpty, hotspot.title.count <= 160,
                  [hotspot.x, hotspot.y, hotspot.w, hotspot.h].allSatisfy(\.isFinite),
                  (0...1).contains(hotspot.x), (0...1).contains(hotspot.y),
                  (0.01...1).contains(hotspot.w), (0.01...1).contains(hotspot.h),
                  hotspot.x >= hotspot.w / 2, hotspot.x <= 1 - hotspot.w / 2,
                  hotspot.y >= hotspot.h / 2, hotspot.y <= 1 - hotspot.h / 2 else {
                throw AgentRoomFailure.invalidData
            }
        }
    }
}

enum AgentRoomFailure: LocalizedError {
    case invalidData, unavailable, image, input
    var errorDescription: String? {
        switch self {
        case .invalidData: "PC’en gav rumdata, som appen ikke kunne bruge."
        case .unavailable: "Forbind til PC’en for at bygge eller ændre rummet."
        case .image: "Vælg en almindelig PNG- eller JPEG-skitse på højst 12 MB. Undgå meget smalle billeder."
        case .input: "Vælg en skitse og mindst én figur, og beskriv rummet."
        }
    }
}

enum AgentRoomIntent {
    static func matches(_ text: String) -> Bool {
        let value = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
        let words = value.split { !$0.isLetter }.map(String.init)
        let subject = words.contains { ["rum", "rummet", "rummene", "room", "rooms", "kontor", "kontoret",
                                        "office", "skitse", "skitsen", "sketch"].contains($0) }
        let creation = words.contains { word in
            ["byg", "lav", "tegn", "indret", "build", "create", "design", "sketch", "skitse"].contains {
                word.hasPrefix($0)
            }
        }
        return subject && creation
    }
}

enum AgentRoomRevisionIntent {
    struct Adjustment: Equatable {
        let figureID: UUID
        let name: String
        let scale: Double
        var summary: String { "\(name) bliver \(Int((scale * 100).rounded())) % størrelse. Lys og de andre figurer bevares." }
    }

    enum Resolution: Equatable {
        case empty, adjustment(Adjustment), unsupported(String)
    }

    static func resolve(_ instruction: String, figures: [AgentRoom.Figure]) -> Resolution {
        let text = normalize(instruction).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !text.isEmpty else { return .empty }
        guard text.count <= 250 else { return .unsupported("Forkort justeringen til højst 250 tegn, eller brug slideren.") }
        let fallback = "Vælg en figur, og brug slideren til størrelsen. Teksten kan her forstå “gør Adam større” eller “gør Eva mindre”."
        let parts = text.components(separatedBy: " og ")
        let preservation = Set(["behold lyset", "bevar lyset", "behold belysningen", "bevar belysningen",
                                "behold baggrunden", "bevar baggrunden", "behold resten", "bevar resten"])
        guard parts.dropFirst().allSatisfy({ preservation.contains($0) }),
              let expression = try? NSRegularExpression(pattern: #"^(?:kan du |vil du )?(?:gor|lav) (?:figuren )?(.+?) (?:lidt )?(storre|mindre)$"#),
              let match = expression.firstMatch(in: parts[0], range: NSRange(parts[0].startIndex..., in: parts[0])),
              let nameRange = Range(match.range(at: 1), in: parts[0]),
              let directionRange = Range(match.range(at: 2), in: parts[0]) else { return .unsupported(fallback) }
        let name = String(parts[0][nameRange])
        let matching = figures.filter { normalize($0.name) == name }
        guard matching.count == 1, let figure = matching.first else {
            return .unsupported("Navnet skal matche én figur i rummet. Vælg ellers figuren og brug slideren.")
        }
        let larger = parts[0][directionRange] == "storre"
        let proposed = figure.scale * (larger ? 1.15 : 0.85)
        let scale = min(1.65, max(0.7, (proposed * 100).rounded() / 100))
        guard abs(scale - figure.scale) >= 0.001 else {
            return .unsupported("\(figure.name) har allerede nået størrelsesgrænsen. Brug slideren til en anden størrelse.")
        }
        return .adjustment(Adjustment(figureID: figure.id, name: figure.name, scale: scale))
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "da_DK"))
            .replacingOccurrences(of: "ø", with: "o").replacingOccurrences(of: "æ", with: "ae")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
