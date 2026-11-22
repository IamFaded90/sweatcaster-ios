// Bevarer én talesyntetisator gennem SwiftUI-visningens levetid.

import AVFAudio
import Foundation
import SwiftUI

/// Render a short room status with the agent's selected system voice before stereo playback.
@MainActor enum VillageRoomSpeechAudio {
    static func render(_ utterance: AVSpeechUtterance) async throws -> Data {
        let synth = AVSpeechSynthesizer()
        let output = VillageRoomSpeechFile()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            output.fail(URLError(.timedOut))
        }
        defer {
            timeout.cancel()
            synth.stopSpeaking(at: .immediate)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard output.start(continuation) else { return }
                // A nonisolated callback receives short-lived buffers on AVFAudio's queue.
                synth.write(utterance, toBufferCallback: output.receive)
            }
        } onCancel: {
            output.fail(CancellationError())
        }
    }
}

/// AVFAudio may call back while the view is disappearing. The lock covers both the file and its single completion.
final class VillageRoomSpeechFile: @unchecked Sendable {
    private let lock = NSLock()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(UUID()).caf")
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    func start(_ awaiting: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { awaiting.resume(throwing: CancellationError()); return false }
        continuation = awaiting
        return true
    }

    func receive(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        do {
            guard let pcm = buffer as? AVAudioPCMBuffer else { throw APIError.malformed }
            if pcm.frameLength == 0 {
                guard file != nil else { throw APIError.malformed }
                file = nil
                finish(.success(try Data(contentsOf: url)))
                return
            }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            finish(.failure(error))
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if !finished { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        finished = true
        file = nil
        try? FileManager.default.removeItem(at: url)
        continuation?.resume(with: result)
        continuation = nil
    }
}

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
        MusicPlayer.shared.pause()
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
