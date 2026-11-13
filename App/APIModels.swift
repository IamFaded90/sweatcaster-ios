// V1 chat framing and shared PC API contracts.
import Foundation

struct ChatRequest: Codable, Sendable {
    let message: String
    let session_id: UUID?
}

struct ChatEvent: Decodable, Sendable, Equatable {
    let type: String
    let content: String
}

enum ChatFailure: Error, Equatable {
    case unreachable, unauthorized, originRejected, invalidRequest, unavailable, rejected, interrupted

    static func validate(status: Int, mime: String?) throws {
        switch status {
        case 200 where mime == "text/event-stream": return
        case 401: throw Self.unauthorized
        case 403: throw Self.originRejected
        case 422: throw Self.invalidRequest
        case 404, 501: throw Self.unavailable
        default: throw Self.rejected
        }
    }

    var message: String {
        switch self {
        case .unreachable: "Kan ikke nå PC’en."
        case .unauthorized: "PC’en afviste adgangskoden."
        case .originRejected: "PC’en afviste forbindelsens oprindelse."
        case .invalidRequest: "PC’en afviste beskeden. Tjek teksten, og prøv igen."
        case .unavailable: "Agenttjenesten på PC’en er ikke klar."
        case .rejected: "Chatten kunne ikke læse svaret fra PC’en."
        case .interrupted: "Svaret blev afbrudt. Et job kan allerede være startet."
        }
    }
}

struct ChatSSEParser {
    private var line = Data()
    private var dataLines: [String] = []
    private var eventSize = 0
    private var afterCR = false
    private(set) var finished = false

    mutating func feed(_ byte: UInt8) throws -> ChatEvent? {
        guard !finished else { return nil }
        let skipLF = afterCR && byte == 10
        afterCR = byte == 13
        if skipLF { return nil }
        guard byte == 10 || byte == 13 else {
            guard line.count < 256 * 1024 else { throw ChatFailure.interrupted }
            line.append(byte)
            return nil
        }
        guard let text = String(data: line, encoding: .utf8) else { throw ChatFailure.interrupted }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventSize = 0
            guard let event = try? JSONDecoder().decode(ChatEvent.self, from: Data(payload.utf8))
            else { throw ChatFailure.interrupted }
            finished = event.type == "done"
            return ["tool_status", "text", "done"].contains(event.type) ? event : nil
        }
        if text == "data" || text.hasPrefix("data:") {
            let field = text.dropFirst(5)
            let value = field.first == " " ? field.dropFirst() : field
            eventSize += value.utf8.count + 1
            guard eventSize <= 256 * 1024 else { throw ChatFailure.interrupted }
            dataLines.append(String(value))
        }
        return nil
    }

    func end() throws {
        guard finished else { throw ChatFailure.interrupted }
    }
}

protocol ChatAPI: Sendable {
    func chat(_ input: ChatRequest, receive: @Sendable (ChatEvent) async -> Void) async throws
}

protocol SweatAPI: Sendable {
    func health() async throws -> Health
    func capabilities() async throws -> Capabilities
    func clips() async throws -> Clips
    func jobs() async throws -> Jobs
    func job(_ id: String) async throws -> Job
    func submit(_ batch: Batch) async throws -> Jobs
    func cancel(_ id: String) async throws -> Job
    func video(_ job: Job) async throws -> URL
}

struct ModuleManifest: Decodable {
    let version: Int
    let tabs: [ModuleTab]
}

struct ModuleTab: Decodable, Identifiable {
    let id, title, kind: String

    var supported: Bool {
        Self.validID(id) && !title.isEmpty && title.count <= 32 && ["cards", "information"].contains(kind)
    }

    static func validID(_ id: String) -> Bool {
        (1...48).contains(id.utf8.count) && id.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }
}

struct ModuleCards: Decodable {
    struct Card: Decodable, Identifiable {
        let id, name, number, set, language: String
        let price: Double?
    }
    let cards: [Card]
}

struct ModuleInformation: Decodable {
    let text: String
}

struct VillageBotJobActivity: Decodable, Sendable {
    let id: UUID
    let status: BotComputerJob.State
}

struct VillageBotActivity: Decodable, Sendable {
    struct Bot: Decodable, Sendable {
        let id: UUID
        let jobs: [VillageBotJobActivity]
    }

    let bots: [Bot]
}

struct EmbyLibraryPage: Decodable {
    struct Item: Decodable, Hashable, Identifiable {
        let id, title, kind: String
        let folder: Bool
        let subtitle: String?
        let webURL: URL?

        var browserURL: URL? {
            guard let webURL, let components = URLComponents(url: webURL, resolvingAgainstBaseURL: false),
                  components.scheme == "https", let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { return nil }
            return webURL
        }
    }

    let configured: Bool
    let items: [Item]
    let nextOffset: Int?
}

struct CodeBatchList: Decodable, Sendable {
    struct Job: Decodable, Identifiable, Sendable {
        let id, repo, goal, status: String
    }
    let jobs: [Job]
}

struct CodeBatchDetail: Decodable {
    struct Proposal: Decodable {
        let diff, branch, reason: String?
        let tests, checks: [String]?
    }
    let id, status: String
    let result: Proposal?
}
