import Foundation

struct MusicPlaybackSnapshot: Codable, Equatable {
    let queue: [MusicTrack]
    let index: Int
    let position: Double
    let repeats: Bool
    var valid: Bool {
        !queue.isEmpty && queue.count <= 200 && queue.indices.contains(index)
            && position.isFinite && position >= 0 && position < 86_400
            && queue.allSatisfy { $0.id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
    }
    var resumePosition: Double {
        guard valid else { return 0 }
        let length = queue[index].duration
        return length.isFinite && length > 0 ? min(position, max(0, length - 1)) : position
    }
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedMusic", isDirectory: true).appendingPathComponent("player.json")
    }
    static func load(from file: URL = Self.file) throws -> Self? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count < 1_000_000 else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: data)
        return value.valid ? value : nil
    }
    func save(to file: URL = Self.file) throws {
        guard valid else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
