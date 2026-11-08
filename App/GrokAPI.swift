// Explicit cloud chat requests and xAI stream decoding.
import Foundation

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
        } catch let error as URLError {
            AppDiagnostics.record(error)
            try Task.checkCancellation()
            throw output.isEmpty ? GrokFailure.unavailable : GrokFailure.interrupted
        } catch let error as V2Failure {
            AppDiagnostics.record(error)
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
