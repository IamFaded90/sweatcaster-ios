import Foundation
import XCTest
@testable import SweatCaster

final class AgentRoomTests: XCTestCase {
    func testSavedRoomKeepsOriginalAndPublishedRevision() throws {
        let room = try decode()
        XCTAssertNoThrow(try room.validated())
        XCTAssertEqual(room.published?.revision, 1)
        XCTAssertEqual(room.current?.figures.first?.character, "eva")
        XCTAssertEqual(room.current?.figures.first?.scale, 1)
    }

    func testRoomRejectsExternalPathsUnknownActionsAndInvalidPlacement() throws {
        XCTAssertThrowsError(try decode(artwork: "../../shared/file").validated())
        XCTAssertThrowsError(try decode(x: 1.2).validated())
        XCTAssertThrowsError(try decode(scale: 1.7).validated())
        let validJSON = String(decoding: try JSONEncoder().encode(decode()), as: UTF8.self)
        let unknownAction = validJSON.replacingOccurrences(of: #""details""#, with: #""execute""#)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentRoom.self, from: Data(unknownAction.utf8)))
    }

    func testRoomIntentNeedsBothRoomAndCreationRequest() {
        XCTAssertTrue(AgentRoomIntent.matches("Byg et rum ud fra min skitse"))
        XCTAssertTrue(AgentRoomIntent.matches("Kan du indrette kontoret?"))
        XCTAssertTrue(AgentRoomIntent.matches("Create a room from this sketch"))
        XCTAssertFalse(AgentRoomIntent.matches("Hvor er botten i rummet?"))
        XCTAssertFalse(AgentRoomIntent.matches("Design en hjemmeside"))
        XCTAssertFalse(AgentRoomIntent.matches("Lav et forum om gaming"))
    }

    func testRoomCameraBoundsAndAllEightFiguresRemainInsideFrame() {
        XCTAssertEqual(AgentRoomCamera.zoom(.nan), 1)
        XCTAssertEqual(AgentRoomCamera.zoom(10), 3)
        let size = CGSize(width: 390, height: 292.5)
        XCTAssertEqual(AgentRoomCamera.pan(CGSize(width: 1000, height: -1000), zoom: 2, size: size),
                       CGSize(width: 195, height: -146.25))
        let point = AgentRoomCamera.point(CGPoint(x: 265, y: 160), zoom: 2,
                                          offset: CGSize(width: 70, height: 13.75), size: size)
        XCTAssertEqual(point.x, size.width / 2, accuracy: 0.001)
        XCTAssertEqual(point.y, size.height / 2, accuracy: 0.001)
        for y in [0.53, 0.83] {
            for x in [0.19, 0.40, 0.61, 0.82] {
                let figure = AgentRoom.Figure(id: UUID(), name: "Eva", character: "eva", x: x, y: y, scale: 1.65)
                let width = AgentRoomCamera.figureWidth(figure, size: size)
                let height = AgentRoomCamera.figureHeight(figure, size: size)
                let rect = CGRect(x: x * size.width - width / 2, y: y * size.height - height / 2,
                                  width: width, height: height)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
            }
        }
    }

    func testNamedRoomRevisionChangesOnlyTheRequestedFigureSize() throws {
        let room = try decode()
        let eva = try XCTUnwrap(room.current?.figures.first)
        let adam = AgentRoom.Figure(id: UUID(), name: "Adam", character: "adam", x: 0.4, y: 0.53, scale: 1.2)
        let figures = [eva, adam]
        guard case .adjustment(let adjustment) = AgentRoomRevisionIntent.resolve(
            "Gør Adam større og behold lyset", figures: figures
        ) else { return XCTFail("Expected a named relative-size adjustment") }
        XCTAssertEqual(adjustment.figureID, adam.id)
        XCTAssertEqual(adjustment.scale, 1.38, accuracy: 0.001)
        XCTAssertEqual(figures.first, eva)
        guard case .adjustment(let smaller) = AgentRoomRevisionIntent.resolve(
            "Gør Eva mindre og bevar baggrunden", figures: figures
        ) else { return XCTFail("Expected a smaller Eva") }
        XCTAssertEqual(smaller.figureID, eva.id)
        XCTAssertEqual(smaller.scale, 0.85, accuracy: 0.001)
        guard case .unsupported = AgentRoomRevisionIntent.resolve(
            "Gør Adam større og flyt stolen", figures: figures
        ) else { return XCTFail("Furniture changes must use the explicit fallback") }
        guard case .unsupported = AgentRoomRevisionIntent.resolve(
            "Gør Adam større", figures: figures + [adam]
        ) else { return XCTFail("Ambiguous names must use the explicit figure selector") }
    }

    private func decode(artwork: String = String(repeating: "a", count: 64),
                        x: Double = 0.19, scale: Double = 1) throws -> AgentRoom {
        let json = Self.payload
            .replacingOccurrences(of: "__DIGEST__", with: artwork)
            .replacingOccurrences(of: "__X__", with: String(x))
            .replacingOccurrences(of: "__SCALE__", with: String(scale))
        return try JSONDecoder().decode(AgentRoom.self, from: Data(json.utf8))
    }

    private static let payload = """
    {"id":"1a56aac1-73ce-4a39-9522-648ea8221f71","botID":"1b56aac1-73ce-4a39-9522-648ea8221f71",
     "title":"Arbejdsrummet","brief":"Et rum med borde","state":"published","created":1795000000,
     "revision":1,"publishedRevision":1,"notice":null,
     "versions":[{"revision":1,"instruction":"Min skitse","artwork":"__DIGEST__","width":1536,"height":1024,
       "figures":[{"id":"1b56aac1-73ce-4a39-9522-648ea8221f71","name":"Eva","character":"eva","x":__X__,"y":0.53,"scale":__SCALE__}],
       "hotspots":[{"id":"desk","title":"Arbejdsbord","x":0.5,"y":0.4,"w":0.2,"h":0.15,"action":"details","botID":null}],
       "checks":["Figurerne står inde i rummet"]}]}
    """
}
