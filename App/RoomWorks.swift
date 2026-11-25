import Foundation

/// References to saved work. Removing a placement never removes the original work.
enum RoomWorks {
    enum Kind: String, Codable, CaseIterable { case song, image, project }
    struct Source: Codable, Hashable {
        let kind: Kind
        let key: String
        var valid: Bool {
            switch kind {
            case .song: key.hasPrefix("faded-song-") && UUID(uuidString: String(key.dropFirst(11))) != nil
            case .project: UUID(uuidString: key) != nil
            case .image: key.range(of: #"^[0-9]{1,20}-[0-9a-fA-F-]{36}\.png$"#, options: .regularExpression) != nil
            }
        }
    }
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        let source: Source
        var title: String
        var x: Double
        var y: Double
        var valid: Bool { source.valid && !title.isEmpty && title.count <= 120 && x.isFinite && y.isFinite && (0.08...0.92).contains(x) && (0.12...0.88).contains(y) }
        mutating func move(x: Double, y: Double) throws {
            guard x.isFinite, y.isFinite else { throw Failure.invalid }
            self.x = min(0.92, max(0.08, x)); self.y = min(0.88, max(0.12, y))
        }
    }
    struct Layout: Codable, Equatable {
        var items: [Item] = []
        var previous: [Item]?
        mutating func add(source: Source, title: String) throws {
            guard source.valid, !items.contains(where: { $0.source == source }), items.count < 12 else { throw Failure.invalid }
            let column = items.count % 4, row = items.count / 4
            let item = Item(source: source, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                            x: 0.17 + Double(column) * 0.22, y: 0.26 + Double(row) * 0.25)
            guard item.valid else { throw Failure.invalid }
            previous = items; items.append(item)
        }
        mutating func move(_ id: UUID, x: Double, y: Double) throws {
            guard let index = items.firstIndex(where: { $0.id == id }) else { throw Failure.invalid }
            var moved = items[index]; try moved.move(x: x, y: y)
            previous = items; items[index] = moved
        }
        mutating func remove(_ id: UUID) {
            guard items.contains(where: { $0.id == id }) else { return }
            previous = items; items.removeAll { $0.id == id }
        }
        mutating func undo() { guard let previous else { return }; let current = items; items = previous; self.previous = current }
        var valid: Bool {
            Self.validItems(items) && (previous.map(Self.validItems) ?? true)
        }
        private static func validItems(_ values: [Item]) -> Bool {
            values.count <= 12 && values.allSatisfy(\.valid) && Set(values.map(\.id)).count == values.count && Set(values.map(\.source)).count == values.count
        }
    }
    enum Failure: LocalizedError {
        case invalid, missing
        var errorDescription: String? { switch self {
        case .invalid: "Genstanden kunne ikke placeres. Vælg et gemt værk, højst én gang og højst 12 i rummet."
        case .missing: "Originalen er flyttet eller slettet. Du kan fjerne genstanden fra rummet eller vælge et andet værk."
        } }
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/RoomWorks", isDirectory: true)
        private func file(_ scene: String) throws -> URL {
            guard (1...120).contains(scene.utf8.count), scene.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { throw Failure.invalid }
            let encoded = Data(scene.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            let file = root.appendingPathComponent(encoded + ".json").standardizedFileURL
            guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure.invalid }
            return file
        }
        func load(_ scene: String) throws -> Layout {
            let file = try file(scene)
            guard FileManager.default.fileExists(atPath: file.path) else { return Layout() }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 40_000 else { throw Failure.invalid }
            let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: file))
            guard layout.valid else { throw Failure.invalid }; return layout
        }
        func save(_ layout: Layout, scene: String) throws {
            guard layout.valid else { throw Failure.invalid }
            let file = try file(scene)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(layout).write(to: file, options: .atomic)
        }
    }
}
