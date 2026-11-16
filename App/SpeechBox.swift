// Bevarer én talesyntetisator gennem SwiftUI-visningens levetid.

import AVFAudio
import Foundation
import SwiftUI

final class SpeechBox: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Playback: Equatable {
        case reply(UUID), preview
    }

    final class WordProgress: ObservableObject {
        struct Position {
            let text: String
            let range: NSRange
        }

        @Published fileprivate(set) var position: Position?
    }

    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var playback: Playback?
    @Published private(set) var isSpeaking = false
    let wordProgress = WordProgress()
    private var currentUtterance: AVSpeechUtterance?
    private var motionOwner: UUID?
    var voiceName: String? { currentUtterance?.voice?.name }

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    @MainActor func play(_ utterance: AVSpeechUtterance, as playback: Playback, agentID: UUID? = nil) {
        stop()
        motionOwner = VillageSpeechMotion.shared.begin(agentID: agentID) { [weak self] in self?.stop() }
        currentUtterance = utterance
        self.playback = playback
        synthesizer.speak(utterance)
    }

    @MainActor func stop() {
        clearPlayback()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        setSpeaking(true, for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        setSpeaking(false, for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        setSpeaking(true, for: utterance)
    }

    private func setSpeaking(_ speaking: Bool, for utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let currentUtterance, ObjectIdentifier(currentUtterance) == identifier else { return }
            isSpeaking = speaking
            if let motionOwner { VillageSpeechMotion.shared.setSpeaking(speaking, owner: motionOwner) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let currentUtterance, ObjectIdentifier(currentUtterance) == identifier else { return }
            if let motionOwner {
                let rate = Double(currentUtterance.rate / AVSpeechUtteranceDefaultSpeechRate)
                VillageSpeechMotion.shared.word(length: characterRange.length, rate: rate, owner: motionOwner)
            }
            if case .reply(_)? = playback {
                wordProgress.position = .init(text: currentUtterance.speechString, range: characterRange)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete(utterance)
    }

    private func complete(_ utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let currentUtterance, ObjectIdentifier(currentUtterance) == identifier else { return }
            clearPlayback()
        }
    }

    @MainActor private func clearPlayback() {
        if let motionOwner { VillageSpeechMotion.shared.end(owner: motionOwner) }
        motionOwner = nil
        currentUtterance = nil
        if wordProgress.position != nil { wordProgress.position = nil }
        if isSpeaking { isSpeaking = false }
        if playback != nil { playback = nil }
    }
}
