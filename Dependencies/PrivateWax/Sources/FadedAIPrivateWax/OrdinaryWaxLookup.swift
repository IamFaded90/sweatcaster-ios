import Foundation
import Wax

/// Persistent, source-ID-bound ordinary memory. Never uses PrivateWaxLookup's temporary root.
public actor OrdinaryWaxLookup {
    public struct Row: Codable, Equatable, Sendable {
        public let id: UUID
        public let text: String
        public init(id: UUID, text: String) { self.id = id; self.text = text }
    }
    private struct Binding: Codable { let row: Row; let frame: UInt64 }
    private let root: URL
    private var busy = false
    private var clearing = 0
    public init(root: URL) { self.root = root }
    public func clear(botID: UUID) async throws {
        clearing += 1; defer { clearing -= 1 }
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        try remove(folder(botID))
    }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func remove(_ work: URL) throws {
        guard work.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
        if FileManager.default.fileExists(atPath: work.path) { try FileManager.default.removeItem(at: work) }
    }
    public func search(_ query: String, botID: UUID, rows: [Row]) async throws -> [UUID] {
        guard !busy, clearing == 0 else { return [] }; busy = true; defer { busy = false }
        try Task.checkCancellation()
        guard rows.count <= 300, Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 6_000 }) else { throw CocoaError(.fileReadCorruptFile) }
        let work = folder(botID), files = FileManager.default
        if rows.isEmpty { try remove(work); return [] }
        let manifest = work.appendingPathComponent("sources.json"), dirty = work.appendingPathComponent("updating")
        if files.fileExists(atPath: dirty.path) || (files.fileExists(atPath: work.path) && (!files.fileExists(atPath: manifest.path) || !files.fileExists(atPath: work.appendingPathComponent("ordinary.wax").path))) { try remove(work) }
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        #if os(iOS)
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: work.path)
        #endif
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true; var excluded = work; try excluded.setResourceValues(flags)
        var bindings: [Binding] = []
        if files.fileExists(atPath: manifest.path) {
            guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
            bindings = try JSONDecoder().decode([Binding].self, from: Data(contentsOf: manifest))
        }
        let memory = try await Memory(at: work.appendingPathComponent("ordinary.wax")) {
            $0.enableVectorSearch = false; $0.enableStructuredMemory = false
            $0.enableAccessStatsScoring = false; $0.enableAsyncEnrichment = false; $0.resolvesRelativeDates = false
        }
        do {
            let wanted = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let changed = bindings.count != rows.count || bindings.contains { wanted[$0.row.id] != $0.row }
            if changed || !files.fileExists(atPath: manifest.path) {
                try Data([1]).write(to: dirty, options: .atomic)
                for old in bindings where wanted[old.row.id] != old.row { try Task.checkCancellation(); try await memory.delete(frameID: old.frame) }
                bindings.removeAll { wanted[$0.row.id] != $0.row }
                let existing = Set(bindings.map { $0.row.id })
                for row in rows where !existing.contains(row.id) {
                    try Task.checkCancellation(); let frame = try await memory.save(row.text, metadata: ["source": row.id.uuidString])
                    bindings.append(.init(row: row, frame: frame))
                }
                try await memory.flush()
                try JSONEncoder().encode(bindings).write(to: manifest, options: .atomic)
                try files.removeItem(at: dirty)
            }
            let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 2 }.prefix(10).map(String.init)
            guard !words.isEmpty else { try await memory.close(); return [] }
            let results = try await memory.search(words.joined(separator: " "), options: .init(topK: 10, mode: .textOnly, inferTimeRange: false))
            let sources = Dictionary(uniqueKeysWithValues: bindings.map { ($0.frame, $0.row.id) })
            var seen = Set<UUID>()
            let hits = results.items.compactMap { item -> UUID? in guard let id = sources[item.frameId], seen.insert(id).inserted else { return nil }; return id }
            try await memory.close(); try Task.checkCancellation(); return hits
        } catch { try? await memory.close(); throw error }
    }
}
