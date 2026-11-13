import Foundation

@MainActor struct PCChatOutbox {
    struct Entry: Codable, Identifiable, Equatable {
        enum State: String, Codable { case waiting, attempted, review, completed }

        let id: UUID
        let address: String
        let targetID: String?
        let prompt: String
        let message: String
        let sessionID: UUID
        let modelID: String?
        let createdAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var reply: String?
        fileprivate(set) var replyModelID: String?
        fileprivate(set) var attempts: Int?
        fileprivate(set) var retryRequestID: UUID?

        var needsReview: Bool { state == .attempted || state == .review }

        func request() throws -> V2ChatRequest {
            try V2ChatRequest(message: message, sessionID: sessionID.uuidString, modelID: modelID, requestID: retryRequestID ?? id)
        }
    }

    enum Failure: Error { case invalidTarget, full, invalidStorage }

    static let didChange = Notification.Name("FadedAI.pcChatOutboxDidChange")
    private static let maximumBytes = 3_000_000
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

    func pendingCount(for address: String, targetID: String? = nil) -> Int {
        (try? entries(for: address).filter { $0.state == .waiting && (targetID == nil || $0.targetID == targetID) }.count) ?? 0
    }

    func reviewCount(for address: String, targetID: String? = nil) -> Int {
        (try? entries(for: address).filter {
            !Self.isDelivering($0.id) && ($0.needsReview || (targetID != nil && $0.targetID != targetID))
        }.count) ?? 0
    }

    static func isDelivering(_ id: UUID) -> Bool { inFlight.contains(id) }

    @discardableResult
    func enqueue(address: String, targetID: String, prompt: String, message: String, sessionID: UUID, modelID: String?) throws -> Entry {
        guard !targetID.isEmpty, let server = try? Server(address), server.address == address else { throw Failure.invalidTarget }
        let entry = Entry(id: UUID(), address: address, targetID: targetID, prompt: prompt, message: message, sessionID: sessionID,
                          modelID: modelID, createdAt: .now, state: .waiting, reply: nil)
        _ = try entry.request()
        var stored = try read()
        guard stored.count < 32 else { throw Failure.full }
        stored.append(entry)
        try write(stored)
        return entry
    }

    func claim(_ id: UUID, for address: String, targetID: String) throws -> Entry? {
        var stored = try read()
        guard let index = stored.firstIndex(where: {
            $0.id == id && $0.address == address && $0.targetID == targetID && $0.state == .waiting
        }) else { return nil }
        stored[index].state = .attempted
        stored[index].attempts = min(2, max(0, stored[index].attempts ?? 0)) + 1
        try write(stored)
        return stored[index]
    }

    @discardableResult
    func retry(_ id: UUID, for address: String, targetID: String) throws -> Bool {
        var stored = try read()
        guard !Self.isDelivering(id), let index = stored.firstIndex(where: {
            $0.id == id && $0.address == address && $0.targetID == targetID && $0.needsReview
        }) else { return false }
        stored[index].state = .waiting
        stored[index].attempts = 0
        stored[index].retryRequestID = UUID()
        try write(stored)
        return true
    }

    private func fail(_ id: UUID, for address: String, targetID: String,
                      canRetry: Bool, restoreAttempt: Bool) throws {
        var stored = try read()
        guard let index = stored.firstIndex(where: {
            $0.id == id && $0.address == address && $0.targetID == targetID && $0.state == .attempted
        }) else { return }
        if restoreAttempt { stored[index].attempts = max(0, (stored[index].attempts ?? 1) - 1) }
        stored[index].state = canRetry && (stored[index].attempts ?? 1) < 3 ? .waiting : .review
        try write(stored)
    }

