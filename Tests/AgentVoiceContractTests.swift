import AVFAudio
import XCTest
@testable import SweatCaster

final class AgentVoiceContractTests: XCTestCase {
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
