import XCTest
@testable import SweatCaster

final class AgentWorkReviewTests: XCTestCase {
    private func job() -> AgentWorkspace.Job { .init(id: UUID(), kind: .document, prompt: "Skriv om katten", created: Date()) }
    func testCompletedJournalCannotHideMissingOrEmptyArtifact() {
        var job = job(); job.state = .completed; job.fileID = job.id
        XCTAssertFalse(AgentWorkReview.assess(job, files: []).canReview)
        let empty = AgentWorkspace.File(id: job.id, name: "text", text: "", updated: Date())
        XCTAssertFalse(AgentWorkReview.assess(job, files: [empty]).canReview)
        let actual = AgentWorkspace.File(id: job.id, name: "text", text: "Katten sover", updated: Date())
        XCTAssertTrue(AgentWorkReview.assess(job, files: [actual]).canReview)
    }
    func testModelJudgmentRequiresAQuoteInTheActualReviewedData() throws {
        let job = job(), file = AgentWorkspace.File(id: UUID(), name: "kat", text: "Katten sover i solen.", updated: Date())
        let reply = #"{"summary":"Emnet er dækket","checks":[{"title":"Kat","status":"pass","source":"output","quote":"Katten sover","reason":"Resultatet omtaler katten"}]}"#
        let report = try AgentWorkReview.decode(reply, job: job, file: file, inputExcerpt: AgentWorkReview.input(job), outputExcerpt: file.text)
        XCTAssertTrue(AgentWorkReview.isCurrent(report, job: job, file: file)); XCTAssertFalse(report.excerptOnly)
        XCTAssertThrowsError(try AgentWorkReview.decode(reply.replacingOccurrences(of: "Katten sover", with: "Hunden løber"), job: job, file: file, inputExcerpt: AgentWorkReview.input(job), outputExcerpt: file.text))
    }
    func testChangedOutputOrInputInvalidatesPreviousReview() throws {
        var job = job(); job.inputSnapshot = "Original source"
        var file = AgentWorkspace.File(id: UUID(), name: "kat", text: "Katten sover i solen.", updated: Date())
        let reply = #"{"summary":"Mangler grundlag","checks":[{"title":"Kilde","status":"unknown","source":"input","quote":"","reason":"Kilden afgør ikke dette"}]}"#
        let report = try AgentWorkReview.decode(reply, job: job, file: file, inputExcerpt: "Original", outputExcerpt: "Katten")
        XCTAssertTrue(report.excerptOnly); file.text += " Changed"; XCTAssertFalse(AgentWorkReview.isCurrent(report, job: job, file: file))
        file.text = "Katten sover i solen."; job.inputSnapshot = "Different source"; XCTAssertFalse(AgentWorkReview.isCurrent(report, job: job, file: file))
    }
    func testOlderJobsDecodeWithoutNewReviewFieldsAndNoOpRecoveryDoesNotRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentWorkspace(botID: UUID(), root: root)
        let task = try store.enqueue("Write a note", kind: .document)
        let copy = try JSONDecoder().decode(AgentWorkspace.Job.self, from: JSONEncoder().encode(task))
        XCTAssertNil(copy.inputSnapshot); XCTAssertNil(copy.review)
        let file = root.appendingPathComponent(store.botID.uuidString.lowercased() + ".json")
        let old = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try store.recover()
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, old)
    }
}
