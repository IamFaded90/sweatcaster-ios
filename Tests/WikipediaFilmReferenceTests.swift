import XCTest
@testable import SweatCaster

final class WikipediaFilmReferenceTests: XCTestCase {
    func testCastSectionExtractsNamedAndSingleNameActorsWithoutRoles() {
        let source = """
        == Cast ==
        * [[Tom Hardy]] as [[Bane (DC Comics)|Bane]]
        * [[Zendaya]] as a character
        * [[Tom Hardy|Tom Hardy]] (additional credit)
        <ref>[[A different article]]</ref>
        """
        XCTAssertEqual(WikipediaFilmReference.castNames(source), ["Tom Hardy", "Zendaya"])
    }
    func testOrdinaryPlotParagraphDoesNotBecomeCast() {
        XCTAssertTrue(WikipediaFilmReference.castNames("The final scene includes [[Someone Else]].").isEmpty)
    }
    func testFilmographyCanFollowItsSeparateCreditsArticle() {
        XCTAssertEqual(WikipediaFilmReference.filmographyReference("{{Main|Tom Hardy filmography}}"), "Tom Hardy filmography")
        XCTAssertEqual(WikipediaFilmReference.filmographyReference("{{see also|List of awards}}\n{{main | Zendaya filmography }}"), "Zendaya filmography")
    }
    func testOnlyFilmographyArticlesAreFollowed() {
        XCTAssertNil(WikipediaFilmReference.filmographyReference("{{Main|Final scene}}"))
        XCTAssertNil(WikipediaFilmReference.filmographyReference("{{Main|File:Actor filmography}}"))
        XCTAssertNil(WikipediaFilmReference.filmographyReference("{{Main|Actor filmography#Plot}}"))
    }
}
