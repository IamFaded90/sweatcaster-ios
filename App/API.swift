// Authenticated PC transport and API operations.
import CryptoKit
import Foundation

// Trust model: use only your own password-protected Wi-Fi or Tailscale, never open Wi-Fi.
// Parsing accepts private IPv4 and 100.64.0.0/10 and rejects public IPs, URL credentials,
// queries, and ports in bare addresses. A full LAN URL must use the fixed API port.
// LAN HTTP does not provide TLS. Tokens travel in headers to the paired origin only;
// URLSession declines redirects so they cannot forward the token elsewhere.
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
        guard parts.count == 4, n.count == 4,
              n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) ||
              (n[0] == 192 && n[1] == 168) || (n[0] == 100 && (64...127).contains(n[1])) else { throw APIError.address }
        let canonical = n.map { String($0) }.joined(separator: ".")
        if parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
           parts.contains(where: { $0.count > 1 && $0.first == "0" }) {
            throw APIError.addressLeadingZeros(canonical)
        }
        guard canonical == address, let origin = URL(string: "http://\(address):8765") else { throw APIError.address }
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
    var storageKey: String { AppStorageKeys.serverProfile(rawValue) }
    var title: String { self == .home ? "Hjem (Lokal IP)" : "Ekstern (Tailscale IP)" }
    var route: String { self == .home ? "Lokal" : "Tailscale" }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct LiveAPI: SweatAPI, ChatAPI {
    private func moduleJSON<T: Decodable>(_ path: String, upload: Data? = nil, timeout: TimeInterval? = nil,
                                          query: [URLQueryItem] = []) async throws -> T {
        var endpoint = try v2Request("modules")
        guard let url = endpoint.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw V2Failure.invalidInput
        }
        components.path = "/api/modules/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
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
    func embyLibrary(parent: String?, search: String, offset: Int) async throws -> EmbyLibraryPage {
        var query = [URLQueryItem(name: "offset", value: String(offset))]
        if let parent { query.append(.init(name: "parent", value: parent)) }
        if !search.isEmpty { query.append(.init(name: "search", value: search)) }
        return try await moduleJSON("emby/library", query: query)
    }

    func youtubeChannels() async throws -> YouTubeChannels {
        try await moduleJSON("youtube/channels", timeout: 24)
    }

    func pcWebSearch(query: String) async throws -> PCWebSearch {
        let data = try JSONEncoder().encode(["query": query])
        return try await moduleJSON("web-search", upload: data, timeout: 16)
    }

    func villageBotActivity(ids: [UUID]) async throws -> VillageBotActivity {
        let data = try JSONEncoder().encode(["botIDs": ids.map { $0.uuidString.lowercased() }])
        return try await moduleJSON("bot-activity", upload: data, timeout: 10)
    }

    func moduleCards(_ id: String, upload: Data? = nil) async throws -> ModuleCards {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)", upload: upload)
    }
    func moduleInformation(_ id: String) async throws -> ModuleInformation {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)")
    }

    func codeBatches() async throws -> CodeBatchList { try await moduleJSON("code-batches") }
    func teamRoutines() async throws -> TeamPCRoutines { try await moduleJSON("routines") }
    func saveTeamRoutines(_ routines: [TeamPCRoutine.Configuration]) async throws -> TeamPCRoutines {
        struct Input: Encodable { let routines: [TeamPCRoutine.Configuration] }
        return try await moduleJSON("routines", upload: JSONEncoder().encode(Input(routines: routines)))
    }

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

    func botComputerResponse(botID: UUID, route: BotComputerRoute,
                             body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: server.origin, resolvingAgainstBaseURL: false) else {
            throw APIError.address
        }
        components.path = "/api/modules/v1/bot-computers/\(botID.uuidString.lowercased())" + route.suffix
        guard let url = components.url else { throw APIError.input }
        let mime = route.isScreen ? "image/png" : "application/json"
        var endpoint = request(url, method: route.method)
        endpoint.setValue(mime, forHTTPHeaderField: "Accept")
        if let timeout = route.timeout { endpoint.timeoutInterval = timeout }
        if let body {
            endpoint.httpBody = body
            endpoint.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loggedData(for: endpoint)
        } catch let error as URLError where !Task.isCancelled {
            throw mapped(error, posting: route.method == "POST")
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.malformed }
        let expected = (200...202).contains(http.statusCode) ? http.statusCode : 200
        try checked(http, expected: expected, data: data)
        let limit = route.isScreen ? 8 * 1024 * 1024 : 2_000_000
        guard data.count <= limit, http.mimeType?.lowercased() == mime else { throw APIError.malformed }
        return (data, http)
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
        do {
            do { return try await session.data(for: request) }
            catch let error as URLError where request.httpMethod == "GET" && error.code == .networkConnectionLost {
                try Task.checkCancellation()
                return try await session.data(for: request)
            }
        } catch { throw AppDiagnostics.record(error) }
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
        let current: Jobs
        do {
            current = try await jobs()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            AppDiagnostics.record(error)
            return
        }
        if current.jobs.contains(where: { $0.status == .rendering }) {
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

    func reportedReplyModelID(for event: V2ChatEvent) -> String? {
        guard event.type == .done, let id = ModelRouter.validReportedID(event.model_id), redact(id) == id else { return nil }
        return id
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
            catch { AppDiagnostics.record(error); throw APIError.malformed }
        } catch let error as URLError {
            AppDiagnostics.record(error)
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
    func deleteUnavailableVideoJob(_ id: String) async throws {
        let segment = try Server.segment(id)
        let url = server.origin.appending(path: "api/modules/v1/video-jobs/\(segment)/record")
        var req = request(url, method: "DELETE")
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
            AppDiagnostics.record(failure)
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
            if (response as? HTTPURLResponse)?.statusCode != 200 {
                envelope = try? LocalFileStore.readPrefix(from: temporary, count: 65_536, maximumBytes: 65_536)
            } else { envelope = nil }
            try checked(response, expected: 200, data: envelope)
            guard response.mimeType == "video/mp4",
                  let header = try? LocalFileStore.readPrefix(from: temporary, count: 8, maximumBytes: LocalFileStore.maximumVideoBytes),
                  header.dropFirst(4).elementsEqual("ftyp".utf8) else {
                throw APIError.unsafeVideo
            }
            let folder = FileManager.default.temporaryDirectory
            let target = try LocalFileStore.safeWriteURL(folder.appendingPathComponent("Sweat-\(UUID()).mp4"), within: folder)
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
                do { try LocalFileStore.protectFile(target) }
                catch {
                    try? FileManager.default.removeItem(at: target)
                    throw error
                }
            }
            catch { AppDiagnostics.record(error); throw APIError.storage }
            return target
        } catch let error as URLError {
            AppDiagnostics.record(error)
            if error.code == .cancelled { throw CancellationError() }
            throw mapped(error, posting: false)
        }
    }
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
                do {
                    for try await byte in bytes {
                        guard data.count < 65_536 else { break }
                        data.append(byte)
                    }
                } catch let error as URLError {
                    AppDiagnostics.record(error)
                    try Task.checkCancellation()
                    throw AppDiagnostics.record(V2Failure.interrupted)
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

    func v2Chat(_ input: V2ChatRequest, willPost: (@Sendable () async -> Void)? = nil,
                receive: @Sendable (V2ChatEvent) async -> Void) async throws {
        try await checkRenderBeforeChat()
        var req = try v2Request("chat", method: "POST")
        req.httpBody = try JSONEncoder().encode(input)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Task.checkCancellation()
        await willPost?()
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
        } catch let error as URLError {
            AppDiagnostics.record(error)
            try Task.checkCancellation()
            throw AppDiagnostics.record(V2Failure.interrupted)
        }
        do { try parser.end() }
        catch { throw AppDiagnostics.record(error) }
    }

    func v2DescribeImage(_ jpegData: Data, prompt: String, model: V2Models.Entry,
                         receive: @Sendable (V2ChatEvent) async -> Void) async throws {
        guard model.supportsImageChat else { throw V2Failure.invalidInput }
        let image = try V2ChatRequest.Image(jpegData: jpegData)
        let request = try V2ChatRequest(message: prompt, modelID: model.id, image: image)
        try await v2Chat(request, receive: receive)
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
