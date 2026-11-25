import XCTest
@testable import SweatCaster

final class MusicMixTests: XCTestCase {
    func testLikesAndRepeatedEarlySkipsChangeRealChoices() {
        let a = MusicTrack(id: "aaaaaaaaaaa", title: "Pop", artist: "A", duration: 100)
        let b = MusicTrack(id: "bbbbbbbbbbb", title: "Pop", artist: "B", duration: 100)
        var feedback = MusicMix.Feedback()
        feedback.favorite(b.id, selected: true)
        feedback.skip(a.id, position: 10, duration: 100)
        XCTAssertEqual(MusicMix.tracks([a, a, b], mood: .fun, feedback: feedback).map(\.id), [b.id, a.id])
        feedback.skip(b.id, position: 90, duration: 100)
        XCTAssertNil(feedback.skips[b.id])
    }
    func testFeedbackPersistsOnlyInSelectedStore() throws {
        let suite = "MusicMixTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        MusicMix.update(defaults: defaults) { $0.favorite("track", selected: true) }
        XCTAssertEqual(MusicMix.feedback(defaults: defaults).likes, ["track"])
    }
    func testExplicitMusicCommandDoesNotCatchOtherConversation() {
        XCTAssertTrue(MusicMix.command("Lav et musikmix"))
        XCTAssertTrue(MusicMix.command("Start noget rolig musik"))
        XCTAssertFalse(MusicMix.command("Jeg vil ikke starte musik"))
    }
}
