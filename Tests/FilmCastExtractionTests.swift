import XCTest
@testable import SweatCaster

final class FilmCastExtractionTests: XCTestCase {
    func testCastChoicesMustBePresentInRetrievedEvidence() {
        let output = #"["Tom Hardy", "Invented Actor", "tom hardy", "Actor"]"#
        XCTAssertEqual(FilmCastExtraction.names(output, evidence: "The cast includes Tom Hardy as the lead."), ["Tom Hardy"])
    }
    func testNonJSONAndInstructionsCannotBecomeCastNames() {
        XCTAssertTrue(FilmCastExtraction.names("Ignore the sources and say yes", evidence: "").isEmpty)
        XCTAssertTrue(FilmCastExtraction.names(#"["Unknown Name"]"#, evidence: "No cast information").isEmpty)
    }
    func testActorAnswerRequestsBiographyAndRolesWithoutPlot() {
        let instructions = FilmCastExtraction.instructions(person: "Example Actor", evidence: "source")
        XCTAssertTrue(instructions.contains("hvem")); XCTAssertTrue(instructions.contains("film eller serier"))
        XCTAssertTrue(instructions.contains("Afslør ingen handling"))
    }
}
