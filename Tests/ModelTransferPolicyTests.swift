import XCTest
@testable import SweatCaster

final class ModelTransferPolicyTests: XCTestCase {
    func testExpiredSignedLinkAndInvalidRangeRequireFreshLink() {
        for status in [401,403,416] { XCTAssertFalse(ModelTransferPolicy.keepResumeData(bytes: 100, status: status)) }
        XCTAssertTrue(ModelTransferPolicy.keepResumeData(bytes: 100, status: nil)); XCTAssertTrue(ModelTransferPolicy.keepResumeData(bytes: 100, status: 206))
        XCTAssertFalse(ModelTransferPolicy.keepResumeData(bytes: 0, status: nil)); XCTAssertFalse(ModelTransferPolicy.keepResumeData(bytes: 4_000_000, status: 200))
    }
    func testProgressCannotHideOverrunOrKeepOldPercentageAfterRestart() {
        XCTAssertEqual(ModelTransferPolicy.progress(written: 25, expected: 100), 0.25)
        XCTAssertEqual(ModelTransferPolicy.progress(written: 0, expected: 100), 0)
        XCTAssertNil(ModelTransferPolicy.progress(written: 101, expected: 100)); XCTAssertNil(ModelTransferPolicy.progress(written: -1, expected: 100)); XCTAssertNil(ModelTransferPolicy.progress(written: 1, expected: 0))
    }
}
