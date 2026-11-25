import Foundation
import CoreML
import FluidAudio

public actor SpeakerRuntime {
    public static let shared = SpeakerRuntime()
    public struct Span: Sendable { public let speaker: String; public let start: Double; public let end: Double }
    private struct FileStamp: Codable { let path: String; let bytes: Int }
    private var busy = false
    public nonisolated static var folder: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/SpeakerModels", isDirectory: true) }
    private nonisolated static var receipt: URL { folder.appendingPathComponent("installed.json") }
    public nonisolated static var installed: Bool { (try? filesValid()) == true }
    private nonisolated static func filesValid() throws -> Bool {
        guard let size = try? receipt.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 500_000 else { return false }
        let files = try JSONDecoder().decode([FileStamp].self, from: Data(contentsOf: receipt))
        guard !files.isEmpty, files.count <= 3_000 else { return false }
        return try files.allSatisfy { file in
            let url = folder.appendingPathComponent(file.path).standardizedFileURL
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."), url.path.hasPrefix(folder.path + "/") else { return false }
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            return info.isRegularFile == true && info.isSymbolicLink != true && info.fileSize == file.bytes && file.bytes > 0
        }
    }
    /// Network access is enabled only for this explicit install action.
    public func install() async throws {
        guard !busy else { throw CocoaError(.userCancelled) }; busy = true
        defer { busy = false; ModelHub.offlineMode = true }
        ModelHub.offlineMode = false
        _ = try await OfflineDiarizerModels.load(from: Self.folder)
        try Task.checkCancellation()
        let enumerator = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        var files: [FileStamp] = []
        while let file = enumerator?.nextObject() as? URL {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if info.isRegularFile == true, info.isSymbolicLink != true, file != Self.receipt, let size = info.fileSize, size > 0 {
                files.append(.init(path: String(file.path.dropFirst(Self.folder.path.count + 1)), bytes: size))
            }
        }
        guard !files.isEmpty, files.count <= 3_000 else { throw CocoaError(.fileReadCorruptFile) }
        try JSONEncoder().encode(files).write(to: Self.receipt, options: [.atomic, .completeFileProtection])
    }
    public func separate(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Span] {
        guard !busy else { throw CocoaError(.userCancelled) }; busy = true
        defer { busy = false }
        ModelHub.offlineMode = true
        guard Self.installed else { throw CocoaError(.fileNoSuchFile) }
        let models = try await OfflineDiarizerModels.load(from: Self.folder)
        try Task.checkCancellation()
        var config = OfflineDiarizerConfig.default; config.exclusiveSegments = false
        let manager = OfflineDiarizerManager(config: config); manager.initialize(models: models)
        let result = try await manager.process(file) { done, total in progress(Double(done) / Double(max(1, total))) }
        try Task.checkCancellation()
        return result.segments.map { .init(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
    public func remove() throws {
        guard !busy else { throw CocoaError(.userCancelled) }
        if FileManager.default.fileExists(atPath: Self.folder.path) { try FileManager.default.removeItem(at: Self.folder) }
    }
}
