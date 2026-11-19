import Foundation
import XCTest
@testable import CastBrowserFeature

final class FilmDialogueTests: XCTestCase {
    private let subtitles = """
        WEBVTT

        NOTE Nora is the queen in the finale

        01
        00:00:01.000 --> 00:00:03.000 align:start
        <v Nora>Hvor kender vi Jonas fra?

        02
        00:00:03.000 --> 00:00:05.000
        Fra skolen.

        03
        00:00:05.000 --> 00:00:08.000
        Nora overtager tronen.
        """

    func testCompletedCueBoundaryAndSearchContext() throws {
        let cues = try FilmDialogue.completed(in: subtitles, through: 5)
        XCTAssertEqual(cues.map(\.text), ["Nora: Hvor kender vi Jonas fra?", "Fra skolen."])
        let relevant = FilmDialogue.evidence(cues, for: "Hvor kender vi Jonas fra?")
        XCTAssertEqual(relevant, cues)
        XCTAssertEqual(FilmDialogue.excerpt(relevant, for: "Hvor kender vi Jonas fra?"), cues)
        XCTAssertEqual(FilmDialogue.selected("2", from: relevant).first?.text, "Fra skolen.")
        XCTAssertEqual(try FilmDialogue.completed(in: subtitles, through: 2.999), [])
        XCTAssertEqual(try FilmDialogue.completed(in: subtitles, through: 7.999), cues)
        XCTAssertEqual(try FilmDialogue.completed(in: subtitles, through: 8).count, 3)
    }

    func testCurrentMovieRequiredEvenWithIdenticalTitle() {
        let session = NSObject()
        func frame(_ media: Int, _ seconds: Double) -> FilmReceiverFrame {
            .init(source: .init(session: ObjectIdentifier(session), mediaID: media, itemID: 1, title: "Samme titel",
                                contentID: "film", subtitles: nil), position: seconds)
        }
        XCTAssertTrue(frame(5, 15).stillApplies(to: frame(5, 16)))
        XCTAssertFalse(frame(5, 15).stillApplies(to: frame(5, 7)))
        XCTAssertFalse(frame(5, 15).stillApplies(to: frame(6, 30)))
        XCTAssertFalse(frame(5, 15).stillApplies(to: nil))
    }

    func testOpaqueTimingAndMalformedBlocksFailClosed() {
        XCTAssertThrowsError(try FilmDialogue.completed(in: "X-TIMESTAMP-MAP=LOCAL:00:00:00.000\n" + subtitles, through: 9))
        XCTAssertThrowsError(try FilmDialogue.completed(in: "<html>not subtitles</html>", through: 9))
        XCTAssertThrowsError(try FilmDialogue.completed(in: "00:02.000 --> 00:03.000\nHej\n00:12.000 --> 00:13.000\nSenere.", through: 5))
        XCTAssertThrowsError(try FilmDialogue.completed(in: "00:61.000 --> 00:03.000\nInvalid.", through: 70))
    }

    func testSRTAndRecentDialogueWindow() throws {
        let source = "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>Hej!</i>\r\n"
        let cues = try FilmDialogue.completed(in: source, through: 3)
        XCTAssertEqual(FilmDialogue.recent(cues, at: 122).first?.text, "Hej!")
        XCTAssertTrue(FilmDialogue.recent(cues, at: 123).isEmpty)
        XCTAssertTrue(FilmDialogue.recent(cues, at: 1).isEmpty)
    }

    func testUnconfirmedOrAmbiguousQuestionsAndUntrustedModelWords() throws {
        let cues = try FilmDialogue.completed(in: subtitles, through: 5)
        XCTAssertTrue(FilmDialogue.keywords("Hvor kender hovedpersonen ham fra?").isEmpty)
        XCTAssertTrue(FilmDialogue.isRecap("Hvad blev der lige sagt?"))
        XCTAssertFalse(FilmDialogue.isRecap("Hvad sagde Nora?"))
        XCTAssertTrue(FilmDialogue.evidence(cues, for: "Hvem er Harry?").isEmpty)
        for invalid in ["0", "-1", "99", "2: from work", "1,2,3,4", "Her er svaret"] {
            XCTAssertTrue(FilmDialogue.selected(invalid, from: cues).isEmpty)
        }
    }

    func testOnlyExplicitPauseAndKnownSceneQuestions() {
        XCTAssertTrue(FilmDialogue.isPauseRequest("Sæt filmen på pause."))
        XCTAssertFalse(FilmDialogue.isPauseRequest("Sæt ikke filmen på pause"))
        XCTAssertFalse(FilmDialogue.isPauseRequest("Hvad sker der efter pausen?"))
        XCTAssertTrue(FilmDialogue.isSceneQuestion("Hvorfor er hun vred?"))
    }

    func testValidatesActualTimeOnDecodedPCReply() throws {
        let json = #"{"detail":"PC","answer":"I skolen.","cues":[{"start":1,"end":3,"text":"At school."},{"start":2,"end":8,"text":"Later."}]}"#
        let response = try JSONDecoder().decode(CastFilmResult.self, from: Data(json.utf8))
        XCTAssertEqual(response.answer, "I skolen.")
        XCTAssertEqual(response.completed(through: 5).map(\.text), ["At school."])
        XCTAssertNotEqual(response.completed(through: 5).count, response.cues.count)
    }
}
