import CoreTransferable
import Foundation
import RoomPlan
import UniformTypeIdentifiers
import simd

struct ScannedOfficeRoom: Codable, Identifiable {
    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let width: Double
        let depth: Double
        let wall: Bool
        var botID: String? = nil
        var x: Double
        var z: Double
        var angle: Double
        var height: Double? = nil

        var displayHeight: Double {
            if botID != nil { return 1.2 }
            if let height, (0.04...12).contains(height) { return height }
            return wall ? 2.4 : 0.8
        }

        var span: (x: Double, z: Double) {
            let cosine = abs(cos(angle))
            let sine = abs(sin(angle))
            return (cosine * width + sine * depth, sine * width + cosine * depth)
        }
    }

    let id: UUID
    let createdAt: Date
    var items: [Item]

    var walls: [Item] { items.filter(\.wall) }

    var bounds: CGRect {
        let minimumX = walls.map { $0.x - $0.span.x / 2 }.min() ?? -2
        let maximumX = walls.map { $0.x + $0.span.x / 2 }.max() ?? 2
        let minimumZ = walls.map { $0.z - $0.span.z / 2 }.min() ?? -2
        let maximumZ = walls.map { $0.z + $0.span.z / 2 }.max() ?? 2
        return CGRect(x: minimumX, y: minimumZ, width: max(1, maximumX - minimumX),
                      height: max(1, maximumZ - minimumZ))
    }

    mutating func place(_ item: Item) {
        var placed = item
        let area = bounds
        let halfX = min(item.span.x / 2, Double(area.width) / 2)
        let halfZ = min(item.span.z / 2, Double(area.height) / 2)
        placed.x = min(max(item.x, Double(area.minX) + halfX), Double(area.maxX) - halfX)
        placed.z = min(max(item.z, Double(area.minY) + halfZ), Double(area.maxY) - halfZ)
        if let current = items.firstIndex(where: { $0.id == item.id }) { items[current] = placed }
        else { items.append(placed) }
    }

    static func layout(_ captured: CapturedRoom, id: UUID) -> Self {
        let wallItems = captured.walls.prefix(48).compactMap {
            measured(id: $0.identifier, type: "Væg", dimensions: $0.dimensions, transform: $0.transform, wall: true)
        }
        let objects = captured.objects.prefix(90).enumerated().compactMap { index, object in
            measured(id: object.identifier, type: furnitureName(String(describing: object.category), index: index),
                     dimensions: object.dimensions, transform: object.transform, wall: false)
        }
        return Self(id: id, createdAt: .now, items: wallItems + objects)
    }

    private static func measured(id: UUID, type: String, dimensions: SIMD3<Float>,
                                 transform: simd_float4x4, wall: Bool) -> Item? {
        let x = Double(transform.columns.3.x)
        let z = Double(transform.columns.3.z)
        let angle = atan2(Double(transform.columns.0.z), Double(transform.columns.0.x))
        let width = Double(dimensions.x)
        let depth = wall ? 0.08 : Double(dimensions.z)
        guard abs(x) < 150, abs(z) < 150, angle.isFinite, (0.04...60).contains(width), (0.04...60).contains(depth) else {
            return nil
        }
        let height = Double(dimensions.y)
        return Item(id: id, title: type, width: width, depth: depth, wall: wall, x: x, z: z, angle: angle,
                    height: (0.04...12).contains(height) ? height : nil)
    }

    private static func furnitureName(_ category: String, index: Int) -> String {
        switch category.lowercased().split(separator: "(").first {
        case "chair": "Stol"
        case "table": "Bord"
        case "sofa": "Sofa"
        case "bed": "Seng"
        case "storage": "Skab"
        case "television": "Fjernsyn"
        case "refrigerator": "Køleskab"
        case "stove": "Komfur"
        case "sink": "Vask"
        default: "Møbel \(index + 1)"
        }
    }
}

struct ScannedOfficePCExport: Encodable, Transferable {
    struct Item: Encodable {
        let title: String
        let x: Double
        let z: Double
        let width: Double
        let depth: Double
        let height: Double
        let angle: Double
        let wall: Bool
        let bot: Bool

        init(_ item: ScannedOfficeRoom.Item) {
            title = String(item.title.prefix(60))
            x = item.x
            z = item.z
            width = item.width
            depth = item.depth
            height = item.displayHeight
            angle = item.angle
            wall = item.wall
            bot = item.botID != nil
        }
    }

    let format = "fadedai-office"
    let version = 1
    let items: [Item]

    init(_ room: ScannedOfficeRoom) { items = room.items.map(Item.init) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { layout in try JSONEncoder().encode(layout) }
            .suggestedFileName("FadedAI-kontor.json")
    }
}

@MainActor enum ScannedOfficeStore {
    static let limit = 6
    private static var root: URL { URL.applicationSupportDirectory.appending(path: "OfficeRoomScans", directoryHint: .isDirectory) }
    private static var files: LocalFileStore { LocalFileStore(root: root, maximumBytes: 300_000) }

    private static func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory) }
    private static func layoutURL(_ id: UUID) -> URL { folder(id).appending(path: "layout.json") }
    static func modelURL(_ id: UUID) -> URL { folder(id).appending(path: "room.usdz") }

    static func rooms() throws -> [ScannedOfficeRoom] {
        do {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return entries.compactMap { entry in
                guard let id = UUID(uuidString: entry.lastPathComponent),
                      let room = try? files.read(ScannedOfficeRoom.self, from: layoutURL(id)),
                      room.id == id, room.items.count <= 150, !room.walls.isEmpty else { return nil }
                return room
            }.sorted { $0.createdAt > $1.createdAt }
        } catch let error where LocalFileStore.isMissing(error) {
            return []
        }
    }

    static func capture(_ room: CapturedRoom) throws -> ScannedOfficeRoom {
        guard try rooms().count < limit else { throw LocalFileStore.Failure.tooLarge }
        let id = UUID()
        let layout = ScannedOfficeRoom.layout(room, id: id)
        guard !layout.walls.isEmpty else { throw LocalFileStore.Failure.invalidFile }
        let manager = FileManager.default
        var directory = root
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try directory.setResourceValues(properties)
        try manager.createDirectory(at: folder(id), withIntermediateDirectories: false,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        do {
            let destination = try LocalFileStore.safeWriteURL(modelURL(id), within: root)
            try room.export(to: destination)
            try LocalFileStore.protectFile(destination)
            try save(layout)
            return layout
        } catch {
            try? remove(id)
            throw error
        }
    }

    static func save(_ room: ScannedOfficeRoom) throws {
        guard room.items.count <= 150 else { throw LocalFileStore.Failure.tooLarge }
        try files.write(room, to: layoutURL(room.id))
    }

    static func remove(_ id: UUID) throws {
        // Only remove the two files this store owns. Never follow links or recursively remove a directory.
        let directory = folder(id)
        try files.delete(modelURL(id))
        try files.delete(layoutURL(id))
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
