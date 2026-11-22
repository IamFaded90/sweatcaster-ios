// Tests migration and bounded storage using isolated defaults and temporary files.
import Foundation
import UIKit
import XCTest
@testable import SweatCaster

final class LumiSceneExpiryTests: XCTestCase {
    func testPrivateSearchUsesSavedDialogueAndDropsAnExpiredMatch() throws {
        let now = Date.now
        let card = LumiSceneCard(title: "Aftentur", setting: "Havnen")
        let line = LumiSceneMessage(role: .user, text: "Min båd hedder Månestriben.", language: "da-DK")
        var first = LumiSavedScene.snapshot(card: card, initiative: .together, language: "da-DK", messages: [line], draft: "")
        first.expiresAt = now.addingTimeInterval(1)
        let expired = scene("Månestriben", expiry: now)
        let other = scene("Bogklubben")
        let saved = [other, first, expired]
        let found = try LumiSavedScene.matching("månestriben", in: saved, at: now)
        XCTAssertTrue(found.contains(first.id))
        XCTAssertFalse(found.contains(expired.id))
        XCTAssertFalse(try LumiSavedScene.matching("månestriben", in: saved, at: now.addingTimeInterval(1)).contains(first.id))
        XCTAssertEqual(try LumiSavedScene.matching("  ", in: saved, at: now), [other.id, first.id])
    }

    func testPrivateSearchSamplesEverySavedExchangeBeyondALongDraft() throws {
        let filler = String(repeating: "Introduktion. ", count: 230)
        let dialogue = (1...16).map { i in
            LumiSceneMessage(role: i.isMultiple(of: 2) ? .assistant : .user,
                             text: "Linje \(i): " + filler + "slut-\(i)!", language: "da-DK")
        }
        let saved = LumiSavedScene.snapshot(card: .init(title: "Værksted"), initiative: .together,
            language: "da-DK", messages: dialogue, draft: filler + "Kladdeslut")
        let excerpts = saved.semanticExcerpts
        XCTAssertEqual(excerpts.count, 5)
        XCTAssertTrue(excerpts.allSatisfy { $0.unicodeScalars.count < 1_000 })
        XCTAssertTrue(excerpts[0].contains("Kladdeslut"))
        for i in 1...16 {
            XCTAssertTrue(excerpts[1 + (i - 1) / 4].contains("slut-\(i)!"))
        }
        let titles = ["Aften ved vandet", "Månestriben"]
        XCTAssertEqual(try LocalTextRanking.lexicalOrder(query: "månestr", texts: titles, completingLastWord: true), [1])
        XCTAssertEqual(try LocalTextRanking.lexicalOrder(query: "månestr", texts: titles), [])
        XCTAssertEqual(try LocalTextRanking.lexicalOrder(query: "må", texts: titles, completingLastWord: true), [])
    }

    private func scene(_ title: String, expiry: Date? = nil) -> LumiSavedScene {
        var scene = LumiSavedScene.snapshot(
            card: LumiSceneCard(title: title), initiative: .together, language: "da-DK",
            messages: [LumiSceneMessage(role: .user, text: title, language: "da-DK")], draft: "")
        scene.expiresAt = expiry
        return scene
    }

