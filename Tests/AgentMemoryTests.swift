import XCTest
@testable import SweatCaster

final class AgentMemoryTests: XCTestCase {
    func testMemoryIsModelIndependentScopedAndDeduplicated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), source = UUID(), store = AgentMemory.Store(botID: bot, root: root)
        let first = try store.remember("Jeg foretrækker et turkis kompas.", sourceTurnID: source)
        XCTAssertEqual(try store.remember(first.quote, sourceTurnID: source).id, first.id)
        XCTAssertEqual(try AgentMemory.Store(botID: bot, root: root).load().items.first?.sourceTurnID, source)
        XCTAssertTrue(try AgentMemory.Store(botID: UUID(), root: root).load().items.isEmpty)
        XCTAssertEqual(AgentMemory.candidates("Hvor er mit kompas?", items: try store.load().items).map(\.id), [first.id])
    }
    func testForgetRemovesSourceFromLaterContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentMemory.Store(botID: UUID(), root: root)
        _ = try store.remember("Jeg bruger en orange tekande.", sourceTurnID: nil)
        var snapshot = try store.load(); snapshot.items = []; try store.save(snapshot)
        XCTAssertTrue(AgentMemory.candidates("tekande", items: try store.load().items).isEmpty)
        XCTAssertEqual(AgentMemory.Context(items: []).instructions, "")
    }
}
