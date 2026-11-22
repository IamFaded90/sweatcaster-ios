import Foundation
import Logging
import MCP

struct PCRepositoryHit: Decodable, Identifiable, Sendable {
    let path: String
    let line: Int
    let text: String
    var id: String { "\(path):\(line)" }
}

struct PCRepositoryTools {
    let api: LiveAPI

    private enum Operation: String {
        case search = "search_repository"
        case read = "read_repository_file"
    }

    func search(repository: String, query: String) async throws -> [PCRepositoryHit] {
        let output = try await call(.search, arguments: ["repository": repository, "query": query])
        if let value = output.structuredContent {
            struct Matches: Decodable { let result: [PCRepositoryHit] }
            let data = try JSONEncoder().encode(value)
            if let matches = try? JSONDecoder().decode(Matches.self, from: data) {
                return Array(matches.result.prefix(5))
            }
        }
        var hits: [PCRepositoryHit] = []
        for text in textItems(output) {
            let data = Data(text.utf8)
            if let list = try? JSONDecoder().decode([PCRepositoryHit].self, from: data) {
                hits.append(contentsOf: list)
            } else {
                hits.append(try JSONDecoder().decode(PCRepositoryHit.self, from: data))
            }
        }
        return Array(hits.prefix(5))
    }

    func read(repository: String, path: String) async throws -> String {
        let output = try await call(.read, arguments: ["repository": repository, "path": path])
        return String(textItems(output).joined(separator: "\n").prefix(16_000))
    }

    private func textItems(_ result: MCP.CallTool.Result) -> [String] {
        result.content.compactMap {
            if case let .text(text, _, _) = $0 { return text }
            return nil
        }
    }

    private func call(_ operation: Operation, arguments: [String: String]) async throws -> MCP.CallTool.Result {
        let client = MCP.Client(name: "FadedAI", version: "1.0")
        let transport = PairedMCPTransport(api: api)
        return try await withTaskCancellationHandler {
            do {
                try await client.connect(transport: transport)
                let available = try await client.listTools()
                guard available.tools.contains(where: { $0.name == operation.rawValue }) else { throw APIError.malformed }
                let request = MCP.CallTool.request(.init(name: operation.rawValue, arguments: arguments.mapValues(MCP.Value.string)))
                let context = try await client.send(request)
                let output = try await context.value
                try Task.checkCancellation()
                guard output.isError != true else { throw APIError.malformed }
                await client.disconnect()
                return output
            } catch {
                await client.disconnect()
                throw error
            }
        } onCancel: {
            Task { await client.disconnect() }
        }
    }
}

/// The SDK handles JSON-RPC request routing. Reuse the paired session so redirects, cookies and IP policy
/// match the rest of FadedAI. Only the paired PC's bounded, stateless JSON MCP endpoint is supported here.
private actor PairedMCPTransport: MCP.Transport {
    nonisolated let logger = Logger(label: "fadedai.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
    private let api: LiveAPI
    private let stream: AsyncThrowingStream<Data, any Error>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private var protocolVersion: String?
    private var connected = false

    init(api: LiveAPI) {
        self.api = api
        let (stream, output) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        self.stream = stream
        self.output = output
    }

    func connect() async throws { connected = true }

    func disconnect() async {
        connected = false
        output.finish()
    }

    func receive() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ data: Data) async throws {
        guard connected, data.count <= 32_768 else { throw APIError.malformed }
        let (reply, status) = try await api.postRepositoryMCP(data, version: protocolVersion)
        guard connected else { throw CancellationError() }
        if status == 202 { return }
        if protocolVersion == nil {
            struct InitializeReply: Decodable {
                struct Result: Decodable { let protocolVersion: String }
                let result: Result?
            }
            let decoded = try? JSONDecoder().decode(InitializeReply.self, from: reply)
            if let version = decoded?.result?.protocolVersion,
               version.utf8.count == 10, version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }) {
                protocolVersion = version
            }
        }
        output.yield(reply)
    }
}

extension LiveAPI {
    fileprivate func postRepositoryMCP(_ data: Data, version: String?) async throws -> (Data, Int) {
        let target = server.origin.appending(path: "api/modules/v1/mcp")
        var call = request(target, method: "POST")
        call.timeoutInterval = 35
        call.httpBody = data
        call.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.setValue("repository", forHTTPHeaderField: "X-FadedAI-Tools")
        if let version { call.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (reply, response) = try await loggedData(for: call)
        guard let http = response as? HTTPURLResponse, reply.count <= 500_000 else { throw APIError.malformed }
        if http.statusCode != 202 { try checked(response, expected: 200, data: reply) }
        return (reply, http.statusCode)
    }
}
