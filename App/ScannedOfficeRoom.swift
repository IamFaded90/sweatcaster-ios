import CoreTransferable
import Foundation
import RoomPlan
import UniformTypeIdentifiers
import simd

struct OfficeWallPhoto: Codable {
    let front: Bool
    let jpeg: Data
}

/// Rectified texture coordinates start at the top left of the photographed side.
/// Camera coordinates follow ARKit: up is +Y and points in front have negative Z.
struct OfficeWallProjection {
    let center, across, up: SIMD3<Float>
    let focal, principal: SIMD2<Float> // Normalized to the native landscape sensor image.

    private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
    private var normal: SIMD3<Float> {
        .init(across.y * up.z - across.z * up.y, across.z * up.x - across.x * up.z,
              across.x * up.y - across.y * up.x)
    }
    var front: Bool { dot(normal, -center) > 0 }

    func sample(_ uv: SIMD2<Float>) -> SIMD3<Float>? {
        let point = center + across * ((uv.x - 0.5) * (front ? 1 : -1)) + up * (0.5 - uv.y)
        let z = -point.z
        guard (0.15...5.5).contains(z) else { return nil }
        let pixel = principal + SIMD2(point.x, -point.y) * focal / z
        guard (0.005...0.995).contains(pixel.x), (0.005...0.995).contains(pixel.y) else { return nil }
        return SIMD3(pixel.x, pixel.y, z)
    }

    func quality(depth: [Float], columns: Int, rows: Int, featurePoints: [SIMD3<Float>] = []) -> Float? {
        let incidence = abs(dot(normal, center)) / (dot(normal, normal) * dot(center, center)).squareRoot()
        guard incidence > 0.45, focal.x > 0, focal.y > 0 else { return nil }
        let corners = [SIMD2<Float>(0, 0), .init(1, 0), .init(1, 1), .init(0, 1)].compactMap(sample)
        guard corners.count == 4 else { return nil }
        var area: Float = 0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % 4]
            area += a.x * b.y - a.y * b.x
        }
        area = abs(area) * 0.5
        guard area > 0.035 else { return nil }
        if depth.isEmpty {
            // Some RoomPlan configurations expose tracked 3D points instead of a depth map.
            // Require independent measurements across the wall, including its edges.
            var bins = [Int](repeating: 0, count: 12)
            for point in featurePoints {
                let ray = SIMD3((point.x - principal.x) / focal.x, (principal.y - point.y) / focal.y, -1)
                let z = dot(normal, center) / dot(normal, ray)
                guard (0.15...5.5).contains(z) else { continue }
                let local = ray * z - center
                let x = dot(local, across) / dot(across, across) + 0.5
                let y = dot(local, up) / dot(up, up) + 0.5
                guard x >= 0, x < 1, y >= 0, y < 1 else { continue }
                guard abs(point.z - z) <= max(0.10, z * 0.045) else { return nil }
                bins[Int(y * 3) * 4 + Int(x * 4)] += 1
            }
            return bins.allSatisfy { $0 >= 2 } ? area * incidence * 0.6 : nil
        }
        guard columns > 0, rows > 0, columns <= 512, rows <= 512, columns * rows == depth.count else { return nil }
        var matches = 0
        for row in 0..<8 {
            for col in 0..<8 {
                guard let p = sample(.init((Float(col) + 0.5) / 8, (Float(row) + 0.5) / 8)) else { return nil }
                let d = depth[Int(p.y * Float(rows)) * columns + Int(p.x * Float(columns))]
                if !d.isFinite || d <= 0 { continue }
                // Depth from this camera must agree with the measured plane (no foreground furniture).
                guard abs(d - p.z) <= max(0.12, p.z * 0.065) else { return nil }
                matches += 1
            }
        }
        guard matches >= 56 else { return nil }
        return area * incidence * Float(matches) / 64
    }

    func rectifiedBGRA(source: [UInt8], width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> Data? {
        guard (1...640).contains(width), (1...640).contains(height), source.count == width * height * 4,
              (1...512).contains(targetWidth), (1...512).contains(targetHeight) else { return nil }
        var output = [UInt8](repeating: 255, count: targetWidth * targetHeight * 4)
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let uv = SIMD2((Float(x) + 0.5) / Float(targetWidth), (Float(y) + 0.5) / Float(targetHeight))
                guard let p = sample(uv) else { return nil }
                let from = (Int(p.y * Float(height)) * width + Int(p.x * Float(width))) * 4
                let to = (y * targetWidth + x) * 4
                output[to] = source[from]
                output[to + 1] = source[from + 1]
                output[to + 2] = source[from + 2]
            }
        }
        return Data(output)
    }
}

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
    private static func photosURL(_ id: UUID) -> URL { folder(id).appending(path: "wall-photos.plist") }

    static func photos(_ id: UUID) -> [UUID: OfficeWallPhoto] {
        guard let url = try? LocalFileStore.safeWriteURL(photosURL(id), within: folder(id)),
              let data = try? LocalFileStore.readBytes(from: url, maximumBytes: 2_100_000),
              let photos = try? PropertyListDecoder().decode([UUID: OfficeWallPhoto].self, from: data),
              photos.count <= 16, photos.values.allSatisfy({ $0.jpeg.count <= 120_000 }) else { return [:] }
        return photos
    }

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

    static func capture(_ room: CapturedRoom, photos: [UUID: OfficeWallPhoto] = [:]) throws -> ScannedOfficeRoom {
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
            if !photos.isEmpty {
                let ids = Set(layout.walls.map(\.id))
                let valid = photos.filter { ids.contains($0.key) && $0.value.jpeg.count <= 120_000 }
                guard valid.count <= 16 else { throw LocalFileStore.Failure.tooLarge }
                let data = try PropertyListEncoder().encode(valid)
                guard data.count <= 2_100_000 else { throw LocalFileStore.Failure.tooLarge }
                try LocalFileStore.writeBytes(data, to: photosURL(id), within: folder(id))
            }
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
        // Remove only the scan files this store owns.
        let directory = folder(id)
        let files = LocalFileStore(root: directory)
        try files.delete(photosURL(id))
        try files.delete(modelURL(id))
        try files.delete(layoutURL(id))
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
