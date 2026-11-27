import XCTest
@testable import SweatCaster

final class SongProgressTests: XCTestCase {
    private let legacy = #"{"id":"12345678-1234-1234-1234-123456789abc","title":"Sang","prompt":"Jazz","lyrics":"","favorite":"","mode":"new","seconds":30,"instrumental":true,"state":"rendering","notice":"Arbejder","created":1}"#

    func testOlderPCAndSavedPhoneJobsStillDecode() throws {
        let job = try JSONDecoder().decode(SongJob.self, from: Data(legacy.utf8))
        XCTAssertNil(job.progress)
        XCTAssertEqual(job.progressStep, 2)
        XCTAssertFalse(job.finished)
    }
    func testReportedSavingStageHasItsOwnLabel() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
        object["progress"] = ["stage": "saving", "updated": 20, "lastChecked": 20]
        let job = try JSONDecoder().decode(SongJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(job.progressStep, 3)
        XCTAssertEqual(job.progressTitle, "Gør lyden klar")
        XCTAssertFalse(job.finished)
    }
    func testFailedJobDoesNotLookLikeItIsStillGenerating() throws {
        let data = legacy.replacingOccurrences(of: "rendering", with: "failed")
        let job = try JSONDecoder().decode(SongJob.self, from: Data(data.utf8))
        XCTAssertTrue(job.finished)
        XCTAssertEqual(job.progressTitle, "Sangen kunne ikke laves")
    }
}
