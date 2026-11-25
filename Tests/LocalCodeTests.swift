import XCTest
@testable import SweatCaster

final class LocalCodeTests: XCTestCase {
    func testFailuresNeverBecomeCompletedOutput() throws {
        XCTAssertThrowsError(try LocalCode.output(#"{"ok":false,"error":"timeout"}"#))
        XCTAssertThrowsError(try LocalCode.output(#"{"ok":true}"#))
        XCTAssertThrowsError(try LocalCode.output(#"{"ok":true,"text":""}"#))
        XCTAssertEqual(try LocalCode.output(#"{"ok":true,"text":"6"}"#), "6")
    }
    func testRecipeBudgetAndCommandRouting() throws {
        XCTAssertThrowsError(try LocalCode.Recipe.decode("return 1"))
        let data = try JSONEncoder().encode(LocalCode.Recipe(name: "Stor", code: String(repeating: "x", count: 8_001)))
        XCTAssertThrowsError(try LocalCode.Recipe.decode(String(decoding: data, as: UTF8.self)))
        XCTAssertEqual(LocalCode.command("Lav et lokalt værktøj: læg beløb sammen"), "læg beløb sammen")
        XCTAssertNil(LocalCode.command("Forklar kode"))
        XCTAssertEqual(LocalCode.linuxCommand("Åbn terminalen"), "")
        XCTAssertEqual(LocalCode.linuxCommand(" KØR LINUX: Sortér æbler "), "Sortér æbler")
        XCTAssertNil(LocalCode.linuxCommand("Hvad er Linux?"))
        XCTAssertTrue(LocalCode.page.contains("connect-src 'none'")); XCTAssertTrue(LocalCode.page.contains("worker.terminate()"))
    }
}
