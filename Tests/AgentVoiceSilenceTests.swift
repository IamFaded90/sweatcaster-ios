import XCTest
@testable import SweatCaster

final class AgentVoiceSilenceTests: XCTestCase {
    func testDoesNotSubmitSilenceOrAnIsolatedNoise() {
        var detector = AgentVoiceSilence(pause: 2)
        XCTAssertFalse(detector.ended(at: 0, level: -70)); XCTAssertFalse(detector.ended(at: 1, level: -15)); XCTAssertFalse(detector.ended(at: 5, level: -70))
        for time in [6.0, 6.12, 6.24] { XCTAssertFalse(detector.ended(at: time, level: -28)) }
        XCTAssertFalse(detector.ended(at: 8, level: -70)); XCTAssertTrue(detector.ended(at: 8.25, level: -70))
    }
    func testInvalidMeterAndClockResetCannotTriggerAFalseTurn() {
        var detector = AgentVoiceSilence(pause: 2)
        for time in [10.0,10.12,10.24] { _ = detector.ended(at: time, level: -20) }
        XCTAssertFalse(detector.ended(at: .infinity, level: -80)); XCTAssertFalse(detector.ended(at: 20, level: .nan))
        XCTAssertFalse(detector.ended(at: 1, level: -80)); XCTAssertFalse(detector.ended(at: 30, level: -80))
    }
    func testPauseSettingsStayBounded() { XCTAssertEqual(AgentVoiceSilence(pause: 0).pause, 1.4); XCTAssertEqual(AgentVoiceSilence(pause: 100).pause, 4); XCTAssertEqual(AgentVoiceSilence(pause: .nan).pause, 2.5) }
}
