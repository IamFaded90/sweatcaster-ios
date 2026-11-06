import Foundation
import Security

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
              (n[0] == 192 && n[1] == 168),
              let origin = URL(string: "http://\(address):8765") else { throw APIError.address }
        self.address = address
        self.origin = origin
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

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct LiveAPI: SweatAPI {
    let server: Server
    private let token: String
    private let session: URLSession
    init(server: Server, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw APIError.token }
        self.server = server
        self.token = token
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess = false
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
        guard let http = response as? HTTPURLResponse else { throw APIError.malformed }
        guard http.statusCode == expected else {
            let decoded = data.flatMap { try? contractDecoder().decode(Envelope.self, from: $0).error }
            let safe = decoded.map {
                Problem(code: redact($0.code), message: redact($0.message))
            }
            throw APIError.http(http.statusCode, safe)
        }
    }
    private func redact(_ text: String) -> String {
        text.replacingOccurrences(of: token, with: "[skjult]")
    }
    private func json<T: Decodable>(_ path: String, status: Int = 200, post: Bool = false,
                                     body: Batch? = nil, auth: Bool = true) async throws -> T {
        var req = request(server.endpoint(path), method: post ? "POST" : "GET", auth: auth)
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: req)
            try checked(response, expected: status, data: data)
            do { return try contractDecoder().decode(T.self, from: data) }
            catch { throw APIError.malformed }
        } catch let error as URLError {
            if error.code == .cancelled && !post { throw CancellationError() }
            throw mapped(error, posting: post)
        }
    }
    func health() async throws -> Health { try await json("health", auth: false) }
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
            guard response.mimeType == "video/mp4" else {
                throw APIError.unsafeVideo
            }
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
}
