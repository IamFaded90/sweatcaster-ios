import Foundation

@MainActor struct PCChatOutbox {
    struct Entry: Codable, Identifiable, Equatable {
        enum State: String, Codable { case waiting, attempted, completed }

        let id: UUID
        let address: String
        let prompt: String
        let message: String
        let sessionID: UUID
        let modelID: String?
        let createdAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var reply: String?

        func request() throws -> V2ChatRequest {
            try V2ChatRequest(message: message, sessionID: sessionID.uuidString, modelID: modelID, requestID: id)
        }
    }

    enum Failure: Error { case invalidTarget, full, invalidStorage }

    static let didChange = Notification.Name("FadedAI.pcChatOutboxDidChange")
    private static var draining = Set<String>()
    private static var inFlight = Set<UUID>()
    private let file: URL

    init(file: URL = URL.applicationSupportDirectory.appending(path: "PCChatOutbox/queue.json")) {
        self.file = file
    }

    static func confirmedOffline(_ error: APIError?) -> Bool {
        switch error {
        case .offline, .localNetwork: true
        case .transport(let code):
            [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut]
                .contains { $0.rawValue == code }
        default: false
        }
    }

    func entries(for address: String) throws -> [Entry] {
        try read().filter { $0.address == address }
    }

    func pendingCount(for address: String) -> Int {
        (try? entries(for: address).filter { $0.state == .waiting }.count) ?? 0
    }

    func reviewCount(for address: String) -> Int {
        (try? entries(for: address).filter { $0.state == .attempted && !Self.isDelivering($0.id) }.count) ?? 0
    }

    static func isDelivering(_ id: UUID) -> Bool { inFlight.contains(id) }

    @discardableResult
    func enqueue(address: String, prompt: String, message: String, sessionID: UUID, modelID: String?) throws -> Entry {
        guard let server = try? Server(address), server.address == address else { throw Failure.invalidTarget }
        let entry = Entry(id: UUID(), address: address, prompt: prompt, message: message, sessionID: sessionID,
                          modelID: modelID, createdAt: .now, state: .waiting, reply: nil)
        _ = try entry.request()
        var stored = try read()
        guard stored.count < 32 else { throw Failure.full }
        stored.append(entry)
        try write(stored)
        return entry
    }

    func claim(_ id: UUID, for address: String) throws -> Entry? {
        var stored = try read()
        guard let index = stored.firstIndex(where: { $0.id == id && $0.address == address && $0.state == .waiting }) else { return nil }
        stored[index].state = .attempted
        try write(stored)
        return stored[index]
    }

    func complete(_ id: UUID, for address: String, reply: String) throws {
        var stored = try read()
        guard let index = stored.firstIndex(where: { $0.id == id && $0.address == address && $0.state == .attempted }) else { return }
        stored[index].state = .completed
        stored[index].reply = reply
        try write(stored)
    }

    func remove(_ ids: Set<UUID>, for address: String) throws {
        var stored = try read()
        let previous = stored.count
        stored.removeAll { $0.address == address && ids.contains($0.id) && !Self.isDelivering($0.id) }
        if stored.count != previous { try write(stored) }
    }

    func deliverReady(using api: LiveAPI) async {
        let address = api.server.address
        guard Self.draining.insert(address).inserted else { return }
        defer { Self.draining.remove(address) }
        do {
            let waiting = try entries(for: address).filter { $0.state == .waiting }
            guard !waiting.isEmpty else { return }
            // Establish V2 support before consuming an attempt. GET has no job side effects.
            _ = try await api.v2Models()
            for item in waiting {
                try Task.checkCancellation()
                try await deliver(item, using: api)
            }
        } catch {
            // Network failures stop this drain. Claimed requests remain attempted and cannot replay.
        }
    }

    private func deliver(_ item: Entry, using api: LiveAPI) async throws {
        let request = try item.request()
        Self.inFlight.insert(item.id)
        defer {
            Self.inFlight.remove(item.id)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        guard try claim(item.id, for: api.server.address) != nil else { return }
        try Task.checkCancellation()
        let answer = Answer()
        try await api.v2Chat(request) { event in
            if event.type == .text { await answer.append(event.content) }
        }
        try complete(item.id, for: api.server.address, reply: api.redactChat(answer.text, complete: true))
    }

    private func read() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...3_000_000).contains(size) else { throw Failure.invalidStorage }
        let stored = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file, options: .mappedIfSafe))
        guard stored.count <= 32, Set(stored.map(\.id)).count == stored.count else { throw Failure.invalidStorage }
        return stored
    }

    private func write(_ stored: [Entry]) throws {
        var folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try folder.setResourceValues(properties)
        try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtection])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    @MainActor private final class Answer {
        private var output = ""
        private var remaining = 12_000
        private var truncated = false

        var text: String { output + (truncated ? "\n\nSvaret er forkortet i udbakken." : "") }

        func append(_ delta: String) {
            let part = delta.unicodeScalars.prefix(remaining)
            output += String(part)
            remaining -= part.count
            truncated = truncated || part.count < delta.unicodeScalars.count
        }
    }
}