    func complete(_ id: UUID, for address: String, targetID: String, reply: String, replyModelID: String? = nil) throws {
        var stored = try read()
        guard let index = stored.firstIndex(where: {
            $0.id == id && $0.address == address && $0.targetID == targetID && $0.state == .attempted
        }) else { return }
        stored[index].state = .completed
        stored[index].reply = reply
        stored[index].replyModelID = replyModelID
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
            let waiting = try entries(for: address).filter { $0.state == .waiting && $0.targetID == api.queueTargetID }
            guard !waiting.isEmpty else { return }
            // Establish V2 support before consuming an attempt. GET has no job side effects.
            _ = try await api.v2Models()
            for item in waiting {
                try Task.checkCancellation()
                try await deliver(item, using: api)
            }
        } catch {
            AppDiagnostics.record(error)
            // Stop this drain. A subsequent pass may retry only requests known not to have connected.
        }
    }

    private func deliver(_ item: Entry, using api: LiveAPI) async throws {
        let request = try item.request()
        Self.inFlight.insert(item.id)
        defer {
            Self.inFlight.remove(item.id)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        guard try claim(item.id, for: api.server.address, targetID: api.queueTargetID) != nil else { return }
        let answer = Answer()
        do {
            try Task.checkCancellation()
            try await api.v2Chat(request, willPost: { await answer.markPosting() }) { event in
                await answer.record(event, modelID: api.reportedReplyModelID(for: event))
            }
            try complete(item.id, for: api.server.address, targetID: api.queueTargetID,
                         reply: api.redactChat(answer.text, complete: true), replyModelID: answer.modelID)
        } catch {
            let deferred = !answer.startedPOST && Self.deferredBeforePOST(error)
            let canRetry = !answer.sawEvent && (deferred || Self.failedToConnect(error)
                || (!answer.startedPOST && Self.confirmedOffline(error as? APIError)))
            try fail(item.id, for: api.server.address, targetID: api.queueTargetID,
                     canRetry: canRetry, restoreAttempt: deferred)
            throw error
        }
    }

    private static func deferredBeforePOST(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .http(503, _)? = error as? APIError { return true }
        return false
    }

    private static func failedToConnect(_ error: Error) -> Bool {
        let code: Int
        if case .transport(let value)? = error as? APIError { code = value }
        else if let failure = error as? URLError { code = failure.code.rawValue }
        else { return false }
        // A timeout or lost connection can happen after the server accepted the POST.
        return [URLError.Code.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .dnsLookupFailed]
            .contains { $0.rawValue == code }
    }

    private func read() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        _ = try checkedFolder()
        let data = try LocalFileStore.readBytes(from: file, maximumBytes: Self.maximumBytes)
        guard !data.isEmpty else { throw Failure.invalidStorage }
        let stored = try JSONDecoder().decode([Entry].self, from: data)
        guard stored.count <= 32, Set(stored.map(\.id)).count == stored.count else { throw Failure.invalidStorage }
        return stored
    }

    private func write(_ stored: [Entry]) throws {
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumBytes else { throw Failure.full }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var folder = try checkedFolder()
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try folder.setResourceValues(properties)
        try LocalFileStore.writeBytes(data, to: file, within: folder)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func checkedFolder() throws -> URL {
        let folder = file.deletingLastPathComponent()
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.invalidStorage }
        return folder
    }

    @MainActor private final class Answer {
        private var output = ""
        private var remaining = 12_000
        private var truncated = false
        private(set) var modelID: String?
        private(set) var sawEvent = false
        private(set) var startedPOST = false

        func markPosting() { startedPOST = true }

        var text: String { output + (truncated ? "\n\nSvaret er forkortet i udbakken." : "") }

        func record(_ event: V2ChatEvent, modelID: String?) {
            sawEvent = true
            if let modelID { self.modelID = modelID }
            guard event.type == .text else { return }
            let delta = event.content
            let part = delta.unicodeScalars.prefix(remaining)
            output += String(part)
            remaining -= part.count
            truncated = truncated || part.count < delta.unicodeScalars.count
        }
    }
}
