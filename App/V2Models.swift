// V2 wire models and incremental event parsing.
import Foundation

struct V2Models: Decodable, Sendable {
    let default_model_id: String
    let models: [Entry]
    struct Entry: Decodable, Identifiable, Sendable {
        let id, label: String
        let available, loaded: Bool
        let capabilities: [String]
        let size_bytes: Int64?

        private enum CodingKeys: String, CodingKey {
            case id, label, available, loaded, capabilities, size_bytes
        }

        init(id: String, label: String, available: Bool, loaded: Bool, capabilities: [String], size_bytes: Int64? = nil) {
            self.id = id
            self.label = label
            self.available = available
            self.loaded = loaded
            self.capabilities = capabilities
            self.size_bytes = size_bytes
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            label = try fields.decode(String.self, forKey: .label)
            available = try fields.decode(Bool.self, forKey: .available)
            loaded = try fields.decode(Bool.self, forKey: .loaded)
            capabilities = try fields.decode([String].self, forKey: .capabilities)
            size_bytes = try? fields.decode(Int64.self, forKey: .size_bytes)
        }

        // Older PC catalogs use "chat" for the route even when it requires an image.
        var requiresImageForChat: Bool { capabilities.contains("vision") && !capabilities.contains("text") }
        var supportsImageChat: Bool { available && capabilities.contains("vision") }
    }

    static let preview = Self(default_model_id: "qwen25-7b", models: [
        .init(id: "qwen25-7b", label: "Qwen 2.5 7B", available: true, loaded: true, capabilities: ["chat", "video"]),
        .init(id: "llama31-8b", label: "Llama 3.1 8B", available: true, loaded: false, capabilities: ["chat", "video"])
    ])
}

struct V2ChatRequest: Encodable, Sendable {
    struct Image: Encodable, Sendable {
        let media_type = "image/jpeg"
        let data_base64: Data

        init(jpegData: Data) throws {
            guard jpegData.count <= 4_000_000, jpegData.starts(with: [0xFF, 0xD8, 0xFF]) else {
                throw V2Failure.invalidInput
            }
            data_base64 = jpegData
        }
    }

    let message: String
    let session_id: String?
    let model_id: String?
    let request_id: UUID
    let image: Image?
    let system_prompt: String?

    init(message: String, sessionID: String? = nil, modelID: String? = nil, requestID: UUID = UUID(), image: Image? = nil) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(trimmed.unicodeScalars.count),
              sessionID.map({ $0.utf8.count <= 64 && $0.utf8.allSatisfy {
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
              } }) ?? true else { throw V2Failure.invalidInput }
        self.message = trimmed
        session_id = sessionID
        model_id = modelID
        request_id = requestID
        self.image = image
        if modelID == "dolphin3-8b", image == nil {
            system_prompt = "Ved kreativ dialog og rollespil mellem voksne, svar som figuren på naturligt dansk. Brug gerne lune, fræk humor og drilsk flirt, når brugeren lægger op til det. Fortsæt scenen med en konkret replik. Svar almindeligt på faktuelle spørgsmål, og hold dig til den tone, brugeren beder om."
        } else {
            system_prompt = nil
        }
    }
}

enum V2Failure: Error, Equatable {
    case invalidInput, invalidResponse, interrupted
    case http(status: Int, code: String?, message: String?)
}

struct V2ChatEvent: Decodable, Sendable, Equatable {
    enum Kind: String, Decodable, Sendable { case tool_status, text, done }
    let type: Kind
    let content: String
    let message_id: String?
    let model_id: String?
    let usage: Usage?

    struct Usage: Decodable, Sendable, Equatable {
        let input_tokens, output_tokens, elapsed_ms: Int
    }
}

struct V2SSEFrames {
    private var line = Data()
    private var fields: [Data] = []
    private var eventBytes = 0
    private var afterCR = false

