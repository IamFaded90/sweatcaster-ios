import AVFAudio
import XCTest
@testable import SweatCaster

final class AgentVoiceContractTests: XCTestCase {
    func testPCSpeechKeepsWholeSentencesAndWordsWithinTheServiceLimit() {
        let sentence = String(repeating: "Dette er en sætning. ", count: 12).trimmingCharacters(in: .whitespaces)
        let reply = [sentence, sentence, sentence].joined(separator: "\n")
        let parts = PCSpeechPassages.split(reply)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.hasSuffix(".") && $0.unicodeScalars.count <= 500 })
        XCTAssertEqual(parts.joined(separator: " ").split(whereSeparator: \.isWhitespace),
                       reply.split(whereSeparator: \.isWhitespace))
        XCTAssertEqual(PCSpeechPassages.split("  \n"), [])
        XCTAssertEqual(PCSpeechPassages.split("Kort svar."), ["Kort svar."])
        let unicode = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let unicodeParts = PCSpeechPassages.split(unicode)
        XCTAssertTrue(unicodeParts.allSatisfy { (1...500).contains($0.unicodeScalars.count) })
        XCTAssertEqual(unicodeParts.joined(), unicode)
        XCTAssertEqual(unicodeParts.map(\.count).reduce(0, +), unicode.count)
    }

    func testPrivateStudioUsesTheExactProfileVoiceForReadingAndPreview() {
        for voice in AgentPCVoice.allCases {
            XCTAssertEqual(StudioVoiceChoice(studio: "", profile: voice.rawValue), .pc(voice))
        }
        let personal = "com.example.english-personal-voice"
        XCTAssertEqual(StudioVoiceChoice(studio: "", profile: personal), .phone(personal))
        XCTAssertEqual(StudioVoiceChoice(studio: personal, profile: "roest-lumi"), .phone(personal))
        XCTAssertEqual(StudioVoiceChoice(studio: "auto", profile: "roest-lumi"), .phone("auto"))
    }

    @MainActor func testTwoDanishPCVoicesStayWithTheirOwnAgents() throws {
        let suite = "DanishVoiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = MigratedAppData(defaults: defaults, store: LocalModelStore(root: folder))
        let eva = VillageBot.founderEva(), adam = VillageBot.founderAdam()
        try store.saveVillageBots(JSONEncoder().encode([eva, adam]))
        try AgentVoiceSelection.save(AgentPCVoice.roestFreja.id, for: eva.id, store: store, defaults: defaults)
        try AgentVoiceSelection.save(AgentPCVoice.roestStorm.id, for: adam.id, store: store, defaults: defaults)
        let bots = try JSONDecoder().decode([VillageBot].self, from: store.villageBots)
        XCTAssertEqual(bots.map(\.voice), ["roest-freja", "roest-storm"])
        XCTAssertEqual(defaults.string(forKey: PhoneModels.agentVoiceKey(eva.id)), bots[0].voice)
        XCTAssertEqual(defaults.string(forKey: PhoneModels.agentVoiceKey(adam.id)), bots[1].voice)
        XCTAssertEqual(bots.compactMap { AgentPCVoice(rawValue: $0.voice)?.language }, ["da-DK", "da-DK"])
    }

    @MainActor func testLumiVoiceCanBeAssignedToAnotherAgentWithoutChangingLumi() throws {
        let suite = "SharedVoiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = MigratedAppData(defaults: defaults, store: LocalModelStore(root: folder))
        let eva = VillageBot.founderEva()
        try store.saveVillageBots(JSONEncoder().encode([eva]))
        let lumiKey = PhoneModels.agentVoiceKey(VillageBot.lumiID)
        defaults.set(AgentPCVoice.roestNic.rawValue, forKey: lumiKey)
        let privateVoice = AgentVoiceSelection.identifier(for: .lumi(), defaults: defaults)
        XCTAssertEqual(StudioVoiceChoice(studio: "", profile: privateVoice), .pc(.roestNic))
        try AgentVoiceSelection.save(AgentPCVoice.roestLumi.id, for: eva.id, store: store, defaults: defaults)
        let saved = try JSONDecoder().decode([VillageBot].self, from: store.villageBots)
        XCTAssertEqual(saved.first?.voice, AgentPCVoice.roestLumi.rawValue)
        XCTAssertEqual(defaults.string(forKey: lumiKey), AgentPCVoice.roestNic.rawValue)
    }

    func testDanishDictationPrefersDedicatedModelAndKeepsInstalledFallbacks() {
        XCTAssertEqual(AgentWhisper.availableModels(for: "da-DK", installed: { _ in true }), [.danish, .small, .base])
        XCTAssertEqual(AgentWhisper.availableModels(for: "da-DK", installed: { $0 == .base }), [.base])
        XCTAssertEqual(AgentWhisper.availableModels(for: "en-US", installed: { _ in true }), [.base, .small])
        XCTAssertTrue(AgentWhisper.availableModels(for: "en-US", installed: { $0 == .danish }).isEmpty)
    }

    func testSilentRecordingIsNotSentToTheWhisperDecoder() {
        let empty = [Float]()
        let quiet: [Float] = [0, -0.000001, 0.00003, .nan, .infinity]
        let quietVoice: [Float] = [0, -0.005, 0]
        XCTAssertFalse(empty.withUnsafeBufferPointer { AgentWhisper.hasMicrophoneSignal($0) })
        XCTAssertFalse(quiet.withUnsafeBufferPointer { AgentWhisper.hasMicrophoneSignal($0) })
        XCTAssertTrue(quietVoice.withUnsafeBufferPointer { AgentWhisper.hasMicrophoneSignal($0) })
    }

    func testWhisperReplacementPreservesAnOpenModel() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "model.bin")
        let download = folder.appending(path: "verified.bin")
        let old = Data("older".utf8)
        let replacement = Data("newer".utf8)
        try old.write(to: model)
        try replacement.write(to: download)
        let inUse = try FileHandle(forReadingFrom: model)
        defer { try? inUse.close() }

        try AgentWhisper.publishVerifiedDownload(download, to: model, within: folder, expectedBytes: replacement.count)

        XCTAssertEqual(try Data(contentsOf: model), replacement)
        XCTAssertEqual(try inUse.readToEnd(), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
    }

    func testRejectedWhisperReplacementLeavesTheModelAvailable() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "model.bin")
        let download = folder.appending(path: "truncated.bin")
        let old = Data("older".utf8)
        try old.write(to: model)
        try Data("bad".utf8).write(to: download)

        XCTAssertThrowsError(try AgentWhisper.publishVerifiedDownload(download, to: model, within: folder,
                                                                    expectedBytes: old.count))

        XCTAssertEqual(try Data(contentsOf: model), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["model.bin"])
    }

    func testExplicitVoiceIsNotReplacedWhenReplyLanguageChanges() throws {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: {
            !$0.voiceTraits.contains(.isPersonalVoice)
        }) else { throw XCTSkip("Simulator has no installed speech voices") }
        let otherLanguage = voice.language.hasPrefix("da") ? "en-US" : "da-DK"
        let resolved = AgentVoiceSelection.resolve(identifier: voice.identifier, language: otherLanguage)
        XCTAssertEqual(resolved?.identifier, voice.identifier)
    }

    func testMissingExplicitVoiceDoesNotSilentlyBecomeSystemVoice() {
        XCTAssertNil(AgentVoiceSelection.resolve(identifier: "fadedai.test.missing-voice", language: "da-DK"))
    }

    @MainActor func testOnlyCurrentAgentMovesAndOldCompletionCannotStopNewAgent() {
        let motion = VillageSpeechMotion()
        let adam = UUID(), eva = UUID()
        var interrupted = false
        let old = motion.begin(agentID: adam) { interrupted = true }
        motion.setSpeaking(true, owner: old)
        XCTAssertTrue(motion.isSpeaking(adam.uuidString))
        let current = motion.begin(agentID: eva) {}
        XCTAssertTrue(interrupted)
        motion.word(length: 6, rate: 1, owner: current)
        motion.end(owner: old)
        motion.setSpeaking(false, owner: old)
        XCTAssertTrue(motion.isSpeaking(eva.uuidString))
        XCTAssertFalse(motion.isSpeaking(adam.uuidString))
        motion.end(owner: current)
        XCTAssertNil(motion.agentID)
        XCTAssertNil(motion.pulse)
    }

    @MainActor func testPauseClosesMouthAndPreviewDoesNotAnimateAnAgent() {
        let motion = VillageSpeechMotion()
        let id = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let owner = motion.begin(agentID: id) {}
        motion.word(length: 10, rate: 1, owner: owner, at: date)
        XCTAssertGreaterThan(motion.mouth(for: id.uuidString, at: date.addingTimeInterval(0.1)), 0)
        motion.setSpeaking(false, owner: owner)
        XCTAssertEqual(motion.mouth(for: id.uuidString, at: date.addingTimeInterval(0.1)), 0)
        let preview = motion.begin(agentID: nil) {}
        motion.word(length: 10, rate: 1, owner: preview, at: date)
        XCTAssertNil(motion.pulse)
        XCTAssertFalse(motion.isSpeaking(id.uuidString))
        motion.setSpeaking(true, owner: preview)
        XCTAssertFalse(motion.isSpeaking("preview-bot-without-uuid"))
    }

    func testWordAnimationExpiresWithoutAnyMoreCallbacks() {
        let start = Date(timeIntervalSinceReferenceDate: 1)
        let pulse = SpeechMouthPulse(start: start, length: 100_000, rate: .nan)
        XCTAssertLessThanOrEqual(pulse.duration, 0.8)
        XCTAssertEqual(pulse.openness(at: start.addingTimeInterval(-1)), 0)
        XCTAssertGreaterThan(pulse.openness(at: start.addingTimeInterval(0.1)), 0)
        XCTAssertEqual(pulse.openness(at: start.addingTimeInterval(1)), 0)
    }

    func testAudioSilenceAndStalledMeterCloseTheMouth() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(SpeechAudioLevel(decibels: -60, date: date).openness(at: date), 0)
        let audible = SpeechAudioLevel(decibels: -20, date: date)
        XCTAssertGreaterThan(audible.openness(at: date), 0)
        XCTAssertEqual(audible.openness(at: date.addingTimeInterval(0.3)), 0)
        XCTAssertEqual(SpeechAudioLevel(decibels: .nan, date: date).openness(at: date), 0)
    }
}

