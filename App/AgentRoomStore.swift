import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

enum AgentRoomImages {
    static func image(_ data: Data) -> UIImage? {
        guard data.count <= 3_300_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let format = UTType(type as String),
              format == .png || format == .jpeg,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...4_096).contains(width), (1...4_096).contains(height), width * height <= 16_777_216,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: image)
    }

    static func sketch(_ data: Data) throws -> Data {
        guard data.count <= 12_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let format = UTType(type as String),
              format == .png || format == .jpeg else { throw AgentRoomFailure.image }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 1_280] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              thumbnail.width >= 64, thumbnail.height >= 64,
              (0.56...2.25).contains(Double(thumbnail.width) / Double(thumbnail.height)),
              let encoded = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.86),
              encoded.count <= 1_900_000 else { throw AgentRoomFailure.image }
        return encoded
    }
}

enum AgentRoomCache {
    private struct Saved: Codable {
        let server: String
        let room: AgentRoom
    }
    private static let files = FileManager.default
    private static var root: URL {
        files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentRooms-v1", isDirectory: true)
    }

    static func list(botID: UUID? = nil, server: String? = nil) -> [AgentRoom] {
        guard let urls = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.prefix(100).compactMap { url -> Saved? in
            guard let bytes = try? LocalFileStore.readBytes(from: url, maximumBytes: 512_000),
                  let saved = try? JSONDecoder().decode(Saved.self, from: bytes),
                  (try? saved.room.validated()) != nil, saved.room.published != nil,
                  server == nil || saved.server == server,
                  botID == nil || saved.room.botID == botID else { return nil }
            return saved
        }
        .sorted { $0.room.created > $1.room.created }
        .reduce(into: [AgentRoom]()) { rooms, saved in
            if !rooms.contains(where: { $0.id == saved.room.id }) { rooms.append(saved.room) }
        }
    }

    static func artwork(_ digest: String) -> Data? {
        guard AgentRoom.validArtwork(digest),
              let data = try? LocalFileStore.readBytes(from: root.appendingPathComponent(digest + ".image"),
                                                      maximumBytes: 3_300_000),
              hash(data) == digest else { return nil }
        return data
    }

