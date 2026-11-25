import XCTest
@testable import SweatCaster

final class VillageAmbienceTests: XCTestCase {
    func testRestoreKeepsExactSettingsAndCreatesUndoHistory() throws {
        var record = VillageAmbience.Record()
        var warm = VillageAmbience.Settings(); warm.name = "Aften"; warm.light = .golden; warm.sound = .fire
        warm.imageID = UUID(); warm.music = .init(id: "local-song", title: "Min sang", artist: "Mig")
        try record.apply(warm)
        var moon = warm; moon.name = "Nat"; moon.light = .moon; moon.volume = 0.1
        try record.apply(moon)
        let warmID = try XCTUnwrap(record.history.last?.id)
        try record.restore(warmID)
        XCTAssertEqual(record.current, warm)
        XCTAssertEqual(record.history.last?.settings, moon)
        XCTAssertEqual(record.current.imageID, warm.imageID)
    }
    func testInvalidSettingsCannotOverwriteSavedRecord() throws {
        var record = VillageAmbience.Record()
        var invalid = record.current; invalid.volume = .nan
        XCTAssertThrowsError(try record.apply(invalid))
        XCTAssertEqual(record.current.volume, 0.22)
        invalid = record.current; invalid.brightness = 100
        XCTAssertThrowsError(try record.savePreset(invalid))
        XCTAssertTrue(record.presets.isEmpty)
    }
    func testHistoryAndPresetsStayBounded() throws {
        var record = VillageAmbience.Record()
        for index in 0..<60 {
            var settings = VillageAmbience.Settings(); settings.name = "Stemning \(index)"
            try record.apply(settings); try record.savePreset(settings)
        }
        XCTAssertEqual(record.history.count, 24); XCTAssertEqual(record.presets.count, 12)
    }
    func testDeletingScenePreservesOtherSceneAndReferencedImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VillageAmbience.Store(root: root)
        let image = try store.saveImage(Data([1, 2, 3]))
        var settings = VillageAmbience.Settings(); settings.imageID = image
        var record = VillageAmbience.Record(); try record.apply(settings)
        try store.save(record, scene: "room-a"); try store.save(record, scene: "room-b")
        XCTAssertEqual(try store.load("room-a"), record)
        try store.remove("room-a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.image(image).path))
        XCTAssertEqual(try store.load("room-b"), record)
        try store.remove("room-b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.image(image).path))
        XCTAssertThrowsError(try store.load("../../outside"))
    }
    func testBackgroundDeletionRemovesAllVersionsButKeepsLightAndMusic() throws {
        let image = UUID()
        var settings = VillageAmbience.Settings(); settings.light = .aurora; settings.imageID = image
        var record = VillageAmbience.Record(); try record.apply(settings); try record.savePreset(settings)
        settings.name = "Ny"; try record.apply(settings)
        record.removeImage(image)
        XCTAssertTrue(record.imageIDs.isEmpty)
        XCTAssertEqual(record.current.light, .aurora)
        XCTAssertNil(record.presets.first?.settings.imageID)
    }
    func testOfflineSoundsHaveFiniteBoundedAudioAndDifferentCharacter() {
        let rain = VillageAmbiencePCM.samples(sound: .rain, rate: 8_000, seconds: 1)
        let fire = VillageAmbiencePCM.samples(sound: .fire, rate: 8_000, seconds: 1)
        let waves = VillageAmbiencePCM.samples(sound: .waves, rate: 8_000, seconds: 1)
        XCTAssertEqual(rain.count, 8_000); XCTAssertNotEqual(rain, fire); XCTAssertNotEqual(fire, waves)
        for values in [rain, fire, waves] {
            XCTAssertTrue(values.allSatisfy { $0.isFinite && abs($0) <= 0.8 })
            XCTAssertGreaterThan(values.reduce(Float(0)) { $0 + $1 * $1 }, 0.01)
        }
        XCTAssertTrue(VillageAmbiencePCM.samples(sound: .none).isEmpty)
        XCTAssertTrue(VillageAmbiencePCM.samples(sound: .rain, seconds: 100).isEmpty)
    }
}