@MainActor private final class DelayedChatMicrophone: ChatWhisperRecording {
    var holdPermission = false
    var permission: CheckedContinuation<Void, Never>?
    var decoding: CheckedContinuation<String, Error>?
    var limit: (@MainActor () -> Void)?
    var languages: [String] = []
    var cancellations = 0

    func start(language: String, silenceAfter: TimeInterval?, whenFull: @escaping @MainActor () -> Void) async throws {
        limit = whenFull
        if holdPermission { await withCheckedContinuation { permission = $0 } }
    }

    func finish(language: String) async throws -> String {
        languages.append(language)
        return try await withCheckedThrowingContinuation { decoding = $0 }
    }

    func cancel() { cancellations += 1 }
}

final class ChatWhisperContractTests: XCTestCase {
    @MainActor private func eventually(_ check: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !check(), ContinuousClock.now < deadline { await Task.yield() }
        return check()
    }

    @MainActor func testDurationAndManualStopDeliverOnceAndKeepTypedDraft() async throws {
        let input = ChatWhisperInput(), microphone = DelayedChatMicrophone()
        var draft = "En gammel kladde", deliveries = 0
        await input.start(microphone, language: "da-DK") { result in
            if let text = try? result.get() { draft = ChatWhisperInput.appending(text, to: draft) }
            deliveries += 1
        }
        XCTAssertEqual(input.phase, .recording)
        microphone.limit?()
        input.finish()
        let decoding = await eventually { microphone.decoding != nil }
        XCTAssertTrue(decoding)
        draft = "Husk torsdag:"
        try XCTUnwrap(microphone.decoding).resume(returning: "  klokken to  ")
        let completed = await eventually { input.phase == .idle }
        XCTAssertTrue(completed)
        XCTAssertEqual(draft, "Husk torsdag: klokken to")
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(microphone.languages, ["da-DK"])
        XCTAssertEqual(ChatWhisperInput.appending(" ", to: draft), draft)
        XCTAssertEqual(ChatWhisperInput.appending("mere", to: "Hej "), "Hej mere")
    }

