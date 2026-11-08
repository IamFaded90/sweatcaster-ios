import Foundation
import Security
import CryptoKit

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

struct Server: Sendable {
    let address: String
    let origin: URL
    let profile: ConnectionProfile
    init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address: String
        if input.contains("://") {
            guard let url = URLComponents(string: input), url.scheme == "http",
                  let host = url.host, url.port == 8765,
                  ["/api/v1", "/api/v1/"].contains(url.percentEncodedPath),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
            else { throw APIError.address }
            address = host
        } else { address = input }
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        let n = parts.compactMap { UInt8($0) }
        guard parts.count == 4, n.count == 4, n.map({ String($0) }).joined(separator: ".") == address,
              n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) ||
              (n[0] == 192 && n[1] == 168) || (n[0] == 100 && (64...127).contains(n[1])),
              let origin = URL(string: "http://\(address):8765") else { throw APIError.address }
        self.address = address
        self.origin = origin
        self.profile = n[0] == 100 ? .tailscale : .home
    }
    func endpoint(_ path: String) -> URL {
        URL(string: origin.absoluteString + "/api/v1/" + path)!
    }
    static func segment(_ id: String) throws -> String {
        guard validWireID(id) else { throw APIError.input }
        return id
    }
    func videoURL(_ job: Job) throws -> URL {
        guard job.status == .completed, validWireID(job.id),
              job.output_url == "/api/v1/jobs/\(job.id)/video" else { throw APIError.unsafeVideo }
        return endpoint("jobs/\(job.id)/video")
    }
}

enum ConnectionProfile: String, CaseIterable, Identifiable, Sendable {
    case home, tailscale
    var id: Self { self }
    var storageKey: String { "server.profile." + rawValue }
    var title: String { self == .home ? "Hjem (Lokal IP)" : "Ekstern (Tailscale IP)" }
    var route: String { self == .home ? "Lokal" : "Tailscale" }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
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

struct CodeBatchList: Decodable {
    struct Job: Decodable, Identifiable {
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

struct LiveAPI: SweatAPI, ChatAPI {
    private func moduleJSON<T: Decodable>(_ path: String, upload: Data? = nil, timeout: TimeInterval? = nil) async throws -> T {
        var endpoint = try v2Request("modules")
        guard let url = endpoint.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw V2Failure.invalidInput
        }
        components.path = "/api/modules/v1/" + path
        guard let target = components.url else { throw V2Failure.invalidInput }
        endpoint = request(target, method: upload == nil ? "GET" : "PUT")
        if let timeout { endpoint.timeoutInterval = timeout }
        if let upload {
            endpoint.httpBody = upload
            endpoint.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await loggedData(for: endpoint)
        try checked(response, expected: 200, data: data)
        guard data.count <= 2_000_000 else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        return try loggedDecode(T.self, from: data, decoder: JSONDecoder())
    }

    func moduleManifest() async throws -> ModuleManifest { try await moduleJSON("manifest") }
    func moduleCards(_ id: String, upload: Data? = nil) async throws -> ModuleCards {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)", upload: upload)
    }
    func moduleInformation(_ id: String) async throws -> ModuleInformation {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)")
    }

    func codeBatches() async throws -> CodeBatchList { try await moduleJSON("code-batches") }

    func cloneCodeRepository(_ repo: String) async throws {
        struct Receipt: Decodable { let repo, revision: String }
        let data = try JSONEncoder().encode(["repo": repo])
        let _: Receipt = try await moduleJSON("code-repositories", upload: data, timeout: 190)
    }

    func enqueueCodeBatch(repo: String, goal: String, files: [String]) async throws {
        struct Input: Encodable { let repo, goal: String; let files: [String] }
        struct Receipt: Decodable { let id: String }
        let receipt: Receipt = try await moduleJSON("code-batches", upload: JSONEncoder().encode(Input(repo: repo, goal: goal, files: files)))
        await JobNotifications.shared.trackCodeJob(server: server.address, id: receipt.id)
    }

