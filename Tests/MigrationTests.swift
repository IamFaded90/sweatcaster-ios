// Tests migration and bounded storage using isolated defaults and temporary files.
import Foundation
import XCTest
@testable import SweatCaster

final class MigrationTests: XCTestCase {
    @MainActor func testMigratesAllSixValuesAndReadsThemOnRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        let encoder = JSONEncoder()
        let bot = VillageBot(name: "Scout")
        let turns = [PrivateChatTurn(prompt: "Hej", reply: "Goddag")]
        let previews = [ChatTurn(prompt: "Min note", source: "Telefon")]
        let fields: [(String, Any)] = [
            (AppStorageKeys.villageBots, try encoder.encode([bot])),
            (AppStorageKeys.spacesNotes, "Husk øvelsen"),
            (AppStorageKeys.privateChatTurns, try encoder.encode(turns)),
            (AppStorageKeys.privateChatDraft, "Dansk kladde"),
            (AppStorageKeys.dashboardChatPreviews, try encoder.encode(previews)),
            (AppStorageKeys.codeActiveContext, ["App/LoginView.swift"])
        ]
        for (key, value) in fields { defaults.set(value, forKey: key) }

        MigratedAppData(defaults: defaults, store: fixture.store).migrateUserDefaultsToFilesIfNeeded()
        for (key, _) in fields { XCTAssertNil(defaults.object(forKey: key), key) }

        let reopened = MigratedAppData(defaults: defaults, store: fixture.store)
        reopened.migrateUserDefaultsToFilesIfNeeded()
        XCTAssertEqual(try JSONDecoder().decode([VillageBot].self, from: reopened.villageBots), [bot])
        XCTAssertEqual(reopened.notes, "Husk øvelsen")
        XCTAssertEqual(reopened.regularStudioTurns().map(\.reply), ["Goddag"])
        XCTAssertEqual(reopened.regularStudioDraft(), "Dansk kladde")
        XCTAssertEqual(try JSONDecoder().decode([ChatTurn].self, from: reopened.dashboardPreviews).map(\.prompt), ["Min note"])
        XCTAssertEqual(reopened.codeContext(), ["App/LoginView.swift"])
    }

    @MainActor func testValidFileTakesPrecedenceAndInvalidLegacyRemainsIntact() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        try model.saveNotes("Nyere fil")
        fixture.defaults.set("Ældre kladde", forKey: AppStorageKeys.spacesNotes)
        let invalid = Data("invalid JSON".utf8)
        fixture.defaults.set(invalid, forKey: AppStorageKeys.villageBots)

        model.migrateUserDefaultsToFilesIfNeeded()
        XCTAssertEqual(model.notes, "Nyere fil")
        XCTAssertNil(fixture.defaults.object(forKey: AppStorageKeys.spacesNotes))
        XCTAssertEqual(fixture.defaults.data(forKey: AppStorageKeys.villageBots), invalid)
        XCTAssertNil(try fixture.store.load([VillageBot].self, forKey: "village_bots"))
    }

    func testModelStoreRejectsTraversalOversizedFilesAndSymlinkReads() throws {
        let fixture = try makeFixture(maximumBytes: 64)
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try fixture.store.save(["bad"], forKey: "../escape"))
        XCTAssertThrowsError(try fixture.store.save(String(repeating: "a", count: 65), forKey: "large"))

        try fixture.store.save(["local"], forKey: "record")
        let target = fixture.store.root.appending(path: "record.json")
        let symlink = fixture.store.root.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.store.load([String].self, forKey: "link"))
        XCTAssertThrowsError(try fixture.store.delete(forKey: "link"))
        XCTAssertEqual(try fixture.store.load([String].self, forKey: "record"), ["local"])
    }

    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let store: LocalModelStore

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(maximumBytes: Int = 8_388_608) throws -> Fixture {
        let suite = "FadedAI.Tests.Migration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = LocalModelStore(root: directory.appending(path: "Models", directoryHint: .isDirectory), maximumBytes: maximumBytes)
        return Fixture(defaults: defaults, suite: suite, directory: directory, store: store)
    }
}
