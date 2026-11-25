import XCTest
@testable import SweatCaster

final class ClonedVoiceTests: XCTestCase {
    func testVoicesKeepIndividualIdentityAcrossRenameAndRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClonedVoice.Store(root: root)
        var first = ClonedVoice.Voice(name: "Adam"); let second = ClonedVoice.Voice(name: "Lumi")
        try store.save(first); try store.save(second); first.name = "Min Adam"; try store.save(first)
        XCTAssertEqual(try store.list().count, 2); XCTAssertEqual(try store.list().first { $0.id == first.id }?.name, "Min Adam")
        XCTAssertFalse(store.ready(first.id))
        try Data(repeating: 1, count: 500).write(to: store.conditions(first.id)); XCTAssertTrue(store.ready(first.id))
        try store.remove(first.id); XCTAssertFalse(store.ready(first.id)); XCTAssertEqual(try store.list().first?.id, second.id)
    }
    func testBadRecordingAndNonSpeechOutputAreRejected() throws {
        for duration in [0, 9, 61, .infinity, .nan] { XCTAssertThrowsError(try ClonedVoice.recording(seconds: duration, bytes: 1_000)) }
        XCTAssertThrowsError(try ClonedVoice.recording(seconds: 30, bytes: 21_000_000))
        try ClonedVoice.recording(seconds: 30, bytes: 100_000)
        XCTAssertThrowsError(try ClonedVoice.wav([])); XCTAssertThrowsError(try ClonedVoice.wav([0,0,0]))
        XCTAssertThrowsError(try ClonedVoice.wav([.nan, 0.1]))
        XCTAssertThrowsError(try ClonedVoice.wav([0.1], sampleRate: Int.max))
        let wave = try ClonedVoice.wav([0.1, -0.2, 2, -2])
        XCTAssertEqual(wave.prefix(4), Data("RIFF".utf8)); XCTAssertEqual(wave[8..<12], Data("WAVE".utf8)); XCTAssertEqual(wave.count, 52)
    }
    func testPartialInstallAndUnsafePathsNeverBecomeReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = ClonedVoice.Install(files: ["weights.bin": 4, "tokenizer.json": 2])
        try Data([1,2,3,4]).write(to: root.appendingPathComponent("weights.bin")); XCTAssertFalse(record.valid(in: root))
        try Data([1,2]).write(to: root.appendingPathComponent("tokenizer.json")); XCTAssertTrue(record.valid(in: root))
        for path in ["../secret", "/secret", "a/../b", "C:/secret", "a\\b"] { XCTAssertThrowsError(try ClonedVoice.safeFile(path, in: root)) }
    }
}