    func codeBatch(_ id: String) async throws -> CodeBatchDetail {
        try await moduleJSON("code-batches/\(Server.segment(id))")
    }

    func approveCodeBatch(_ id: String) async throws -> CodeBatchDetail.Proposal {
        try await moduleJSON("code-batches/\(Server.segment(id))/approval", upload: JSONEncoder().encode(["approved": true]))
    }
    let server: Server
    let queueTargetID: String
    private let token: String
    private let session: URLSession
    init(server: Server, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw APIError.token }
        self.server = server
        self.token = token
        let target = Data("\(server.origin.absoluteString)\n\(token)".utf8)
        queueTargetID = SHA256.hash(data: target).map { String(format: "%02x", $0) }.joined()
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess = server.profile == .tailscale
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    private func request(_ url: URL, method: String = "GET", auth: Bool = true) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        if auth { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func mapped(_ error: URLError, posting: Bool) -> APIError {
        if posting { return .transport(error.errorCode) }
        // URLSession does not reliably distinguish LAN denial from an unreachable PC.
        if error.code == .appTransportSecurityRequiresSecureConnection { return .transport(error.errorCode) }
        if [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut].contains(error.code) {
            return .offline
        }
        return .transport(error.errorCode)
    }
    private func checked(_ response: URLResponse, expected: Int, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(APIError.malformed) }
        guard http.statusCode == expected else {
            let decoded = data.flatMap { try? contractDecoder().decode(Envelope.self, from: $0).error }
            let safe = decoded.map {
                Problem(code: redact($0.code), message: redact($0.message))
            }
            throw AppDiagnostics.record(APIError.http(http.statusCode, safe))
        }
    }

    private func loggedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch { throw AppDiagnostics.record(error) }
    }

