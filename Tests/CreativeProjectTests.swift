import XCTest
@testable import SweatCaster

final class CreativeProjectTests: XCTestCase {
    func testDraftIsStructuredAndRejectsBrokenModelOutput() throws {
        let valid = #"{"title":"Filmaften","text":"Fredag [udfyld]","imagePrompt":"A cozy cinema"}"#
        XCTAssertEqual(try CreativeProject.draft(valid).title, "Filmaften")
        XCTAssertThrowsError(try CreativeProject.draft("Bare et svar uden billedbeskrivelse"))
        XCTAssertThrowsError(try CreativeProject.draft(#"{"title":"A","text":"B","imagePrompt":""}"#))
    }
    func testProjectAndListeningContextPersistPerOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreativeProject.Store(root: root); let bot = UUID()
        var project = CreativeProject(botID: bot); project.title = "Plakat"; project.musicID = "track"; project.musicTitle = "Min sang"
        try store.save(project); XCTAssertEqual(try store.list(botID: bot), [project]); XCTAssertTrue(try store.list(botID: UUID()).isEmpty)
        XCTAssertNil(store.asset(project.id, name: "../../secret"))
        try store.remove(project.id); XCTAssertTrue(try store.list().isEmpty)
    }
}
