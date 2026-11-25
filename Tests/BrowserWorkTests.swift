import XCTest
@testable import SweatCaster

final class BrowserWorkTests: XCTestCase {
    func testProofMustCiteActuallyObservedText() throws {
        let valid = #"{"verified":true,"reason":"Titlen og tiden er på siden.","quote":"Open daily 10 to 18"}"#
        XCTAssertTrue(try BrowserWork.Proof.decode(valid, observed: "Shop\nOpen daily 10 to 18\nContact").verified)
        XCTAssertThrowsError(try BrowserWork.Proof.decode(valid, observed: "Closed today"))
        XCTAssertThrowsError(try BrowserWork.Proof.decode(#"{"verified":true,"reason":"Done","quote":"OK"}"#, observed: "OK"))
    }
    func testProofRejectsBlankOrInventedEvidence() throws {
        let spaces = #"{"verified":true,"reason":"Fundet","quote":"        "}"#
        XCTAssertThrowsError(try BrowserWork.Proof.decode(spaces, observed: "Velkommen til butikken"))
        let invented = #"{"verified":false,"reason":"Siden er uklar","quote":"En opfundet åbningstid"}"#
        XCTAssertThrowsError(try BrowserWork.Proof.decode(invented, observed: "Butikken lukker klokken 18"))
        let blankReason = #"{"verified":true,"reason":"   ","quote":"Lukker klokken 18"}"#
        XCTAssertThrowsError(try BrowserWork.Proof.decode(blankReason, observed: "Lukker klokken 18"))
    }
    func testUnconfirmedResultStaysUnconfirmedInReceipt() throws {
        var record = BrowserWork.Record(); record.answer = "Jeg fandt et forslag."
        record.proof = try BrowserWork.Proof.decode(#"{"verified":false,"reason":"Åbningstiden mangler.","quote":""}"#, observed: "Shop")
        XCTAssertTrue(record.receipt.contains("Mangler bekræftelse")); XCTAssertFalse(record.receipt.contains("Kontrolleret mod siden"))
    }
    func testSourcesDropTokensAndCannotUseLocalFilesOrEmbeddedCredentials() {
        XCTAssertEqual(BrowserWork.sourceURL("https://example.com/page?token=secret#private")?.absoluteString, "https://example.com/page")
        XCTAssertNil(BrowserWork.sourceURL("file:///secret")); XCTAssertNil(BrowserWork.sourceURL("https://user:pass@example.com"))
        XCTAssertNil(BrowserWork.sourceURL("javascript:alert(1)"))
    }
    func testExplicitBrowserCommandsDoNotStealOrdinarySearchOrMail() {
        XCTAssertTrue(BrowserWork.command("Kan du bruge browseren til at finde en billet?"))
        XCTAssertTrue(BrowserWork.command("Gå ind på https://example.com og find åbningstiden"))
        XCTAssertFalse(BrowserWork.command("Læs min seneste Gmail")); XCTAssertFalse(BrowserWork.command("Hvad er en browser?"))
    }
}