    private func loggedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: request) }
        catch { throw AppDiagnostics.record(error) }
    }

    private func loggedDecode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder = contractDecoder()) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw AppDiagnostics.record(error) }
    }

    private func checkRenderBeforeChat() async throws {
        let current = try await jobs()
        guard !current.jobs.contains(where: { $0.status == .rendering }) else {
            throw AppDiagnostics.record(APIError.http(503, nil))
        }
    }
    private func redact(_ text: String) -> String {
        text.replacingOccurrences(of: token, with: "[skjult]")
    }
    func redactChat(_ text: String, complete: Bool) -> String {
        var safe = redact(text)
        if complete { return safe }
        let limit = min(safe.count, token.count - 1)
        if limit > 0, let length = (1...limit).reversed().first(where: {
            safe.hasSuffix(String(token.prefix($0)))
        }) {
            safe.removeLast(length)
        }
        return safe
    }
    private func json<T: Decodable>(_ path: String, status: Int = 200, post: Bool = false,
                                     body: Batch? = nil, auth: Bool = true, timeout: TimeInterval? = nil) async throws -> T {
        var req = request(server.endpoint(path), method: post ? "POST" : "GET", auth: auth)
        if let timeout { req.timeoutInterval = timeout }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await loggedData(for: req)
            try checked(response, expected: status, data: data)
            do { return try loggedDecode(T.self, from: data) }
            catch { throw APIError.malformed }
        } catch let error as URLError {
            if error.code == .cancelled && !post { throw CancellationError() }
            throw mapped(error, posting: post)
        }
    }
    func health() async throws -> Health { try await json("health", auth: false, timeout: 3) }
    func capabilities() async throws -> Capabilities { try await json("capabilities") }
    func clips() async throws -> Clips { try await json("clips") }
    func jobs() async throws -> Jobs { try await json("jobs") }
    func job(_ id: String) async throws -> Job { try await json("jobs/\(Server.segment(id))") }
    func submit(_ batch: Batch) async throws -> Jobs {
        try batch.validate(limit: 10)
        return try await json("jobs", status: 202, post: true, body: batch)
    }
    func cancel(_ id: String) async throws -> Job {
        try await json("jobs/\(Server.segment(id))/cancel", post: true)
    }
    func deleteFailedJob(_ id: String) async throws {
        let segment = try Server.segment(id)
        var req = request(server.endpoint("jobs/\(segment)"), method: "DELETE")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["confirm_job_id": id])
        let (data, response) = try await loggedData(for: req)
        try checked(response, expected: 200, data: data)
    }
    func chat(_ input: ChatRequest, receive: @Sendable (ChatEvent) async -> Void) async throws {
        try await checkRenderBeforeChat()
        var req = request(server.endpoint("chat"), method: "POST")
        req.httpBody = try JSONEncoder().encode(input)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var receivedResponse = false
        do {
            let (bytes, response) = try await loggedBytes(for: req)
            defer { bytes.task.cancel() }
            receivedResponse = true
            guard let http = response as? HTTPURLResponse else { throw ChatFailure.rejected }
            if http.statusCode == 503 { throw AppDiagnostics.record(APIError.http(503, nil)) }
            try ChatFailure.validate(status: http.statusCode, mime: http.mimeType)
            var parser = ChatSSEParser()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.feed(byte) {
                    await receive(event)
                    try Task.checkCancellation()
                    if parser.finished { return }
                }
            }
            try parser.end()
        } catch let failure as URLError {
            if Task.isCancelled || failure.code == .cancelled { throw CancellationError() }
            if !receivedResponse, [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(failure.code) {
                throw ChatFailure.unreachable
            }
            throw ChatFailure.interrupted
        }
    }
    func video(_ job: Job) async throws -> URL {
        let url = try server.videoURL(job)
        do {
            let (temporary, response) = try await session.download(for: request(url))
            defer { try? FileManager.default.removeItem(at: temporary) }
            let envelope: Data?
            if (response as? HTTPURLResponse)?.statusCode != 200,
               let file = try? FileHandle(forReadingFrom: temporary) {
                defer { try? file.close() }
                envelope = try? file.read(upToCount: 65536)
            } else { envelope = nil }
            try checked(response, expected: 200, data: envelope)
            guard response.mimeType == "video/mp4",
                  let file = try? FileHandle(forReadingFrom: temporary) else {
                throw APIError.unsafeVideo
            }
            defer { try? file.close() }
            let header = try file.read(upToCount: 8)
            guard header?.dropFirst(4).elementsEqual("ftyp".utf8) == true else { throw APIError.unsafeVideo }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("Sweat-\(UUID()).mp4")
            do { try FileManager.default.moveItem(at: temporary, to: target) }
            catch { throw APIError.storage }
            return target
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw mapped(error, posting: false)
        }
    }
}


struct V2Models: Decodable, Sendable {
    let default_model_id: String
    let models: [Entry]
    struct Entry: Decodable, Identifiable, Sendable {
        let id, label: String
        let available, loaded: Bool
        let capabilities: [String]
    }

    static let preview = Self(default_model_id: "qwen25-7b", models: [
        .init(id: "qwen25-7b", label: "Qwen 2.5 7B", available: true, loaded: true, capabilities: ["chat", "video"]),
        .init(id: "llama31-8b", label: "Llama 3.1 8B", available: true, loaded: false, capabilities: ["chat", "video"])
    ])
}

struct V2ChatRequest: Encodable, Sendable {
    let message: String
    let session_id: String?
    let model_id: String?
    let request_id: UUID

    init(message: String, sessionID: String? = nil, modelID: String? = nil, requestID: UUID = UUID()) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(trimmed.unicodeScalars.count),
              sessionID.map({ $0.utf8.count <= 64 && $0.utf8.allSatisfy {
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
              } }) ?? true else { throw V2Failure.invalidInput }
        self.message = trimmed
        session_id = sessionID
        model_id = modelID
        request_id = requestID
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

extension LiveAPI {
    func v2ClipRoots() async throws -> V2ClipRoots { try await v2JSON("clip-roots") }