    @MainActor func testExpiryRemovesOnlyTemporarySceneWithoutReopeningStudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LumiSceneLibrary(root: root)
        let file = root.appendingPathComponent("library.json")
        let permanent = scene("Behold")
        let temporary = scene("Midlertidig", expiry: .now.addingTimeInterval(0.15))
        try library.write([permanent, temporary])
        let store = LocalFileStore(root: root)
        let timeout = ContinuousClock.now.advanced(by: .seconds(3))
        var stored = try store.read([LumiSavedScene].self, from: file)
        while stored.count > 1 && ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(25))
            stored = try store.read([LumiSavedScene].self, from: file)
        }
        XCTAssertEqual(stored.map(\.id), [permanent.id])
        try library.write([scene("Sidste midlertidige scene", expiry: .now.addingTimeInterval(0.15))])
        let lastDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.exists(file) && ContinuousClock.now < lastDeadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(store.exists(file))
        XCTAssertTrue(try library.read().isEmpty)
    }

    @MainActor func testColdReadPrunesExpiredScenesAndKeepsOneResavedPermanently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launchTime = Date.now
        var promoted = scene("Gem permanent", expiry: launchTime.addingTimeInterval(0.15))
        let store = LocalFileStore(root: root)
        let file = root.appendingPathComponent("library.json")
        try store.write([scene("Udløbet", expiry: .distantPast), promoted], to: file)
        let reopened = LumiSceneLibrary(root: root)
        XCTAssertEqual(try reopened.read(now: launchTime).map(\.id), [promoted.id])
        promoted.expiresAt = nil
        try reopened.write([promoted])
        try await Task.sleep(for: .milliseconds(250))
        let stored = try store.read([LumiSavedScene].self, from: file)
        XCTAssertEqual(stored.map(\.id), [promoted.id])
        XCTAssertNil(stored.first?.expiresAt)
    }

    func testExpiredSceneAttachmentsLeaveDiskAndMemoryWhileOtherScenesKeepTheirPhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = scene("Udløbet")
        let saved = scene("Gemt")
        let open = scene("Åben")
        let store = LocalFileStore(root: root)
        var media = LumiSceneMedia()
        for scene in [expired, saved, open] {
            let id = try XCTUnwrap(scene.messages.first?.id)
            let file = root.appendingPathComponent("Lumi-\(id).png")
            let bytes = Data(scene.card.title.utf8)
            try LocalFileStore.writeBytes(bytes, to: file, within: root)
            media.sentPhotos[id] = bytes
            media.pictures[id] = file
        }
        let preview = root.appendingPathComponent("Lumi.png")
        try LocalFileStore.writeBytes(Data([1]), to: preview, within: root)
        let pictures = media.pictures
        media.retain(for: open.messages, saved: [saved], in: root)
        let expected = Set((open.messages + saved.messages).map(\.id))
        XCTAssertEqual(Set(media.pictures.keys), expected)
        XCTAssertEqual(Set(media.sentPhotos.keys), expected)
        for (id, file) in pictures { XCTAssertEqual(store.exists(file), expected.contains(id)) }
        XCTAssertTrue(store.exists(preview))
    }
}

final class MigrationTests: XCTestCase {
    @MainActor func testGalleryThumbnailReusesOnlyTheCurrentOrdinaryFile() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("image.png")
        let link = root.appendingPathComponent("link.png")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 128)).pngData { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 512, height: 128))
        }
        try png.write(to: source)
        let cache = StudioGalleryThumbnailCache()
        let first = await cache.image(for: source, in: root)
        XCTAssertEqual(first?.width, 384)
        let hit = await cache.image(for: source, in: root) { _ in nil }
        XCTAssertTrue(first === hit)
        try png.write(to: source, options: .atomic)
        let stale = await cache.image(for: source, in: root) { _ in nil }
        XCTAssertNil(stale)
        try files.createSymbolicLink(at: link, withDestinationURL: source)
        let linked = await cache.image(for: link, in: root)
        let outside = await cache.image(for: source, in: root.appendingPathComponent("other"))
        let privateURL = try XCTUnwrap(URL(string: "fadedai-private://studio/abc/image.png"))
        let privateImage = await cache.image(for: privateURL, in: root)
        XCTAssertNil(linked)
        XCTAssertNil(outside)
        XCTAssertNil(privateImage)
        let replacement = await cache.image(for: source, in: root)
        XCTAssertNotNil(replacement)
        cache.remove(source)
        let evicted = await cache.image(for: source, in: root) { _ in nil }
        XCTAssertNil(evicted)
        try files.removeItem(at: source)
        let missing = await cache.image(for: source, in: root)
        XCTAssertNil(missing)
    }

    @MainActor func testClearingGalleryDuringDecodeDiscardsLateThumbnail() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.png")
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { _ in }
        try bytes.write(to: source)
        let cache = StudioGalleryThumbnailCache()
        let started = expectation(description: "Thumbnail decode started")
        let finish = DispatchSemaphore(value: 0)
        let pending = Task {
            await cache.image(for: source, in: root) { file in
                started.fulfill()
                guard finish.wait(timeout: .now() + 5) == .success else { return nil }
                return StudioGalleryThumbnailCache.decode(file)
            }
        }
        await fulfillment(of: [started], timeout: 4)
        cache.clear()
        finish.signal()
        let late = await pending.value
        XCTAssertNil(late)
        let cached = await cache.image(for: source, in: root) { _ in nil }
        XCTAssertNil(cached)
    }

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
