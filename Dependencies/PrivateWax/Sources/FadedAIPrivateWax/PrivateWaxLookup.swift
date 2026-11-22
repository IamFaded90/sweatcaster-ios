import Foundation
import Wax

/// A single explicit lookup. Only fresh, opaque word identifiers enter the temporary Wax index.
public final class PrivateWaxLookup: @unchecked Sendable {
    public struct Turn: Sendable {
        public let id: UUID
        public let text: String
        public init(id: UUID, text: String) { self.id = id; self.text = text }
    }

    private static let registry = Directories()
    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("FadedAIPrivateWax", isDirectory: true) }
    private let work: URL
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    public convenience init() { self.init(root: Self.root) }
    init(root: URL) { work = root.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    public static func cleanAbandoned() throws { try registry.sweep(root) }
    static func cleanAbandoned(in root: URL) throws { try registry.sweep(root) }

    public func cancel() {
        lock.withLock { cancelled = true }
        try? Self.registry.finish(work)
    }

    private func check() throws {
        try Task.checkCancellation()
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    public func search(_ query: String, in turns: [Turn]) async throws -> [UUID] {
        try check()
        let queryWords = terms(query)
        guard !queryWords.isEmpty, !turns.isEmpty else { return [] }
        let requested = Set(queryWords)
        var candidates: [Candidate] = []
        for turn in turns {
            try check()
            let words = terms(turn.text)
            if requested.isSubset(of: Set(words)) { candidates.append(Candidate(id: turn.id, words: words)) }
        }
        guard !candidates.isEmpty else { return [] }
        try lock.withLock {
            guard !started, !cancelled else { throw CancellationError() }
            started = true
            try Self.registry.reserve(work)
        }
        do {
            let hits = try await lookup(queryWords, candidates: candidates)
            try Self.registry.finish(work)
            try check()
            return hits
        } catch {
            try Self.registry.finish(work)
            throw error
        }
    }

    private func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "da_DK"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private struct Candidate {
        let id: UUID
        let words: [String]
    }

    private func lookup(_ queryWords: [String], candidates: [Candidate]) async throws -> [UUID] {
        try check()
        let memory = try await Memory(at: work.appendingPathComponent("chat.wax")) {
            $0.enableVectorSearch = false
            $0.enableStructuredMemory = false
            $0.enableAccessStatsScoring = false
            $0.enableAsyncEnrichment = false
            $0.resolvesRelativeDates = false
        }
        do {
            var wordIDs: [String: String] = [:]
            var used: Set<String> = []
            var rows: [UInt64: UUID] = [:]
            var rowTokens: [String: UUID] = [:]
            func freshCode() -> String {
                var code: String
                repeat { code = "w" + String(UInt32.random(in: 1...UInt32.max), radix: 36) } while !used.insert(code).inserted
                return code
            }
            for turn in candidates {
                try check()
                let row = freshCode()
                rowTokens[row] = turn.id
                var words = [String]()
                for (index, term) in turn.words.enumerated() {
                    if index.isMultiple(of: 128) { try check() }
                    if wordIDs[term] == nil { wordIDs[term] = freshCode() }
                    if let code = wordIDs[term] { words.append(code) }
                }
                // Short records keep the private display identifier alongside every searchable passage.
                for i in stride(from: 0, to: words.count, by: 24) {
                    try check()
                    let chunk = ([row] + words[i..<min(i + 24, words.count)]).joined(separator: " ")
                    let frameID = try await memory.save(chunk)
                    rows[frameID] = turn.id
                }
            }
            let queryCodes = queryWords.compactMap { wordIDs[$0] }
            var hits = [UUID]()
            if !queryCodes.isEmpty {
                try check()
                try await memory.flush()
                let results = try await memory.search(queryCodes.joined(separator: " "), options: .init(topK: 32, mode: .textOnly, inferTimeRange: false))
                var seen = Set<UUID>()
                for item in results.items {
                    let row = rows[item.frameId] ?? item.text.split { !$0.isLetter && !$0.isNumber }.lazy.compactMap { rowTokens[String($0)] }.first
                    if let row, seen.insert(row).inserted { hits.append(row) }
                }
            }
            try await memory.close()
            try check()
            return hits
        } catch {
            try? await memory.close()
            throw error
        }
    }
}

private final class Directories: @unchecked Sendable {
    private let lock = NSLock()
    private var active = Set<URL>()
    private let files = FileManager.default

    func reserve(_ directory: URL) throws {
        try lock.withLock {
            let root = directory.deletingLastPathComponent()
            try protectedDirectory(root)
            try removeAbandoned(root)
            try protectedDirectory(directory)
            active.insert(directory.standardizedFileURL)
        }
    }

    func finish(_ directory: URL) throws {
        try lock.withLock {
            active.remove(directory.standardizedFileURL)
            do { try files.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func sweep(_ root: URL) throws {
        try lock.withLock {
            do { try removeAbandoned(root) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        }
    }

    private func removeAbandoned(_ root: URL) throws {
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: entry.lastPathComponent) != nil, !active.contains(entry.standardizedFileURL) else { continue }
            try files.removeItem(at: entry)
        }
    }

    private func protectedDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700]
        #else
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #endif
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        #if os(iOS)
        try files.setAttributes(attributes, ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #endif
    }
}
