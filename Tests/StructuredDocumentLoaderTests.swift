import XCTest
@testable import SweatCaster

final class StructuredDocumentLoaderTests: XCTestCase {
    func testDanishSemicolonCSVPreservesDecimalCommaAndQuotedSeparators() throws {
        let text = "Navn;Beløb;Note\r\nLars;12,50;\"Rød; grøn\"\r\nEva;20,00;\"Hun sagde \"\"hej\"\"\""
        let rows = try StructuredDocumentLoader.load(Data(text.utf8), type: "csv")
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(rows[1].location, "Række 2")
        XCTAssertTrue(rows[1].text.contains("12,50")); XCTAssertTrue(rows[1].text.contains("Rød; grøn")); XCTAssertTrue(rows[2].text.contains("Hun sagde \"hej\""))
    }
    func testQuotedNewlineDoesNotInventAnotherRecordAndBadQuotesFail() throws {
        let rows = try StructuredDocumentLoader.load(Data("name,note\na,\"line one\nline two\"\nb,plain".utf8), type: "csv")
        XCTAssertEqual(rows.count, 3); XCTAssertTrue(rows[1].text.contains("line one\nline two"))
        XCTAssertThrowsError(try StructuredDocumentLoader.load(Data("a,b\n1,\"unterminated".utf8), type: "csv"))
        XCTAssertThrowsError(try StructuredDocumentLoader.load(Data("a,b\n1,\"closed\"junk".utf8), type: "csv"))
        let spaced = try StructuredDocumentLoader.load(Data("name,note\n\na,value".utf8), type: "csv")
        XCTAssertEqual(spaced[1].location, "Række 3")
    }
    func testJSONKeepsSiblingFactsTogetherAndGivesUnambiguousPath() throws {
        let rows = try StructuredDocumentLoader.load(Data(#"{"orders":[{"person":"Lars","amount":12.5},{"person":"Eva","amount":20}],"a.b":{"enabled":true}}"#.utf8), type: "json")
        let lars = try XCTUnwrap(rows.first { $0.location == "JSON $.orders[0]" })
        XCTAssertTrue(lars.text.contains("Lars")); XCTAssertTrue(lars.text.contains("12.5")); XCTAssertFalse(lars.text.contains("Eva"))
        XCTAssertTrue(rows.contains { $0.location == #"JSON $["a.b"]"# && $0.text.contains("true") })
    }
    func testInvalidAndOversizeInputsAreRejectedBeforeIndexing() {
        XCTAssertThrowsError(try StructuredDocumentLoader.load(Data("{bad}".utf8), type: "json"))
        XCTAssertThrowsError(try StructuredDocumentLoader.load(Data(repeating: 65, count: 24_001), type: "csv"))
        XCTAssertThrowsError(try StructuredDocumentLoader.load(Data([255,254,0]), type: "csv"))
    }
}
