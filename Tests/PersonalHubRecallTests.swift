import XCTest
@testable import SweatCaster

final class PersonalHubRecallTests: XCTestCase {
    func testImageMusicQuestionUsesAnActualAssociation() {
        let one = PersonalHubRecall.Record(id: "image", kind: .image, title: "Billede af rød bil", text: "Hørte Sang A", relatedMusicID: "track")
        let unrelated = PersonalHubRecall.Record(id: "song", kind: .music, title: "Sang A", text: "rød bil")
        XCTAssertEqual(PersonalHubRecall.matches("Hvilken sang hørte vi da vi lavede billedet med rød bil?", records: [one, unrelated]).map(\.id), ["image"])
    }
    func testEphemeralContentAndOtherAgentAreExcluded() {
        let bot = UUID()
        let records: [PersonalHubRecall.Record] = [
            .init(id: "private", kind: .image, title: "Billede", text: "", ephemeral: true),
            .init(id: "other", kind: .conversation, title: "Billede", text: "", botID: UUID()),
            .init(id: "mine", kind: .conversation, title: "Billede", text: "", botID: bot)]
        XCTAssertEqual(PersonalHubRecall.matches("Billede", records: records, botID: bot).map(\.id), ["mine"])
    }
    func testListeningLinkPersistsAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalMediaLink.Store(file: root.appendingPathComponent("links.json"))
        let link = PersonalMediaLink(id: UUID(), botID: UUID(), imageName: "image.png", prompt: "Bil", musicID: "track", musicTitle: "Sang", musicArtist: "Kunstner", created: .now)
        try store.remember(link); XCTAssertEqual(try store.load(), [link]); try store.remove(link.id); XCTAssertTrue(try store.load().isEmpty)
    }
    func testMailQuestionBecomesSearchTermsWithoutInventingAnswers() {
        XCTAssertEqual(PersonalHubRecall.gmailQuery("Hvad aftalte jeg med tandlægen?"), "tandlæge")
        XCTAssertEqual(PersonalHubRecall.gmailQuery("from:clinic@example.com"), "from:clinic@example.com")
    }
}
