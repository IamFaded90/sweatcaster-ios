import Foundation

struct BotComputerStatus: Decodable, Sendable {
    enum State: String, Decodable, Sendable {
        case stopped, running, starting, unavailable

        var title: String {
            switch self {
            case .stopped: "Stoppet"
            case .running: "Kører"
            case .starting: "Starter"
            case .unavailable: "Ikke tilgængelig"
            }
        }
    }

    let status: State
    let message: String?
}

struct BotComputerJob: Decodable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable {
        case queued, running, completed, failed, cancelled

        var title: String {
            switch self {
            case .queued: "Venter"
            case .running: "Kører"
            case .completed: "Færdig"
            case .failed: "Fejlet"
            case .cancelled: "Annulleret"
            }
        }

        var canCancel: Bool { self == .queued || self == .running }
        var canRetry: Bool { self == .failed || self == .cancelled }
    }

    let id: UUID
    let status: State
    let prompt: String
    let result: String?
    let error: String?
    let fileID: UUID?
}

struct BotComputerFile: Decodable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let bytes: Int
}

struct BotComputerFrame: Sendable {
    let png: Data
    let width: Int?
    let height: Int?
}

enum BotComputerRoute: Sendable {
    case status, start, stop, screen, input, jobs, submitJob, cancelJob(UUID)
    case files, uploadFile, file(UUID), share

    var suffix: String {
        switch self {
        case .status: ""
        case .start: "/start"
        case .stop: "/stop"
        case .screen: "/screen"
        case .input: "/input"
        case .jobs, .submitJob: "/jobs"
        case .cancelJob(let id): "/jobs/\(id.uuidString.lowercased())/cancel"
        case .files, .uploadFile: "/files"
        case .file(let id): "/files/\(id.uuidString.lowercased())"
        case .share: "/share"
        }
    }

    var method: String {
        switch self {
        case .status, .screen, .jobs, .files, .file: "GET"
        default: "POST"
        }
    }

    var isScreen: Bool {
        if case .screen = self { true } else { false }
    }

    var timeout: TimeInterval? {
        if case .start = self { 150 } else { nil }
    }
}

struct BotComputerClient: Sendable {
    let api: LiveAPI
    let botID: UUID

    enum Input: Encodable, Sendable {
        case click(x: Int, y: Int)
        case text(String)
        case key(String)
        case scroll(x: Int, y: Int, dx: Int, dy: Int)

        private enum Field: String, CodingKey { case type, x, y, dx, dy, text, key }

        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: Field.self)
            switch self {
            case .click(let x, let y):
                try fields.encode("click", forKey: .type)
                try fields.encode(x, forKey: .x)
                try fields.encode(y, forKey: .y)
            case .text(let text):
                try fields.encode("text", forKey: .type)
                try fields.encode(text, forKey: .text)
            case .key(let key):
                try fields.encode("key", forKey: .type)
                try fields.encode(key, forKey: .key)
            case .scroll(let x, let y, let dx, let dy):
                try fields.encode("scroll", forKey: .type)
                try fields.encode(x, forKey: .x)
                try fields.encode(y, forKey: .y)
                try fields.encode(dx, forKey: .dx)
                try fields.encode(dy, forKey: .dy)
            }
        }
    }

    private struct JobList: Decodable { let jobs: [BotComputerJob] }
    private struct FileList: Decodable { let files: [BotComputerFile] }
    private struct FileContents: Decodable { let content: String }
    private struct Receipt: Decodable { let ok: Bool }
    private struct Draft: Encodable {
        let requestID: String
        let prompt: String
        let fileID: String?
    }
    private struct Import: Encodable { let name: String; let content: String }
    private struct Share: Encodable { let sourceBotID: String; let fileID: String }

    func status() async throws -> BotComputerStatus { try await json(.status) }
    func start() async throws -> BotComputerStatus { try await json(.start) }
    func stop() async throws -> BotComputerStatus { try await json(.stop) }
    func jobs() async throws -> [BotComputerJob] { try await json(.jobs, as: JobList.self).jobs }
    func files() async throws -> [BotComputerFile] { try await json(.files, as: FileList.self).files }
    func file(_ id: UUID) async throws -> String { try await json(.file(id), as: FileContents.self).content }
    func cancel(_ id: UUID) async throws -> BotComputerJob { try await json(.cancelJob(id)) }

    func screenshot() async throws -> BotComputerFrame {
        let (data, response) = try await api.botComputerResponse(botID: botID, route: .screen, body: nil)
        return BotComputerFrame(png: data, width: dimension("x-screen-width", in: response),
                                height: dimension("x-screen-height", in: response))
    }

    func send(_ input: Input) async throws {
        let receipt: Receipt = try await json(.input, body: JSONEncoder().encode(input))
        guard receipt.ok else { throw APIError.malformed }
    }

    func submit(prompt: String, fileID: UUID?, requestID: UUID) async throws -> BotComputerJob {
        let draft = Draft(requestID: requestID.uuidString.lowercased(), prompt: prompt,
                          fileID: fileID?.uuidString.lowercased())
        return try await json(.submitJob, body: JSONEncoder().encode(draft))
    }

    func upload(name: String, content: String) async throws -> BotComputerFile {
        try await json(.uploadFile, body: JSONEncoder().encode(Import(name: name, content: content)))
    }

    func share(fileID: UUID, with recipient: UUID) async throws {
        let transfer = Share(sourceBotID: botID.uuidString.lowercased(), fileID: fileID.uuidString.lowercased())
        let body = try JSONEncoder().encode(transfer)
        let (data, _) = try await api.botComputerResponse(botID: recipient, route: .share, body: body)
        _ = try JSONDecoder().decode(BotComputerFile.self, from: data)
    }

    private func json<Response: Decodable>(_ route: BotComputerRoute, as type: Response.Type = Response.self,
                                           body: Data? = nil) async throws -> Response {
        let (data, _) = try await api.botComputerResponse(botID: botID, route: route, body: body)
        return try JSONDecoder().decode(type, from: data)
    }

    private func dimension(_ header: String, in response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: header), let size = Int(value),
              (1...16_384).contains(size) else { return nil }
        return size
    }
}