    mutating func feed(_ byte: UInt8) throws -> Data? {
        let skip = afterCR && byte == 10
        afterCR = byte == 13
        if skip { return nil }
        guard byte == 10 || byte == 13 else {
            guard line.count < 262_144 else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
            line.append(byte)
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !fields.isEmpty else { return nil }
            defer { fields.removeAll(keepingCapacity: true); eventBytes = 0 }
            var event = Data()
            for (index, field) in fields.enumerated() {
                if index > 0 { event.append(10) }
                event.append(field)
            }
            return event
        }
        if line.starts(with: "data:".utf8) {
            var field = line.dropFirst(5)
            if field.first == 32 { field = field.dropFirst() }
            eventBytes += field.count + 1
            guard eventBytes <= 262_144 else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
            fields.append(Data(field))
        }
        return nil
    }
}

struct V2ChatParser {
    private var frames = V2SSEFrames()
    private(set) var finished = false

    mutating func feed(_ byte: UInt8) throws -> V2ChatEvent? {
        guard let payload = try frames.feed(byte) else { return nil }
        guard !finished else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        let event = try JSONDecoder().decode(V2ChatEvent.self, from: payload)
        if event.type == .done {
            guard event.message_id?.isEmpty == false, event.model_id?.isEmpty == false else {
                throw AppDiagnostics.record(V2Failure.invalidResponse)
            }
            finished = true
        }
        return event
    }

    func end() throws {
        guard finished else { throw V2Failure.interrupted }
    }
}

struct V2Hub: Decodable, Sendable {
    let revision: Int
    let rooms: [Room]
    let agents: [Agent]
    let summary: Summary

    struct Room: Decodable, Identifiable, Sendable {
        let id, name, icon: String
    }
    struct Agent: Decodable, Identifiable, Sendable {
        enum Status: String, Decodable, Sendable { case working, thinking, ready, offline }
        let id, room_id, name, icon: String
        let status: Status
        let xp, level, xp_in_level, xp_for_next_level: Int
        let recent_quests: [Quest]
    }
    struct Quest: Decodable, Identifiable, Sendable {
        enum State: String, Decodable, Sendable { case queued, running, completed, failed }
        let id, title: String
        let state: State
        let updated_at: Date
    }
    struct Summary: Decodable, Sendable {
        let active_agents, active_jobs, total_xp, streak_days: Int
    }
}

struct V2Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next_cursor: String?
}
struct V2History: Decodable, Identifiable, Sendable {
    let id, kind, title, state: String
    let at: Date
    let tool_name, summary: String?
}
struct V2Memory: Decodable, Identifiable, Sendable {
    let id, title, summary: String
    let updated_at: Date
}
struct V2Achievements: Decodable, Sendable {
    let items: [Item]
    struct Item: Decodable, Identifiable, Sendable {
        let id, title, description, icon: String
        let current, target: Int
        let earned_at: Date?
    }
}
struct V2HubEvent: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case hub_updated, resync_required }
    let type: Kind
    let revision: Int?
}

struct V2CodeWorkspace: Decodable, Sendable {
    let files: [File]
    let max_files: Int
    struct File: Decodable, Identifiable, Sendable {
        let path: String
        let size: Int
        let updated_at: String
        var id: String { path }
    }
}

struct V2CodeFile: Decodable, Sendable {
    let path, content: String
}

struct V2CodeProposal: Decodable, Sendable {
    let change_id, path, diff: String
    let requires_approval: Bool
}

struct V2CodeApplied: Decodable, Sendable {
    let change_id, path: String
    let applied: Bool
}

struct V2ClipRoots: Decodable, Sendable {
    let roots: [Root]
    struct Root: Decodable, Identifiable, Sendable {
        let id, label: String
        let file_count: Int
        let ready, indexing: Bool
    }
}

struct V2ClipPage: Decodable, Sendable {
    let root_id, label: String
    let clips: [Clip]
    let next_cursor: String?
    let ready, indexing: Bool
}