    func v2ClipPage(rootID: String, cursor: String? = nil, limit: Int = 100) async throws -> V2ClipPage {
        guard Int(rootID) != nil, (1...100).contains(limit) else { throw V2Failure.invalidInput }
        var query = [URLQueryItem(name: "root_id", value: rootID),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await v2JSON("clips", query: query)
    }
    func v2GenerateImage(prompt: String) async throws -> Data {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1000).contains(message.count) else { throw V2Failure.invalidInput }
        var req = try v2Request("images/generate", method: "POST")
        req.timeoutInterval = 240
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("image/png", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(["prompt": message])
        let (data, response) = try await loggedData(for: req)
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        guard http.statusCode == 200 else { throw v2HTTPError(http.statusCode, data: data) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/png") == true,
              data.count <= 15_000_000, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        return data
    }

    func deletePCVideo(_ id: String) async throws {
        guard validWireID(id) else { throw V2Failure.invalidInput }
        var request = try v2Request("jobs/\(id)/video", method: "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["confirm_job_id": id])
        let (data, response) = try await loggedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        guard http.statusCode == 200 else { throw v2HTTPError(http.statusCode, data: data) }
    }

    func v2Models() async throws -> V2Models { try await v2JSON("models") }
    func v2Hub() async throws -> V2Hub { try await v2JSON("agent-hub") }
    func v2Achievements() async throws -> V2Achievements { try await v2JSON("achievements") }
    func v2CodeWorkspace() async throws -> V2CodeWorkspace { try await v2JSON("code/workspace") }

    func v2CodeFile(path: String) async throws -> V2CodeFile {
        try await v2JSON("code/file", query: [URLQueryItem(name: "path", value: path)])
    }

    func v2CodeProposal(path: String, content: String) async throws -> V2CodeProposal {
        var request = try v2Request("code/proposals", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path, "content": content])
        let (data, response) = try await loggedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        guard http.statusCode == 200 else { throw v2HTTPError(http.statusCode, data: data) }
        return try loggedDecode(V2CodeProposal.self, from: data)
    }

    func v2ApplyCodeProposal(_ id: String, approved: Bool) async throws -> V2CodeApplied {
        guard UUID(uuidString: id) != nil else { throw V2Failure.invalidInput }
        var request = try v2Request("code/proposals/\(id)/apply", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["approved": approved])
        let (data, response) = try await loggedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        guard http.statusCode == 200 else { throw v2HTTPError(http.statusCode, data: data) }
        return try loggedDecode(V2CodeApplied.self, from: data)
    }

    func v2History(agentID: String, cursor: String? = nil) async throws -> V2Page<V2History> {
        try await v2JSON("agents/\(v2AgentSegment(agentID))/history", query: v2PageQuery(cursor))
    }
    func v2Memory(agentID: String, cursor: String? = nil) async throws -> V2Page<V2Memory> {
        try await v2JSON("agents/\(v2AgentSegment(agentID))/memory", query: v2PageQuery(cursor))
    }

    private func v2AgentSegment(_ id: String) throws -> String {
        guard !id.isEmpty, id != ".", id != "..",
              let segment = id.addingPercentEncoding(withAllowedCharacters:
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"))
        else { throw V2Failure.invalidInput }
        return segment
    }

    private func v2PageQuery(_ cursor: String?) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: "50")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    private func v2Request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: server.origin, resolvingAgainstBaseURL: false) else {
            throw V2Failure.invalidInput
        }
        components.percentEncodedPath = "/api/v2/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw V2Failure.invalidInput }
        return request(url, method: method)
    }

    private func v2JSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await loggedData(for: v2Request(path, query: query))
        guard let http = response as? HTTPURLResponse else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        guard http.statusCode == 200 else { throw v2HTTPError(http.statusCode, data: data) }
        return try loggedDecode(T.self, from: data)
    }

    private func v2HTTPError(_ status: Int, data: Data) -> V2Failure {
        let problem = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        return AppDiagnostics.record(V2Failure.http(status: status, code: problem.map { redact($0.code) },
                                                    message: problem.map { redact($0.message) }))
    }

