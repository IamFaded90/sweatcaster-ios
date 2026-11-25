import XCTest
@testable import SweatCaster

final class AudioTranscriptTests: XCTestCase {
    func testPendingAudioSurvivesReopenAndFailuresAndNeverCrossesAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), otherID = UUID()
        let pending = AudioTranscript.Recovery(botID: id, root: root.appendingPathComponent("pending"))
        let other = AudioTranscript.Recovery(botID: otherID, root: root.appendingPathComponent("pending"))
        let store = AudioTranscript.Store(botID: id, root: root.appendingPathComponent("journal"))
        let recording = AudioTranscript.Recording(title: "Mit møde")
        try pending.begin(recording)
        let raw = Data("raw audio retained".utf8); try raw.write(to: pending.audio(recording.id))
        XCTAssertEqual(try pending.list().map(\.id), [recording.id])
        XCTAssertTrue(try other.list().isEmpty)
        XCTAssertThrowsError(try pending.commit(recording, to: store) { throw AudioTranscript.Failure.invalid })
        XCTAssertEqual(try Data(contentsOf: pending.audio(recording.id)), raw)
        let reopened = AudioTranscript.Recovery(botID: id, root: root.appendingPathComponent("pending"))
        XCTAssertEqual(try reopened.list().map(\.id), [recording.id])
        XCTAssertThrowsError(try reopened.commit(recording, to: .init(botID: otherID, root: store.root)) {})
        let saved = try reopened.commit(recording, to: store) {}
        XCTAssertEqual(saved.id, recording.id); XCTAssertEqual(try store.load().map(\.id), [recording.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audio(recording.id).path))
    }
    func testFailedJournalWriteAndExistingTranscriptPreserveRawAndEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), pending = AudioTranscript.Recovery(botID: bot, root: root.appendingPathComponent("pending"))
        let recording = AudioTranscript.Recording(title: "Møde")
        try pending.begin(recording); try Data("original".utf8).write(to: pending.audio(recording.id))
        let badRoot = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: badRoot)
        XCTAssertThrowsError(try pending.commit(recording, to: .init(botID: bot, root: badRoot)) {})
        XCTAssertEqual(try Data(contentsOf: pending.audio(recording.id)), Data("original".utf8))
        let store = AudioTranscript.Store(botID: bot, root: root.appendingPathComponent("journal"))
        var edited = recording; edited.segments = [.init(start: 0, end: 1, text: "Mine rettelser")]
        try store.save(edited)
        let result = try pending.commit(recording, to: store) {}
        XCTAssertEqual(result.segments.first?.text, "Mine rettelser")
        XCTAssertEqual(try store.load().first?.segments.first?.text, "Mine rettelser")
    }
    func testFullLibraryKeepsRawAndDeletingOneAgentDoesNotTouchAnother() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), otherBot = UUID(), shared = root.appendingPathComponent("pending")
        let mine = AudioTranscript.Recovery(botID: bot, root: shared)
        let other = AudioTranscript.Recovery(botID: otherBot, root: shared)
        let recording = AudioTranscript.Recording(title: "Optagelse")
        try mine.begin(recording); try other.begin(recording)
        try Data("mine".utf8).write(to: mine.audio(recording.id))
        try Data("other".utf8).write(to: other.audio(recording.id))
        let store = AudioTranscript.Store(botID: bot, root: root.appendingPathComponent("journal"))
        for n in 0..<24 { try store.save(.init(title: "Eksisterende \(n)")) }
        XCTAssertThrowsError(try mine.commit(recording, to: store) {})
        XCTAssertEqual(try Data(contentsOf: mine.audio(recording.id)), Data("mine".utf8))
        try mine.remove(recording.id)
        XCTAssertEqual(try Data(contentsOf: other.audio(recording.id)), Data("other".utf8))
        XCTAssertEqual(try store.load().count, 24)
    }
    func testImportedConversionIsPreservedAndFailedCleanupDoesNotUndoCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bot = UUID(), recovery = AudioTranscript.Recovery(botID: bot, root: root.appendingPathComponent("pending"))
        let store = AudioTranscript.Store(botID: bot, root: root.appendingPathComponent("journal"))
        let recording = AudioTranscript.Recording(title: "Import")
        let converted = root.appendingPathComponent("saved.wav"), original = Data("saved audio".utf8)
        try original.write(to: converted)
        try recovery.preserveConverted(recording, from: converted)
        XCTAssertEqual(try Data(contentsOf: converted), original)
        XCTAssertEqual(try Data(contentsOf: recovery.audio(recording.id)), original)
        let sidecar = recovery.audio(recording.id).deletingPathExtension().appendingPathExtension("json")
        let otherFile = root.appendingPathComponent("other.txt")
        try Data("untouched".utf8).write(to: otherFile)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: otherFile)
        XCTAssertEqual(try recovery.commit(recording, to: store) {}.id, recording.id)
        XCTAssertEqual(try store.load().map(\.id), [recording.id])
        XCTAssertEqual(try Data(contentsOf: converted), original)
        XCTAssertEqual(try Data(contentsOf: otherFile), Data("untouched".utf8))
    }
    func testChunkBoundariesCoverWholeFileWithoutDuplication() throws {
        let chunks = try AudioTranscript.chunks(duration: 61)
        XCTAssertEqual(chunks, [0..<25, 25..<50, 50..<61]); XCTAssertThrowsError(try AudioTranscript.chunks(duration: 1801)); XCTAssertThrowsError(try AudioTranscript.chunks(duration: .nan))
    }
    func testOverlappingOrChangingSpeakersAreNotPretendedToBeOnePerson() {
        let texts: [AudioTranscript.Segment] = [.init(start: 0, end: 2, text: "Hej"), .init(start: 2, end: 5, text: "Goddag"), .init(start: 8, end: 9, text: "Ingen talerkilde")]
        let labeled = AudioTranscript.label(texts, with: [.init(speaker: "S7", start: 0, end: 3), .init(speaker: "S2", start: 2.5, end: 6), .init(speaker: "bad", start: .nan, end: 4)])
        XCTAssertEqual(labeled[0].speaker, "Taler 1"); XCTAssertEqual(labeled[1].speaker, "Flere talere"); XCTAssertNil(labeled[2].speaker)
        XCTAssertEqual(labeled.map(\.text), texts.map(\.text))
    }
    func testInterruptedTranscriptPersistsAndCanBeRemovedWithoutOtherBots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioTranscript.Store(botID: UUID(), root: root), other = AudioTranscript.Store(botID: UUID(), root: root)
        let recording = AudioTranscript.Recording(title: "Møde", segments: [.init(start: 25, end: 30, text: "Rigtig tekst")])
        try store.save(recording); try other.save(recording)
        XCTAssertEqual(try store.load().first?.complete, false); XCTAssertTrue(recording.exportedText.contains("00:25–00:30"))
        try store.remove(recording.id); XCTAssertTrue(try store.load().isEmpty); XCTAssertEqual(try other.load().count, 1)
    }
}
