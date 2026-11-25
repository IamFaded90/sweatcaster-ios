import XCTest
@testable import SweatCaster

final class DocumentLocationTests: XCTestCase {
    func testLegacyPassagesAndSourcesStillDecode() throws {
        let passage = try JSONDecoder().decode(AgentDocument.Passage.self, from: Data(#"{"page":2,"text":"hello"}"#.utf8))
        let source = try JSONDecoder().decode(AgentDocumentSource.self, from: Data(#"{"id":1,"name":"Brev","page":2}"#.utf8))
        XCTAssertNil(passage.location); XCTAssertNil(source.location)
        XCTAssertEqual(source.citation, "Brev, side 2")
    }
    func testDifferentRowsCannotSupplyEachOthersDeadline() {
        let doc = AgentDocument(id: UUID(), name: "liste.csv", model: nil, passages: [
            .init(page: nil, text: "Frist:", vector: nil, location: "Række 2"),
            .init(page: nil, text: "2031-12-01", vector: nil, location: "Række 3"),
            .init(page: nil, text: "Svarfrist: 2031-12-05", vector: nil, location: "Række 4")
        ])
        let hits = AgentDocumentDeadline.sources(in: doc)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.citation, "liste.csv, Række 4")
        XCTAssertEqual(hits.first?.deadline?.day, "2031-12-05")
    }
}
