import XCTest
@testable import SweatCaster

final class CameraGuideTests: XCTestCase {
    func testPromptFitsPCPhotoContractEvenWithLongUnicodeInputs() throws {
        let long = String(repeating: "👩🏽‍💻 meget lang historik ", count: 1000)
        let box = try CameraGuide.Box.corners([0, 0, 100, 100])
        let prompt = CameraGuide.prompt(question: long, context: long, anchors: [.init(text: long, box: box)])
        XCTAssertLessThanOrEqual(prompt.unicodeScalars.count, 1800)
        XCTAssertTrue(prompt.contains("Spørgsmål:"))
    }
    private func answer(_ marks: String) -> String { #"{"answer":"Tryk på knappen nederst.","marks":MARKS}"#.replacingOccurrences(of: "MARKS", with: marks) }
    func testAnchorUsesExactVisibleTextAndRejectsMissingAnchor() throws {
        let box = try CameraGuide.Box.corners([700, 750, 940, 900])
        let anchors = [CameraGuide.Anchor(text: "Send", box: box)]
        let raw = answer(#"[{"label":"Send-knappen","anchor":1}]"#)
        let result = try CameraGuide.decode(raw, photoID: UUID(), question: "Send?", source: "iPhone", model: "Test", anchors: anchors)
        XCTAssertEqual(result.marks.first?.box, box); XCTAssertEqual(result.marks.first?.label, "Send")
        XCTAssertEqual(result.marks.first?.origin, .text)
        XCTAssertTrue(try CameraGuide.decode(raw, photoID: UUID(), question: "?", source: "iPhone", model: "Test", anchors: []).marks.isEmpty)
        let malformed = answer(#"[{"label":"Send-knap","box":[[400,600,900,999]]}]"#)
        XCTAssertEqual(try CameraGuide.decode(malformed, photoID: UUID(), question: "?", source: "iPhone", model: "Test", anchors: anchors).marks.first?.box, box)
        XCTAssertTrue(try CameraGuide.decode(malformed, photoID: UUID(), question: "?", source: "iPhone", model: "Test", anchors: []).marks.isEmpty)
    }
    func testVisionCoordinatesAndScreenOrientationAreConvertedToTopLeft() throws {
        let box = try CameraGuide.Box.vision(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        XCTAssertEqual(box.y, 0.8, accuracy: 0.000001)
        let corners = try CameraGuide.Box.corners([100, 800, 300, 900])
        XCTAssertEqual(corners.x, box.x); XCTAssertEqual(corners.y, box.y, accuracy: 0.000001)
        XCTAssertThrowsError(try CameraGuide.Box.corners([900, 0, 100, 100]))
        XCTAssertThrowsError(try CameraGuide.Box.corners([0, 0, 1_100, 900]))
        XCTAssertThrowsError(try CameraGuide.Box(x: .nan, y: 0, width: 0.2, height: 0.2))
    }
    func testExactTextAnchorOverridesGuessedModelPosition() throws {
        let box = try CameraGuide.Box(x: 0.6, y: 0.8, width: 0.2, height: 0.1)
        let result = try CameraGuide.decode(answer(#"[{"label":"SEND","box":[100,100,200,200]}]"#), photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: [.init(text: "Send", box: box)])
        XCTAssertEqual(result.marks.first?.box, box); XCTAssertEqual(result.marks.first?.origin, .text)
    }
    func testDuplicateTextIsNotArbitrarilyMappedToFirstButton() throws {
        let first = try CameraGuide.Box(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let second = try CameraGuide.Box(x: 0.6, y: 0.8, width: 0.2, height: 0.1)
        let anchors = [CameraGuide.Anchor(text: "Send", box: first), .init(text: "Send", box: second)]
        let result = try CameraGuide.decode(answer(#"[{"label":"Send","box":[600,800,800,900]}]"#), photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: anchors)
        XCTAssertEqual(result.marks.first?.box, second)
        let ambiguous = try CameraGuide.decode(answer(#"[{"label":"Send","box":[300,300,400,400]}]"#), photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: anchors)
        XCTAssertEqual(ambiguous.marks.first?.origin, .model)
    }
    func testInvalidMarksAreDroppedAndMalformedResponseNeverInventsTargets() throws {
        let result = try CameraGuide.decode(answer(#"[{"label":"Send","box":[0,0,9999,9999]}]"#), photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: [])
        XCTAssertTrue(result.marks.isEmpty)
        XCTAssertThrowsError(try CameraGuide.decode("Tryk her: {\"tool\":\"delete\"}", photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: []))
        let none = try CameraGuide.decode("```json\n" + answer("[]") + "\n```", photoID: UUID(), question: "Hvor?", source: "iPhone", model: "Test", anchors: [])
        XCTAssertTrue(none.marks.isEmpty)
        XCTAssertTrue(try CameraGuide.decode("```json\r\n" + answer("[]") + "\r\n```", photoID: UUID(), question: "?", source: "iPhone", model: "Test", anchors: []).marks.isEmpty)
    }
    func testNewPhotoCannotShowOldMarksAndStaleResponseCannotBeAppended() throws {
        var session = CameraGuide.Session()
        let result = try CameraGuide.decode(answer("[]"), photoID: session.photoID, question: "Første", source: "iPhone", model: "Test", anchors: [])
        try session.append(result); XCTAssertNotNil(session.current)
        session.replacePhoto(); XCTAssertNil(session.current); XCTAssertTrue(session.context.contains("Første"))
        XCTAssertThrowsError(try session.append(result))
        session.remove(result.id); XCTAssertTrue(session.context.isEmpty)
    }
    func testNewQuestionHidesOldAnswerButKeepsItInHistory() throws {
        var session = CameraGuide.Session()
        let old = try CameraGuide.decode(answer("[]"), photoID: session.photoID, question: "Første", source: "iPhone", model: "Test", anchors: [])
        try session.append(old)
        session.beginAttempt()
        XCTAssertNil(session.current)
        XCTAssertEqual(session.steps.map(\.id), [old.id])
        XCTAssertTrue(session.context.contains("Første"))
        XCTAssertThrowsError(try session.append(old))
    }
    func testManualMarkCannotBeMovedOffPhoto() throws {
        let box = try CameraGuide.Box(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let moved = try box.moved(centerX: 2, centerY: -1)
        XCTAssertEqual(moved.x, 0.7, accuracy: 0.000001); XCTAssertEqual(moved.y, 0)
        XCTAssertTrue(CameraGuide.command("Kan du vise mig hvor jeg skal trykke?"))
        XCTAssertFalse(CameraGuide.command("Lav et billede af en lampe"))
    }
}