    private func v2Stream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var req = request
        req.timeoutInterval = 120
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await loggedBytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw AppDiagnostics.record(V2Failure.invalidResponse)
        }
        guard http.statusCode == 200 else {
            defer { bytes.task.cancel() }
            var data = Data()
            if http.mimeType == "application/json" {
                for try await byte in bytes {
                    guard data.count < 65_536 else { break }
                    data.append(byte)
                }
            }
            throw v2HTTPError(http.statusCode, data: data)
        }
        guard http.mimeType == "text/event-stream" else {
            bytes.task.cancel()
            throw AppDiagnostics.record(V2Failure.invalidResponse)
        }
        return bytes
    }

    func v2Chat(_ input: V2ChatRequest, receive: @Sendable (V2ChatEvent) async -> Void) async throws {
        try await checkRenderBeforeChat()
        var req = try v2Request("chat", method: "POST")
        req.httpBody = try JSONEncoder().encode(input)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bytes = try await v2Stream(req)
        defer { bytes.task.cancel() }
        var parser = V2ChatParser()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.feed(byte) {
                    await receive(event)
                    try Task.checkCancellation()
                    if parser.finished { return }
                }
            }
        } catch is URLError {
            try Task.checkCancellation()
            throw AppDiagnostics.record(V2Failure.interrupted)
        }
        do { try parser.end() }
        catch { throw AppDiagnostics.record(error) }
    }

    func v2HubEvents(after revision: Int, receive: @Sendable (V2HubEvent) async -> Void) async throws {
        let request = try v2Request("agent-hub/events", query: [
            URLQueryItem(name: "after_revision", value: String(revision))
        ])
        let bytes = try await v2Stream(request)
        defer { bytes.task.cancel() }
        var frames = V2SSEFrames()
        var latest = revision
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let payload = try frames.feed(byte) else { continue }
            let event = try JSONDecoder().decode(V2HubEvent.self, from: payload)
            if event.type == .resync_required {
                await receive(event)
                return
            }
            guard let next = event.revision else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
            if next > latest {
                latest = next
                await receive(event)
            }
        }
    }
}

enum Pairing {
    static let addressKey = "server.address"
    private static func query(_ address: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AI Sweat-Caster pairing v1", kSecAttrAccount as String: address]
    }
    static func load(_ address: String) throws -> String {
        var query = query(address)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8) else { throw APIError.token }
        return token
    }
    static func save(_ token: String, for address: String) throws {
        let q = query(address)
        let data = Data(token.utf8)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw APIError.storage }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }

    static func removeAll() throws {
        var filter = query("")
        filter.removeValue(forKey: kSecAttrAccount as String)
        let result = SecItemDelete(filter as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw APIError.storage }
    }
}

