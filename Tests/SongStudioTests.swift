import XCTest
@testable import SweatCaster

final class SongStudioTests: XCTestCase {
    func testOnlyUnfinishedJobsKeepPCStatusRefreshActive() {
        func job(_ state: String) -> SongJob {
            .init(id: UUID(), title: "Sang", prompt: "Jazz", lyrics: "", favorite: "", mode: .new,
                  seconds: 20, instrumental: true, state: state, notice: "", created: 1)
        }
        let done = SongStudioCatalog(ready: true, voiceReference: true,
                                     jobs: [job("completed"), job("failed"), job("removed")])
        XCTAssertFalse(done.hasActiveJobs)
        for state in ["queued", "submitting", "rendering"] {
            let pending = SongStudioCatalog(ready: true, voiceReference: true, jobs: done.jobs + [job(state)])
            XCTAssertTrue(pending.hasActiveJobs, "\(state) should continue to update")
        }
        XCTAssertFalse(SongStudioCatalog(ready: true, voiceReference: true, jobs: []).hasActiveJobs)
    }
    func testHiphopGetsUsefulDetailWithoutChangingUserConstraints() {
        let short = SongPrompt.expanded("hiphop", instrumental: true)
        XCTAssertTrue(short.contains("laid-back swing"))
        XCTAssertTrue(short.contains("no vocals"))
        let specified = SongPrompt.expanded("hiphop uden trommer, 140 BPM og uden bas", instrumental: false)
        XCTAssertTrue(specified.hasPrefix("hiphop uden trommer, 140 BPM og uden bas"))
        XCTAssertFalse(specified.contains("punchy drums"))
        XCTAssertFalse(specified.contains("mid-tempo"))
        XCTAssertFalse(specified.contains("controlled bass"))
        XCTAssertTrue(specified.contains("no drums"))
    }
    func testDetailedOrUnknownGenreRequestsAreNotInventedOver() {
        XCTAssertEqual(SongPrompt.expanded("min særlige stil", instrumental: false), "min særlige stil")
        let detailed = "hiphop " + Array(repeating: "beskrivelse", count: 26).joined(separator: " ")
        XCTAssertEqual(SongPrompt.expanded(detailed, instrumental: false), detailed)
        let constrained = SongPrompt.expanded("mørk hiphop uden omkvæd", instrumental: false)
        XCTAssertFalse(constrained.contains("warm"))
        XCTAssertFalse(constrained.contains("verse and hook"))
    }
    func testSongCommandOpensActionWithoutInterceptingQuestions() {
        XCTAssertEqual(SongDraft.request("Lav en sang med mørk house")?.prompt, "med mørk house")
        XCTAssertEqual(SongDraft.request("Lav et remix")?.mode, .remix)
        XCTAssertNil(SongDraft.request("Hvordan laver jeg en sang?"))
        XCTAssertNil(SongDraft.request("Find en sang med et godt omkvæd"))
    }
    func testFavoriteTitleCannotPretendToBeRemixAudio() {
        var draft = SongDraft()
        draft.title = "Mit nummer"; draft.prompt = "Rolig house"; draft.mode = .remix
        draft.favorite = "Et nummer · En kunstner"
        XCTAssertNotNil(draft.problem)
        draft.source = Data([1, 2, 3])
        XCTAssertNil(draft.problem)
    }
    func testVoiceTrialCannotSilentlyReplaceMusicReference() {
        var draft = SongDraft()
        draft.title = "Prøve"; draft.prompt = "Pop"; draft.mode = .inspiration
        draft.source = Data([1]); draft.voice = Data([2])
        XCTAssertNotNil(draft.problem)
        draft.mode = .remix
        XCTAssertNil(draft.problem)
        draft.instrumental = true
        XCTAssertNotNil(draft.problem)
    }
    func testInvalidDurationsAndOversizeReferenceAreRejected() {
        var draft = SongDraft()
        draft.title = "Sang"; draft.prompt = "Jazz"; draft.seconds = .nan
        XCTAssertNotNil(draft.problem)
        draft.seconds = 60
        draft.source = Data(repeating: 0, count: 12_000_001)
        XCTAssertNotNil(draft.problem)
    }
    func testGeneratedAudioHasOwnIDAndRejectsPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SongLibrary(root: root)
        XCTAssertNil(library.localURL("../../elsewhere"))
        let id = UUID()
        XCTAssertTrue(SongLibrary.trackID(id).hasPrefix("faded-song-"))
        let job = SongJob(id: id, title: "Sang", prompt: "Jazz", lyrics: "", favorite: "",
            mode: .new, seconds: 20, instrumental: true, state: "completed", notice: "Klar", created: 1)
        var wave = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8)
        wave += Data(repeating: 0, count: 44)
        let track = try library.save(wave, job: job)
        XCTAssertNotNil(library.localURL(track.id))
        try library.remove(id)
        XCTAssertNil(library.localURL(track.id))
    }
    func testInputAudioIsSentOnlyWhenExplicitlyChosen() throws {
        var draft = SongDraft()
        draft.title = "Jazz"; draft.prompt = "Slow jazz"; draft.favorite = "My favorite"
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        XCTAssertNil(value["source"])
        XCTAssertNil(value["voice"])
        XCTAssertEqual(value["favorite"] as? String, "My favorite")
    }
    func testPhoneSongIsCopiedFromDiskWithoutOverwritingExistingSong() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav"), library = SongLibrary(root: root.appendingPathComponent("songs"))
        let id = UUID(), job = SongJob(id: id, title: "Sang", prompt: "Jazz", lyrics: "", favorite: "", mode: .new, seconds: 20, instrumental: true, state: "completed", notice: "Klar", created: 1)
        let bytes = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8) + Data(repeating: 3, count: 200_000)
        try bytes.write(to: source)
        let track = try library.saveFile(source, job: job)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.localURL(track.id))), bytes)
        XCTAssertThrowsError(try library.saveFile(source, job: job))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testPhoneSongRecoversAfterJournalWasLostAndIgnoresOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try (Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8) + Data(repeating: 0, count: 44)).write(to: source)
        let library = SongLibrary(root: root.appendingPathComponent("songs"))
        let id = UUID()
        let job = SongJob(id: id, title: "Reddet sang", prompt: "Jazz", lyrics: "", favorite: "", mode: .new,
                          seconds: 20, instrumental: true, state: "completed", notice: "Lavet på denne iPhone · 20 sek.", created: 1)
        let track = try library.saveFile(source, job: job)
        XCTAssertEqual(library.recoverPhoneSongs(), [job])
        XCTAssertTrue(library.containsStoredFiles(id))
        try FileManager.default.removeItem(at: XCTUnwrap(library.localURL(track.id)))
        XCTAssertTrue(library.recoverPhoneSongs().isEmpty, "Metadata without the audio file must not become a playable song")
        try library.remove(id)
        XCTAssertFalse(library.containsStoredFiles(id))
    }
}
