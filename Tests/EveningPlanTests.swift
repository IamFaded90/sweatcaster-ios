import XCTest
@testable import SweatCaster

final class EveningPlanTests: XCTestCase {
    func testOfflineNeverSuggestsWebOrTooLongMedia() {
        let pool: [EveningPlan.Candidate] = [
            .init(id: "web", kind: .film, title: "Film", detail: ""),
            .init(id: "long", kind: .music, title: "Lang", detail: "", seconds: 7_200, offline: true),
            .init(id: "song", kind: .music, title: "Chill", detail: "", seconds: 200, offline: true),
            .init(id: "village", kind: .village, title: "Agenter", detail: "", offline: true)]
        let result = EveningPlan.choices(pool, request: .init(minutes: 30, offlineOnly: true))
        XCTAssertEqual(result.map(\.id), ["song", "village"])
    }
    func testDiverseChoicesUseMoodAndDeduplicate() {
        let pool: [EveningPlan.Candidate] = [
            .init(id: "film", kind: .film, title: "En gemt film", detail: ""),
            .init(id: "pop", kind: .music, title: "Pop", detail: ""),
            .init(id: "chill", kind: .music, title: "Chill", detail: ""),
            .init(id: "chill", kind: .music, title: "Chill igen", detail: ""),
            .init(id: "village", kind: .village, title: "Agenter", detail: "", offline: true)]
        XCTAssertEqual(EveningPlan.choices(pool, request: .init()).map(\.id), ["film", "chill", "village"])
    }
    func testChatRequestPreservesTimeAndOfflineChoice() {
        let result = EveningPlan.Request.parse("Gør min aften god. Jeg har en halv time, helt offline")
        XCTAssertEqual(result?.minutes, 30)
        XCTAssertEqual(result?.offlineOnly, true)
        XCTAssertNil(EveningPlan.Request.parse("Hvad betyder aften?"))
        XCTAssertNil(EveningPlan.Request.parse("Lad være med at planlæg min aften"))
        XCTAssertNil(EveningPlan.Request.parse("Hvad betyder jeg keder mig?"))
    }
}
