import XCTest
@testable import SweatCaster

final class MusicPlaybackSnapshotTests: XCTestCase {
    func testQueueAndPositionSurviveWithoutAutoplayFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("player.json")
        let value = MusicPlaybackSnapshot(queue: [.init(id: "abcdefghijk", title: "Sang", artist: "Kunstner", duration: 200)], index: 0, position: 42, repeats: true)
        try value.save(to: file)
        XCTAssertEqual(try MusicPlaybackSnapshot.load(from: file), value)
        XCTAssertEqual(value.resumePosition, 42)
    }
    func testBadIndexPathAndNonfinitePositionsAreRejected() {
        let track = MusicTrack(id: "../../music", title: "", artist: "")
        XCTAssertFalse(MusicPlaybackSnapshot(queue: [track], index: 0, position: 0, repeats: false).valid)
        XCTAssertFalse(MusicPlaybackSnapshot(queue: [], index: 8, position: .infinity, repeats: false).valid)
    }
    func testResumeIsClampedBeforeEnd() {
        let track = MusicTrack(id: "abcdefghijk", title: "", artist: "", duration: 20)
        XCTAssertEqual(MusicPlaybackSnapshot(queue: [track], index: 0, position: 25, repeats: false).resumePosition, 19)
    }
}
