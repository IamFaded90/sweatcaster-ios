import Foundation

extension LiveAPI {
    func agentRooms(botID: UUID? = nil, published: Bool = false) async throws -> [AgentRoom] {
        struct List: Decodable { let rooms: [AgentRoom] }
        var query: [URLQueryItem] = []
        if let botID { query.append(.init(name: "bot_id", value: botID.uuidString.lowercased())) }
        if published { query.append(.init(name: "published", value: "true")) }
        let value: List = try await moduleJSON("agent-rooms", query: query)
        guard value.rooms.count <= 100 else { throw AgentRoomFailure.invalidData }
        return try value.rooms.map { try $0.validated() }
    }

    func agentRoom(_ id: UUID) async throws -> AgentRoom {
        let value: AgentRoom = try await moduleJSON("agent-rooms/\(id.uuidString.lowercased())")
        guard value.id == id else { throw AgentRoomFailure.invalidData }
        return try value.validated()
    }

    func buildAgentRoom(id: UUID, botID: UUID, title: String, brief: String, sketch: Data,
                        figures: [VillageBot]) async throws -> AgentRoom {
        struct Figure: Encodable { let id: UUID; let name, character: String }
        struct Input: Encodable {
            let botID: UUID
            let title, brief: String
            let sketch: Data
            let figures: [Figure]
        }
        guard !sketch.isEmpty, sketch.count <= 1_900_000, (1...8).contains(figures.count) else {
            throw AgentRoomFailure.input
        }
        let input = Input(botID: botID, title: title, brief: brief, sketch: sketch,
                          figures: figures.map { Figure(id: $0.id, name: $0.name, character: $0.villageFigure) })
        return try await roomMutation(id, action: nil, payload: JSONEncoder().encode(input))
    }

    func reviseAgentRoom(_ room: UUID, revision: Int, figureID: UUID, scale: Double,
                         instruction: String) async throws -> AgentRoom {
        struct Input: Encodable { let revision: Int; let figureID: UUID; let scale: Double; let instruction: String }
        let input = Input(revision: revision, figureID: figureID, scale: scale, instruction: instruction)
        return try await roomMutation(room, action: "revise", payload: JSONEncoder().encode(input))
    }

    func publishAgentRoom(_ id: UUID, revision: Int) async throws -> AgentRoom {
        try await roomMutation(id, action: "publish", payload: JSONEncoder().encode(["revision": revision]))
    }

    func retryAgentRoom(_ id: UUID) async throws -> AgentRoom {
        try await roomMutation(id, action: "retry", payload: Data("{}".utf8))
    }

    func removeAgentRoom(_ id: UUID) async throws -> Bool {
        struct Receipt: Decodable { let removed: Bool }
        let receipt: Receipt = try await moduleJSON("agent-rooms/\(id.uuidString.lowercased())/remove",
                                                     upload: Data("{}".utf8))
        return receipt.removed
    }

    func agentRoomArtwork(_ id: UUID, digest: String) async throws -> Data {
        struct Artwork: Decodable { let image: Data }
        guard AgentRoom.validArtwork(digest) else { throw AgentRoomFailure.invalidData }
        let result: Artwork = try await moduleJSON("agent-rooms/\(id.uuidString.lowercased())/art/\(digest)",
                                                   maximumBytes: 4_500_000)
        guard !result.image.isEmpty, result.image.count <= 3_300_000 else { throw AgentRoomFailure.image }
        return result.image
    }

    private func roomMutation(_ id: UUID, action: String?, payload: Data) async throws -> AgentRoom {
        let suffix = action.map { "/" + $0 } ?? ""
        let result: AgentRoom = try await moduleJSON("agent-rooms/\(id.uuidString.lowercased())" + suffix,
                                                     upload: payload, timeout: 30)
        guard result.id == id else { throw AgentRoomFailure.invalidData }
        return try result.validated()
    }
}
