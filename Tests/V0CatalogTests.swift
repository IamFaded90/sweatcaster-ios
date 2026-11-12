import XCTest
@testable import SweatCaster

final class V0CatalogTests: XCTestCase {
    func testPurchasedAtlasAndLookbookInventory() {
        XCTAssertEqual(V0FeatureAtlasData.entries.map(\.id), Array(1...100))
        XCTAssertEqual(Set(V0LookPreset.all.map(\.id)).count, 50)
        XCTAssertEqual(Set(V0LocalTool.all.map(\.id)).count, 50)
        XCTAssertEqual(Set(V0HubShortcut.entries.map(\.id)).count, 50)
    }

    func testLocalToolsKeepDanishTextAndRejectInvalidInput() throws {
        let encoder = try XCTUnwrap(V0LocalTool.all.first { $0.id == "base64encode" })
        let decoder = try XCTUnwrap(V0LocalTool.all.first { $0.id == "base64decode" })
        let input = "Grønne æbler og blåbær"
        let encoded = try encoder.run(["input": input])
        XCTAssertEqual(try decoder.run(["input": encoded]), input)

        let json = try XCTUnwrap(V0LocalTool.all.first { $0.id == "jsonpretty" })
        XCTAssertThrowsError(try json.run(["input": "{ugyldig}"]))
        XCTAssertThrowsError(try encoder.run(["input": String(repeating: "x", count: 20_001)]))
    }
}