enum CloudModelKey {
    static let didChange = Notification.Name("FadedAI.cloudModelKeyDidChange")

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "FadedAI optional cloud models",
         kSecAttrAccount as String: "xai"]
    }

    static func exists() -> Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(key) else { throw APIError.input }
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecSuccess {
            guard updated == errSecItemNotFound else { throw APIError.storage }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func load() throws -> String {
        var item: CFTypeRef?
        var filter = query
        filter[kSecReturnData as String] = true
        guard SecItemCopyMatching(filter as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), isValid(key) else {
            throw GrokFailure.missingKey
        }
        return key
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func isValid(_ key: String) -> Bool {
        (1...512).contains(key.utf8.count) && key.utf8.allSatisfy { (33...126).contains($0) }
    }
}

enum GrokFailure: Error, Equatable {
    case missingKey, interrupted, invalidResponse, unavailable, http(Int)

    var message: String {
        switch self {
        case .missingKey: "Gem en gyldig xAI-nøgle i AI- eller chatindstillingerne."
        case .http(401), .http(403): "xAI afviste nøglen eller adgangen til Grok. Tjek din xAI-konto."
        case .http(402): "Tjek din saldo eller fakturering hos xAI."
        case .http(404): "Grok-modellen er ikke tilgængelig for din xAI-konto."
        case .http(429): "xAI har nået en brugsgrænse. Prøv igen om lidt."
        case .http, .unavailable: "Kunne ikke få svar fra Grok. Tjek internetforbindelsen, og prøv igen."
        case .interrupted: "Grok-svaret blev afbrudt."
        case .invalidResponse: "Grok sendte et svar, som appen ikke kunne læse."
        }
    }
}

struct GrokResponsesParser {
    private struct Event: Decodable { let type: String }
    private struct TextDelta: Decodable { let delta: String }

    private var frames = V2SSEFrames()
    private(set) var finished = false

    mutating func feed(_ byte: UInt8) throws -> String? {
        guard !finished else { return nil }
        guard let payload = try frames.feed(byte) else { return nil }
        guard let event = try? JSONDecoder().decode(Event.self, from: payload) else { throw GrokFailure.invalidResponse }
        switch event.type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let event = try? JSONDecoder().decode(TextDelta.self, from: payload) else { throw GrokFailure.invalidResponse }
            return event.delta
        case "response.completed":
            finished = true
        case "response.failed", "response.incomplete", "response.cancelled", "error":
            throw GrokFailure.interrupted
        default: break
        }
        return nil
    }

    func end() throws {
        guard finished else { throw GrokFailure.interrupted }
    }
}

enum GrokAPI {
    static let sourceLabel = "Grok · Cloud"

    struct Message: Encodable, Sendable {
        enum Role: String, Encodable, Sendable { case user, assistant }
        let role: Role
        let content: String
    }

    private struct RequestBody: Encodable {
        struct Reasoning: Encodable { let effort = "low" }
        let model = "grok-4.7"
        let input: [Message]
        let stream = true
        let store = false
        let max_output_tokens = 2_048
        let reasoning = Reasoning()
    }

    static func request(input: [Message], key: String) throws -> URLRequest {
        guard CloudModelKey.isValid(key) else { throw GrokFailure.missingKey }
        let sanitized = input.map {
            Message(role: $0.role, content: $0.content.replacingOccurrences(of: key, with: "[skjult]"))
        }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/responses")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RequestBody(input: sanitized))
        return request
    }

    static func reply(input: [Message], receive: @Sendable (String) async -> Void) async throws {
        let key = try CloudModelKey.load()
        let request = try Self.request(input: input, key: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var parser = GrokResponsesParser()
        var output = ""
        var outputBytes = 0
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw GrokFailure.invalidResponse }
            guard http.statusCode == 200 else { throw GrokFailure.http(http.statusCode) }
            guard http.mimeType == "text/event-stream" else { throw GrokFailure.invalidResponse }
            for try await byte in bytes {
                try Task.checkCancellation()
                if let delta = try parser.feed(byte), !delta.isEmpty {
                    outputBytes += delta.utf8.count
                    guard outputBytes <= 262_144 else { throw GrokFailure.invalidResponse }
                    output += delta
                    await receive(redacted(output, key: key, streaming: true))
                }
                if parser.finished { break }
            }
            try Task.checkCancellation()
            try parser.end()
        } catch is URLError {
            try Task.checkCancellation()
            throw output.isEmpty ? GrokFailure.unavailable : GrokFailure.interrupted
        } catch is V2Failure {
            throw GrokFailure.invalidResponse
        }
        guard !output.isEmpty else { throw GrokFailure.invalidResponse }
        await receive(redacted(output, key: key, streaming: false))
    }

    static func redacted(_ text: String, key: String, streaming: Bool) -> String {
        var safe = text.replacingOccurrences(of: key, with: "[skjult]")
        let limit = min(safe.count, key.count - 1)
        if streaming, limit > 0, let match = (1...limit).reversed().first(where: { safe.hasSuffix(String(key.prefix($0))) }) {
            safe.removeLast(match)
        }
        return safe
    }
}
