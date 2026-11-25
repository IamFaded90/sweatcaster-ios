import XCTest
@testable import SweatCaster

final class RoomWorksTests: XCTestCase {
    func testPlacementSurvivesRelaunchAndScenesStaySeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomWorks.Store(root: root)
        var room = RoomWorks.Layout()
        try room.add(source: .init(kind: .song, key: "faded-song-" + UUID().uuidString), title: "Min sang")
        let id = try XCTUnwrap(room.items.first?.id)
        try room.move(id, x: 0.64, y: 0.3); try store.save(room, scene: "zone-cafe")
        XCTAssertEqual(try RoomWorks.Store(root: root).load("zone-cafe"), room)
        XCTAssertTrue(try store.load("zone-sleep").items.isEmpty)
    }
    func testRemoveUndoAndMoveOnlyChangeReferences() throws {
        var room = RoomWorks.Layout()
        let source = RoomWorks.Source(kind: .project, key: UUID().uuidString)
        try room.add(source: source, title: "Invitation")
        let id = try XCTUnwrap(room.items.first?.id)
        try room.move(id, x: -9, y: 99)
        XCTAssertEqual(room.items.first?.x, 0.08); XCTAssertEqual(room.items.first?.y, 0.88)
        room.remove(id); XCTAssertTrue(room.items.isEmpty)
        room.undo(); XCTAssertEqual(room.items.first?.source, source)
        XCTAssertThrowsError(try room.move(id, x: .nan, y: 0))
    }
    func testBadSourcesDuplicatesAndOverflowAreRejected() throws {
        for source in [RoomWorks.Source(kind: .image, key: "../../photo.png"), .init(kind: .project, key: "bad"), .init(kind: .song, key: "file:///secret")] {
            var room = RoomWorks.Layout(); XCTAssertThrowsError(try room.add(source: source, title: "A"))
        }
        var room = RoomWorks.Layout()
        for i in 0..<12 { try room.add(source: .init(kind: .project, key: UUID().uuidString), title: "Projekt \(i)") }
        XCTAssertThrowsError(try room.add(source: room.items[0].source, title: "Igen"))
        XCTAssertThrowsError(try room.add(source: .init(kind: .project, key: UUID().uuidString), title: "For mange"))
        XCTAssertTrue(room.valid)
    }
    func testInvalidSceneCannotEscapeStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RoomWorks.Store(root: root)
        for scene in ["", "../escape", "/tmp/test", String(repeating: "a", count: 121)] { XCTAssertThrowsError(try store.save(.init(), scene: scene)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