    static func save(_ room: AgentRoom, server: String, image: Data, digest: String) throws {
        guard room.published?.artwork == digest, hash(image) == digest else { throw AgentRoomFailure.invalidData }
        _ = try room.validated()
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let record = Saved(server: server, room: room)
        let name = hash(Data((server + ":" + room.id.uuidString).utf8))
        try image.write(to: root.appendingPathComponent(digest + ".image"), options: [.atomic, .completeFileProtection])
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent(name + ".json"),
                                               options: [.atomic, .completeFileProtection])
    }

    static func remove(_ room: AgentRoom, server: String) throws {
        let name = hash(Data((server + ":" + room.id.uuidString).utf8))
        let url = root.appendingPathComponent(name + ".json")
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        let records = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let referenced = try Set(records.compactMap { record -> String? in
            let bytes = try LocalFileStore.readBytes(from: record, maximumBytes: 512_000)
            return try JSONDecoder().decode(Saved.self, from: bytes).room.published?.artwork
        })
        for digest in Set(room.versions.map(\.artwork)) where AgentRoom.validArtwork(digest) && !referenced.contains(digest) {
            let asset = root.appendingPathComponent(digest + ".image")
            if files.fileExists(atPath: asset.path) { try files.removeItem(at: asset) }
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@MainActor @Observable final class AgentRoomStore {
    private(set) var rooms: [AgentRoom] = []
    private(set) var current: AgentRoom?
    private(set) var images: [String: UIImage] = [:]
    private(set) var busy = false
    private(set) var offline = false
    var message: String?
    private var generation = UUID()
    private var boundServer: String?
    private var createID = UUID()
    private var creationFingerprint: String?

    func load(api: LiveAPI?, botID: UUID? = nil, published: Bool = false) async {
        let id = UUID()
        generation = id
        if boundServer != api?.queueTargetID {
            current = nil
            images = [:]
            creationFingerprint = nil
            boundServer = api?.queueTargetID
        }
        let local = AgentRoomCache.list(botID: botID, server: "phone")
        rooms = AgentRoomCache.list(botID: botID, server: api?.queueTargetID)
        if api != nil { rooms += local.filter { item in !rooms.contains { $0.id == item.id } } }
        offline = api == nil
        guard let api else {
            message = rooms.isEmpty ? "Forbind til PC’en for at bygge et rum fra din skitse." : "Viser dine gemte rum fra telefonen."
            return
        }
        do {
            let loaded = try await api.agentRooms(botID: botID, published: published)
            guard generation == id, !Task.isCancelled else { return }
            rooms = loaded + local.filter { item in !loaded.contains { $0.id == item.id } }
            offline = false
            message = nil
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            offline = true
            message = rooms.isEmpty ? Self.explain(error) : "PC’en kunne ikke nås. Du kan åbne gemte rum på telefonen."
        }
    }

    func select(_ room: AgentRoom) { current = room; message = nil }

    func refresh(api: LiveAPI?) async {
        guard let api, let room = current, !busy else { return }
        if AgentPhoneRoomEditor.isLocal(room) { return }
        let id = generation
        do {
            let value = try await api.agentRoom(room.id)
            guard generation == id, !Task.isCancelled else { return }
            current = value
            offline = false
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            offline = true
            message = Self.explain(error)
        }
    }

    func image(room: AgentRoom, version: AgentRoom.Version, api: LiveAPI?) async {
        guard images[version.artwork] == nil else { return }
        let id = generation
        do {
            let data: Data
            if let cached = AgentRoomCache.artwork(version.artwork) { data = cached }
            else if let api { data = try await api.agentRoomArtwork(room.id, digest: version.artwork) }
            else { throw AgentRoomFailure.unavailable }
            guard AgentRoomCache.hash(data) == version.artwork, let image = AgentRoomImages.image(data),
                  image.cgImage?.width == version.width, image.cgImage?.height == version.height else {
                throw AgentRoomFailure.image
            }
            guard generation == id, !Task.isCancelled else { return }
            images[version.artwork] = image
            if images.count > 8, let victim = images.keys.first(where: { $0 != version.artwork }) { images[victim] = nil }
            if let api, room.published?.artwork == version.artwork, !AgentPhoneRoomEditor.isLocal(room) {
                try AgentRoomCache.save(room, server: api.queueTargetID, image: data, digest: version.artwork)
            }
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            message = Self.explain(error)
        }
    }

    func create(api: LiveAPI?, bot: VillageBot, title: String, brief: String,
                sketch: Data, figures: [VillageBot]) async -> AgentRoom? {
        guard let api else { message = AgentRoomFailure.unavailable.localizedDescription; return nil }
        let descriptions = figures.map { "\($0.id.uuidString):\($0.name):\($0.villageFigure)" }.joined(separator: "\n")
        var source = Data("\(api.queueTargetID)\n\(bot.id.uuidString)\n\(title)\n\(brief)\n\(descriptions)\n".utf8)
        source.append(sketch)
        let fingerprint = AgentRoomCache.hash(source)
        if creationFingerprint != fingerprint { createID = UUID(); creationFingerprint = fingerprint }
        var result: AgentRoom?
        await action(api) {
            try await api.buildAgentRoom(id: self.createID, botID: bot.id, title: title, brief: brief,
                                        sketch: sketch, figures: figures)
        } apply: {
            self.current = $0
            self.rooms.insert($0, at: 0)
            self.createID = UUID()
            self.creationFingerprint = nil
            result = $0
        }
        return result
    }

    func revise(api: LiveAPI?, revision: Int, figureID: UUID, scale: Double, instruction: String) async {
        if let room = current, AgentPhoneRoomEditor.isLocal(room) {
            do { current = try AgentPhoneRoomEditor.resize(room, figureID: figureID, scale: scale, instruction: instruction); message = "Figurstørrelsen er gemt på telefonen. Motivændringer laves i det kreative forløb." }
            catch { message = "Figuren kunne ikke ændres. Vælg en størrelse mellem 0,7 og 1,65." }
            return
        }
        guard let api, let room = current else { return }
        await action(api) {
            try await api.reviseAgentRoom(room.id, revision: revision, figureID: figureID, scale: scale,
                                         instruction: instruction)
        } apply: { self.current = $0 }
    }

    func publish(api: LiveAPI?, revision: Int) async {
        if let room = current, AgentPhoneRoomEditor.isLocal(room) { message = "Rummet er allerede gemt på telefonen."; return }
        guard let api, let room = current else { return }
        await action(api) {
            try await api.publishAgentRoom(room.id, revision: revision)
        } apply: { self.current = $0; self.message = "Rummet er gemt i landsbyen." }
        if let updated = current, let version = updated.published {
            images[version.artwork] = nil
            await image(room: updated, version: version, api: api)
        }
    }

    func retry(api: LiveAPI?) async {
        guard let api, let room = current else { return }
        await action(api) { try await api.retryAgentRoom(room.id) } apply: { self.current = $0 }
    }

    func remove(api: LiveAPI?) async -> Bool {
        if let room = current, AgentPhoneRoomEditor.isLocal(room) {
            do {
                try AgentRoomCache.remove(room, server: "phone")
                rooms.removeAll { $0.id == room.id }; current = nil
                do { try VillageAmbienceHub.shared.reset(VillageAmbience.room(room.id)) }
                catch { message = "Rummet er fjernet. Stemningens filer kunne ikke ryddes helt." }
                return true
            }
            catch { message = "Rummet kunne ikke slettes fra telefonen."; return false }
        }
        guard let api, let room = current else { return false }
        var removed = false
        await action(api) { try await api.removeAgentRoom(room.id) } apply: { value in
            guard value else { return }
            self.rooms.removeAll { $0.id == room.id }
            self.current = nil
            removed = true
        }
        if removed {
            do { try VillageAmbienceHub.shared.reset(VillageAmbience.room(room.id)) }
            catch { message = "Rummet er fjernet. Stemningens filer kunne ikke ryddes helt." }
            do { try AgentRoomCache.remove(room, server: api.queueTargetID) }
            catch { message = "Rummet er fjernet på PC’en. Telefonens kopi kunne ikke fjernes." }
        }
        return removed
    }

    private func action<T>(_ api: LiveAPI, operation: () async throws -> T, apply: (T) -> Void) async {
        guard !busy else { return }
        busy = true
        let id = generation
        message = nil
        defer { busy = false }
        do {
            let value = try await operation()
            guard generation == id, !Task.isCancelled else { return }
            apply(value)
            offline = false
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            message = Self.explain(error)
        }
    }

    static func explain(_ error: Error) -> String {
        if let room = error as? AgentRoomFailure { return room.localizedDescription }
        if let api = error as? APIError {
            switch api {
            case .http(404, _): return "PC’en skal opdateres, eller rummet er blevet fjernet."
            case .http(409, _): return "Rummet er ændret i mellemtiden. Opdater det, og prøv igen."
            case .http(422, _): return "Tjek skitsen, teksten og de valgte figurer."
            default: return api.title
            }
        }
        return "Rummet kunne ikke hentes fra PC’en. Prøv igen."
    }
}
