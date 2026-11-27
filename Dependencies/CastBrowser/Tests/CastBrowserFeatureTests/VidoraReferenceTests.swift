import XCTest
@testable import CastBrowserFeature

final class VidoraReferenceTests: XCTestCase {
    func testMovieLinkUsesBluePlayerAndDiscardsUntrustedParameters() throws {
        let item = try XCTUnwrap(VidoraReference(input: "https://www.themoviedb.org/movie/786892-furiosa?autoplay=true&fallback_url=https://other.test"))
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.playerURL.host, "vidora.ac")
        XCTAssertEqual(item.playerURL.path, "/movie/786892")
        let query = try XCTUnwrap(URLComponents(url: item.playerURL, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "primaryColor" }?.value, "4596FB")
        XCTAssertEqual(query.first { $0.name == "autoplay" }?.value, "false")
        XCTAssertFalse(query.contains { $0.name == "fallback_url" })
    }
    func testEpisodeLinksKeepSeasonAndEpisode() throws {
        for input in ["https://vidora.ac/tv/123/3/8", "https://www.themoviedb.org/tv/123-title/season/3/episode/8"] {
            let item = try XCTUnwrap(VidoraReference(input: input))
            XCTAssertEqual(item.playerURL.path, "/tv/123/3/8")
        }
    }
    func testPastedSeriesCanBeChangedBeforeOpening() throws {
        var item = try XCTUnwrap(VidoraReference(input: "https://vidora.ac/tv/123/3/8"))
        item.season = 4; item.episode = 2
        XCTAssertEqual(item.playerURL.path, "/tv/123/4/2")
    }
    func testRejectsUnexpectedOriginsAndInvalidIdentifiers() {
        for input in ["https://vidora.ac.evil.test/movie/5", "http://vidora.ac/movie/5", "https://user:pass@vidora.ac/movie/5",
                      "https://vidora.ac:443/movie/5", "https://vidora.ac/tv/5/0/8", "https://vidora.ac/tv/5/3",
                      "https://vidora.ac/movie/-5", "0", "99999999999999999999", "javascript:alert(1)"] {
            XCTAssertNil(VidoraReference(input: input), input)
        }
    }
}
