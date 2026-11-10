// Bevarer én talesyntetisator gennem SwiftUI-visningens levetid.

import AVFAudio
import Foundation
import SwiftUI

final class SpeechBox: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Playback: Equatable {
        case reply(UUID), preview
    }

    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var playback: Playback?
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    @MainActor func play(_ utterance: AVSpeechUtterance, as playback: Playback) {
        stop()
        currentUtterance = utterance
        self.playback = playback
        synthesizer.speak(utterance)
    }

    @MainActor func stop() {
        currentUtterance = nil
        if playback != nil { playback = nil }
        synthesizer.stopSpeaking(at: .immediate)
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
            self.currentUtterance = nil
            self.playback = nil
        }
    }
}
