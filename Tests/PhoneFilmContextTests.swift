import XCTest
@testable import SweatCaster

final class PhoneFilmContextTests: XCTestCase {
    func testRewindFilmSwitchAndMissingReceiverInvalidateAnswer() {
        let clip = PhoneFilmContext(id: "one", title: "Film", position: 90)
        XCTAssertTrue(clip.stillApplies(to: .init(id: "one", title: "Film", position: 110)))
        XCTAssertFalse(clip.stillApplies(to: .init(id: "one", title: "Film", position: 50)))
        XCTAssertFalse(clip.stillApplies(to: .init(id: "two", title: "Film", position: 110)))
        XCTAssertFalse(clip.stillApplies(to: nil))
    }
    func testTranscriptContextIsBoundedAndDoesNotAuthorizeTools() {
        let prompt = PhoneFilmContext.instructions(transcript: String(repeating: "x", count: 50_000), question: "Forklar")
        XCTAssertLessThan(prompt.count, 4_000)
        XCTAssertTrue(prompt.contains("aldrig"))
        XCTAssertTrue(prompt.contains("senere scener"))
        XCTAssertTrue(prompt.contains("oversæt kun"))
    }
    func testRecapNeverIncludesFutureClipsOrOtherFilms() throws {
        let suite = "FilmHistoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        PhoneFilmHistory.remember("Tidlig scene", context: .init(id: "one", title: "", position: 20), defaults: defaults)
        PhoneFilmHistory.remember("Sen afsløring", context: .init(id: "one", title: "", position: 200), defaults: defaults)
        PhoneFilmHistory.remember("Anden film", context: .init(id: "two", title: "", position: 10), defaults: defaults)
        let text = PhoneFilmHistory.seen(through: .init(id: "one", title: "", position: 50), defaults: defaults)
        XCTAssertTrue(text.contains("Tidlig scene")); XCTAssertFalse(text.contains("Sen afsløring")); XCTAssertFalse(text.contains("Anden film"))
    }
}
