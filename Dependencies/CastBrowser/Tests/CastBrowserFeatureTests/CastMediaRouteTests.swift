import Foundation
import XCTest
@testable import CastBrowserFeature

final class CastMediaRouteTests: XCTestCase {
    func testCinejoyUsesPCBeforePhoneEvenFromAnEmbeddedPlayer() {
        let embed = URL(string: "https://film.example/embed")
        let site = URL(string: "https://www.cinejoy.pk/watch/42")
        XCTAssertEqual(CastMediaRoute.order(page: embed, browserPage: site, hasPC: true), [.pc, .direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: site, browserPage: nil, hasPC: true), [.pc, .direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: site, browserPage: nil, hasPC: false), [.direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: URL(string: "https://notcinejoy.pk"), browserPage: nil, hasPC: true),
                       [.direct, .pc, .phone])
    }

    func testReferringPageKeepsPlaybackPathOnly() {
        let embed = URL(string: "https://watch.example:443/embed/42?token=123#private")
        XCTAssertEqual(CastMediaRoute.referringPage(embed)?.absoluteString, "https://watch.example:443/embed/42")
        XCTAssertNil(CastMediaRoute.referringPage(URL(string: "https://person:secret@watch.example/film")))
        XCTAssertNil(CastMediaRoute.referringPage(URL(string: "data:text/html,film")))
    }
}
