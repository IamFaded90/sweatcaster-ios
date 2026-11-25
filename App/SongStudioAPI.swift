import Foundation

struct SongRemoval: Decodable {
    let removed: Bool
    let engineMayContinue: Bool?
    let cleanupPending: Bool?
}

extension LiveAPI {
    func songStudio() async throws -> SongStudioCatalog { try await moduleJSON("song-studio", timeout: 8) }
    func createSong(_ draft: SongDraft) async throws -> SongJob {
        guard draft.problem == nil else { throw APIError.input }
        var outgoing = draft
        if draft.enhancePrompt { outgoing.prompt = SongPrompt.expanded(draft.prompt, instrumental: draft.instrumental) }
        return try await moduleJSON("song-studio/jobs/" + draft.id.uuidString.lowercased(),
            upload: JSONEncoder().encode(outgoing), timeout: 45)
    }
    func songJob(_ id: UUID) async throws -> SongJob {
        try await moduleJSON("song-studio/jobs/" + id.uuidString.lowercased())
    }
    func songAudio(_ id: UUID) async throws -> Data {
        struct Audio: Decodable { let audio: Data }
        let value: Audio = try await moduleJSON("song-studio/jobs/" + id.uuidString.lowercased() + "/audio", timeout: 100, maximumBytes: 94_000_000)
        return value.audio
    }
    func removeSong(_ id: UUID) async throws -> SongRemoval {
        let result: SongRemoval = try await moduleJSON("song-studio/jobs/" + id.uuidString.lowercased() + "/remove", upload: Data("{}".utf8))
        guard result.removed else { throw APIError.input }
        return result
    }
}
