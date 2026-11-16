import XCTest
@testable import SweatCaster

final class PhoneMemoryBudgetTests: XCTestCase {
    func testOtherAppsCanReduceBudgetEvenOnLargePhone() {
        let result = PhoneMemoryBudget.assess(required: 3_000_000_000, physical: 12_000_000_000, available: 2_000_000_000)
        XCTAssertEqual(result.fit, .unavailable)
        XCTAssertEqual(result.recommendedBytes, 2_000_000_000)
    }

    func testConservativeEstimateDoesNotBlockOtherwiseLoadableModel() {
        let result = PhoneMemoryBudget.assess(required: 8_000_000_000, physical: 12_000_000_000, available: 9_000_000_000)
        XCTAssertEqual(result.fit, .tight)
    }

    func testSmallModelAndUnknownMemory() {
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1_000_000_000, physical: 8_000_000_000, available: 5_000_000_000).fit, .comfortable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1, physical: 0, available: 0).fit, .unavailable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 0, physical: 8_000_000_000, available: 5_000_000_000).fit, .unavailable)
    }
}
