/// Repeated positions let the viewport return to an identical middle copy at rest.
/// The route ID remains unchanged, so scrolling never opens a destination by itself.
enum NavigationWheelLoop {
    struct Position: Hashable, Identifiable, Sendable {
        let cycle: Int
        let itemID: String
        var id: Self { self }
    }

    private static let middle = 2
    private static let copies = 5

    static func positions(in ids: [String]) -> [Position] {
        (0..<(ids.count > 1 ? copies : 1)).flatMap { cycle in
            ids.map { Position(cycle: cycle, itemID: $0) }
        }
    }

    static func center(_ id: String, in ids: [String]) -> Position? {
        guard ids.contains(id) else { return nil }
        return Position(cycle: ids.count > 1 ? middle : 0, itemID: id)
    }

    static func recentered(_ position: Position?, in ids: [String]) -> Position? {
        guard let position else { return nil }
        return center(position.itemID, in: ids)
    }

    static func nearest(_ id: String, to reference: Position?, in ids: [String]) -> Position? {
        let rows = positions(in: ids)
        guard let target = center(id, in: ids) else { return nil }
        guard let reference, let origin = rows.firstIndex(of: reference) else { return target }
        return rows.enumerated().filter { $0.element.itemID == id }
            .min { abs($0.offset - origin) < abs($1.offset - origin) }?.element
    }

    static func step(from position: Position?, by offset: Int, in ids: [String]) -> Position? {
        let rows = positions(in: ids)
        guard let first = ids.first, let fallback = center(first, in: ids) else { return nil }
        let origin = position.flatMap { rows.firstIndex(of: $0) } ?? rows.firstIndex(of: fallback)!
        let index = (origin + offset % rows.count + rows.count) % rows.count
        return rows[index]
    }
}
