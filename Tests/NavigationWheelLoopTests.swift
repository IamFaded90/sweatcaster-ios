import XCTest
@testable import SweatCaster

final class NavigationWheelLoopTests: XCTestCase {
    private let ids = ["chat", "private", "home", "village", "film", "music"]

    func testEveryRepeatedRowHasUniqueIdentityButKeepsTheOriginalRoute() {
        let positions = NavigationWheelLoop.positions(in: ids)
        XCTAssertEqual(Set(positions).count, positions.count)
        XCTAssertEqual(Set(positions.map(\.itemID)), Set(ids))
        for cycle in Set(positions.map(\.cycle)) {
            XCTAssertEqual(positions.filter { $0.cycle == cycle }.map(\.itemID), ids)
        }
    }

    func testRepeatedForwardAndBackwardRotationsReachEveryDestination() {
        for direction in [-1, 1] {
            var position = NavigationWheelLoop.center(ids[0], in: ids)
            var seen = Set<String>()
            for step in 1...240 {
                position = NavigationWheelLoop.step(from: position, by: direction, in: ids)
                let expected = (step * direction % ids.count + ids.count) % ids.count
                XCTAssertEqual(position?.itemID, ids[expected])
                if let id = position?.itemID { seen.insert(id) }
                position = NavigationWheelLoop.recentered(position, in: ids)
            }
            XCTAssertEqual(seen, Set(ids))
        }
    }

    func testRestingRecenterPreservesTheRouteAcrossBothEnds() {
        for position in NavigationWheelLoop.positions(in: ids) {
            let middle = NavigationWheelLoop.recentered(position, in: ids)
            XCTAssertEqual(middle?.itemID, position.itemID)
            XCTAssertEqual(NavigationWheelLoop.recentered(middle, in: ids), middle)
        }
    }

    func testArrowDuringASwipeKeepsMovingFromTheVisibleCopy() {
        let positions = NavigationWheelLoop.positions(in: ids)
        for index in 1..<(positions.count - 1) {
            XCTAssertEqual(NavigationWheelLoop.step(from: positions[index], by: 1, in: ids), positions[index + 1])
            XCTAssertEqual(NavigationWheelLoop.step(from: positions[index], by: -1, in: ids), positions[index - 1])
        }
    }

    func testProgrammaticSelectionTakesTheShortPathAcrossTheSeam() throws {
        let last = try XCTUnwrap(NavigationWheelLoop.center(ids.last!, in: ids))
        let next = try XCTUnwrap(NavigationWheelLoop.nearest(ids[0], to: last, in: ids))
        XCTAssertEqual(next.cycle, last.cycle + 1)
        let first = try XCTUnwrap(NavigationWheelLoop.center(ids[0], in: ids))
        let previous = try XCTUnwrap(NavigationWheelLoop.nearest(ids.last!, to: first, in: ids))
        XCTAssertEqual(previous.cycle, first.cycle - 1)
    }

    func testEmptyAndSingleItemWheelsDoNotCreateInvalidPositions() {
        XCTAssertTrue(NavigationWheelLoop.positions(in: []).isEmpty)
        XCTAssertNil(NavigationWheelLoop.step(from: nil, by: 1, in: []))
        let rows = NavigationWheelLoop.positions(in: ["only"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(NavigationWheelLoop.step(from: nil, by: -1, in: ["only"]), rows.first)
    }

    func testRemovedDestinationsDoNotBecomeInvalidScrollTargets() {
        let removed = NavigationWheelLoop.center("music", in: ids)
        let remaining = ids.filter { $0 != "music" }
        XCTAssertNil(NavigationWheelLoop.recentered(removed, in: remaining))
        XCTAssertNil(NavigationWheelLoop.nearest("music", to: removed, in: remaining))
        XCTAssertEqual(NavigationWheelLoop.nearest("home", to: removed, in: remaining),
                       NavigationWheelLoop.center("home", in: remaining))
    }
}
