import Foundation
import XCTest
@testable import SweatCaster

final class AgentTasteTests: XCTestCase {
    func testOneDistinctOptionNeverWinsABlindComparison() {
        for choices in [[], [""], ["Nic"], ["Nic", "Nic", ""]] as [[String]] {
            var round = AgentTasteRound(choices)
            XCTAssertTrue(round.pair.isEmpty)
            round.choose("Nic")
            XCTAssertNil(round.favorite)
        }
    }

    func testWinnerFacesNewChallengersAndCanBeKeptEarly() {
        var round = AgentTasteRound(["one", "one", "two", "three", "two", "four"])
        XCTAssertEqual(round.pair, ["one", "two"])
        round.choose("four")
        XCTAssertNil(round.favorite)
        round.choose("two")
        XCTAssertEqual(round.favorite, "two")
        XCTAssertEqual(Set(round.pair), ["two", "three"])
        round.choose("one")
        XCTAssertEqual(round.comparisons, 1)
        round.choose("three")
        XCTAssertEqual(Set(round.pair), ["three", "four"])
        round.choose("four")
        XCTAssertEqual(round.favorite, "four")
        XCTAssertTrue(round.pair.isEmpty)
        round.choose("two")
        XCTAssertEqual(round.favorite, "four")
        XCTAssertEqual(round.comparisons, 3)
    }

    func testImageStyleSurvivesReopeningForOnlyTheChosenAgent() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let eva = UUID(), adam = UUID()
        AgentImageTasteStyle.pixel.save(for: eva, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let selected = try XCTUnwrap(AgentImageTasteStyle.selected(for: eva, defaults: reopened))
        XCTAssertEqual(selected, .pixel)
        XCTAssertNil(AgentImageTasteStyle.selected(for: adam, defaults: reopened))
        XCTAssertEqual(selected.applying(to: "  "), "")
        XCTAssertTrue(selected.applying(to: "Et hus").hasPrefix("Et hus\n"))
        XCTAssertFalse(selected.applying(to: "Et hus") == AgentImageTasteStyle.puppet.applying(to: "Et hus"))
        defaults.removeObject(forKey: AgentImageTasteStyle.key(for: eva))
        XCTAssertNil(AgentImageTasteStyle.selected(for: eva, defaults: reopened))
    }

    #if canImport(UIKit)
    @MainActor func testVoiceWinnerReachesProfileAndPlaybackOverrideOnlyForWinnerOwner() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = MigratedAppData(defaults: defaults, store: LocalModelStore(root: folder))
        let eva = VillageBot.founderEva(), adam = VillageBot.founderAdam()
        try store.saveVillageBots(JSONEncoder().encode([eva, adam]))
        let voice = AgentPCVoice.roestNic.id
        try AgentVoiceSelection.save(voice, for: eva.id, store: store, defaults: defaults)
        let reopened = try JSONDecoder().decode([VillageBot].self, from: store.villageBots)
        XCTAssertEqual(reopened.map(\.voice), [voice, adam.voice])
        XCTAssertEqual(reopened.map(\.villageFigure), [eva.villageFigure, adam.villageFigure])
        XCTAssertEqual(defaults.string(forKey: PhoneModels.agentVoiceKey(eva.id)), voice)
        XCTAssertNil(defaults.string(forKey: PhoneModels.agentVoiceKey(adam.id)))
        let deleted = UUID()
        XCTAssertThrowsError(try AgentVoiceSelection.save(voice, for: deleted, store: store, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: PhoneModels.agentVoiceKey(deleted)))
    }
    #endif
}