    @MainActor func testChangingChatDuringPermissionIgnoresOldTimer() async throws {
        let input = ChatWhisperInput(), old = DelayedChatMicrophone(), next = DelayedChatMicrophone()
        old.holdPermission = true
        let first = Task { await input.start(old, language: "da") { _ in XCTFail("Den gamle chat fik et svar") } }
        let awaitingPermission = await eventually { old.permission != nil }
        XCTAssertTrue(awaitingPermission)
        input.cancel()
        await input.start(next, language: "en") { _ in XCTFail("Den nye optagelse blev afsluttet") }
        old.limit?()
        try XCTUnwrap(old.permission).resume()
        await first.value
        XCTAssertEqual(input.phase, .recording)
        XCTAssertTrue(old.languages.isEmpty)
        XCTAssertEqual(old.cancellations, 1)
        input.cancel()
    }

    @MainActor func testCancelledTranscriptCannotReplaceNewChatAndFailureAllowsRetry() async throws {
        let input = ChatWhisperInput(), old = DelayedChatMicrophone(), next = DelayedChatMicrophone()
        var results: [Result<String, Error>] = []
        await input.start(old, language: "da") { results.append($0) }
        input.finish()
        let firstDecode = await eventually { old.decoding != nil }
        XCTAssertTrue(firstDecode)
        input.cancel()
        await input.start(next, language: "en") { results.append($0) }
        input.finish()
        let secondDecode = await eventually { next.decoding != nil }
        XCTAssertTrue(secondDecode)
        try XCTUnwrap(old.decoding).resume(returning: "Tekst fra en lukket chat")
        try XCTUnwrap(next.decoding).resume(throwing: CocoaError(.fileReadCorruptFile))
        let completed = await eventually { input.phase == .idle }
        XCTAssertTrue(completed)
        XCTAssertEqual(results.count, 1)
        XCTAssertThrowsError(try XCTUnwrap(results.first).get())
        await input.start(DelayedChatMicrophone(), language: "da") { _ in XCTFail() }
        XCTAssertEqual(input.phase, .recording)
        input.cancel()
    }
}
