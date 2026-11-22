import XCTest
@testable import SweatCaster

final class AgentShoppingTests: XCTestCase {
    func testSeveralItemsAndDecimalQuantities() {
        XCTAssertEqual(AgentShoppingRequest.match("Kan du tilføje 1,5 liter mælk, æg og rugbrød til min indkøbsliste?"),
                       .add(["1,5 liter mælk", "æg", "rugbrød"]))
        XCTAssertEqual(AgentShoppingRequest.match("Lav en indkøbsliste: Æg; æg\nkaffe"), .add(["Æg", "kaffe"]))
        XCTAssertEqual(AgentShoppingRequest.key("Køb   MÆLK"), "mælk")
    }

    func testFetchingAndUnrelatedChat() {
        XCTAssertEqual(AgentShoppingRequest.match("Hvad mangler der på indkøbslisten?"), .view)
        XCTAssertEqual(AgentShoppingRequest.match("Vis min indkøbsliste"), .view)
        XCTAssertNil(AgentShoppingRequest.match("Hvad synes du om min indkøbsliste?"))
        XCTAssertNil(AgentShoppingRequest.match("Slet indkøbslisten"))
        XCTAssertNil(AgentShoppingRequest.match("Lav en indkøbsliste med    "))
    }

    func testWeightsVolumesAndCounts() throws {
        let weight = try XCTUnwrap(AgentUnitPrice.answer("Hvad er billigst: 600 g til 30 kr eller 1 kg til 45 kr?"))
        XCTAssertTrue(weight.hasPrefix("1 kg til 45 kr er billigst pr. kg."))
        XCTAssertTrue(weight.contains("50,00 kr./kg"))
        let mixedOrder = try XCTUnwrap(AgentUnitPrice.answer("Sammenlign 30 kr for 600 g med 1 kg 45 kr"))
        XCTAssertTrue(mixedOrder.hasPrefix("1 kg 45 kr er billigst"))
        let grouped = try XCTUnwrap(AgentUnitPrice.answer("Hvad er billigst: 1.000 g for 20 kr. eller 500 g for 15 kr?"))
        XCTAssertTrue(grouped.hasPrefix("1.000 g for 20 kr. er billigst"))
        let large = try XCTUnwrap(AgentUnitPrice.answer("Hvad er billigst: 1.500,5 ml for 15 kr eller 1 liter for 12 kr?"))
        XCTAssertTrue(large.hasPrefix("1.500,5 ml for 15 kr er billigst"))
        let volume = try XCTUnwrap(AgentUnitPrice.answer("Hvad er billigst, 75 cl for 12,50 kr. eller 2 l til 34 kr?"))
        XCTAssertTrue(volume.hasPrefix("75 cl for 12,50 kr."))
        XCTAssertTrue(volume.contains("16,6667 kr./l"), volume)
        XCTAssertTrue(try XCTUnwrap(AgentUnitPrice.answer("Hvad er billigst: 3 stk til 10 kr eller 6 styk til 20 kr")).hasPrefix("De koster det samme"))
    }

    func testInvalidOrIncompatibleOffers() {
        XCTAssertNil(AgentUnitPrice.answer("Hvad er billigst i min lokale butik?"))
        XCTAssertNil(AgentUnitPrice.answer("Hvad er billigst: 0 g til 20 kr eller 200 g til 9 kr"))
        XCTAssertNotNil(AgentUnitPrice.answer("Hvad er billigst: 1 l til 20 kr eller 1 kg til 18 kr")?.range(of: "samme slags enhed"))
    }

    func testPreviewAndRetryAfterPartiallyRecordedShopping() throws {
        let id = UUID()
        let items = ["mælk", "æg", "ris", "kaffe"]
        let selected: Set<String> = ["mælk", "æg", "kaffe"]
        let rows = [AgentShoppingRow(title: "Køb Tilføj mælk til min indkøbsliste", marker: nil, done: false),
                    AgentShoppingRow(title: "Køb kaffe", marker: nil, done: true),
                    AgentShoppingRow(title: "æg", marker: nil, done: false)]
        let plan = AgentShoppingPlan(original: items, selected: selected, requestID: id, rows: rows, defaultList: true)
        XCTAssertEqual(plan.existing, ["mælk"])
        XCTAssertEqual(plan.additions.map(\.title), ["æg", "kaffe"])
        let saved = try XCTUnwrap(plan.additions.first)
        let retryRows = rows + [AgentShoppingRow(title: "æg fra gården", marker: saved.marker, done: true)]
        let retry = AgentShoppingPlan(original: items, selected: selected, requestID: id, rows: retryRows, defaultList: true)
        XCTAssertEqual(retry.existing, ["mælk", "æg"])
        XCTAssertEqual(retry.additions.map(\.marker), [try XCTUnwrap(plan.additions.last).marker])
        let named = AgentShoppingPlan(original: items, selected: selected, requestID: UUID(), rows: rows, defaultList: false)
        XCTAssertEqual(named.additions.map(\.title), ["kaffe"])
    }

    func testReadOnlySharedListAndPreviousDefaultList() {
        let add = AgentShoppingRequest.add(["mælk"])
        XCTAssertEqual(add.destinationIDs(named: ["Delt"], writable: ["Min"], standard: "Min"), ["Min"])
        XCTAssertEqual(AgentShoppingRequest.view.destinationIDs(named: ["Delt"], writable: ["Min"], standard: "Min"), ["Min", "Delt"])
        XCTAssertEqual(AgentShoppingRequest.view.destinationIDs(named: ["Delt", "Indkøb"], writable: ["Indkøb", "Min"], standard: "Min"),
                       ["Indkøb", "Delt", "Min"])
        XCTAssertEqual(add.destinationIDs(named: ["Delt"], writable: [], standard: nil), [])
    }

    func testVoiceInboxAndChatAgreeOnGroceryItems() {
        let rows = VoiceInboxParser.suggestions(from: "Tilføj mælk og kaffe til min indkøbsliste")
        XCTAssertEqual(rows.map(\.text), ["Køb mælk", "Køb kaffe"])
        XCTAssertTrue(rows.allSatisfy { $0.kind == .shopping })
        XCTAssertEqual(AgentShoppingRequest.titles(in: "Køb Tilføj mælk og kaffe til min indkøbsliste"), ["mælk", "kaffe"])
    }

    @MainActor func testIndividualAndTeamRouting() {
        let add = "Skriv mælk og kaffe på indkøbslisten"
        guard case .action(.shopping(.add(let items)))? = AgentChatIntent.match(add),
              case .shopping(.add(let teamItems))? = TeamTool.match(add) else { return XCTFail("Indkøb blev ikke genkendt") }
        XCTAssertEqual(items, ["mælk", "kaffe"])
        XCTAssertEqual(teamItems, items)
        let compare = "Hvad er billigst: 1 kg til 40 kr eller 500 g til 30 kr?"
        guard case .action(.unitPrice(let answer))? = AgentChatIntent.match(compare),
              case .unitPrice(let teamAnswer)? = TeamTool.match(compare) else { return XCTFail("Tilbudsregneren blev ikke valgt") }
        XCTAssertEqual(answer, teamAnswer)
    }
}
