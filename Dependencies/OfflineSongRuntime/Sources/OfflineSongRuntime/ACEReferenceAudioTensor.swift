#if canImport(AVFAudio)
import Foundation
import AVFAudio
import MLX

/// Bridges a bounded, normalized temporary WAV into the audio encoder's
/// [batch, frames, stereo] layout. The source and its temporary copy are never
/// modified. Apple audio decoding and actual peak RAM need device validation.
enum ACEReferenceAudioTensor {
    enum Failure: LocalizedError {
        case invalidDuration, sourceTooShort, unreadableAudio
        var errorDescription: String? {
            switch self {
            case .invalidDuration: return "Vælg en sanglængde mellem 10 og 180 hele sekunder."
            case .sourceTooShort: return "Remixet kan ikke være længere end lydfilen. Vælg en længere fil eller en kortere sang."
            case .unreadableAudio: return "Lydfilen kunne ikke forberedes på iPhone."
            }
        }
    }

    /// Create the PC-equivalent three 10-second timbre selections. Short clips
    /// repeat virtually, so even a short recording needs no expanded WAV copy.
    static func timbre(source: URL, scratch: URL) async throws -> MLXArray {
        let prepared = try await ACEReferenceAudioLoader.prepare(source, in: scratch, maxSeconds: 180)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        try Task.checkCancellation()
        let plan = try ReferenceAudioPlan.make(originalFrames: prepared.info.originalFrames) { lower, upper in
            Int.random(in: lower...upper)
        }
        let file = try AVAudioFile(forReading: prepared.url)
        var output: [Float] = []
        output.reserveCapacity(ReferenceAudioPlan.targetFrames * 2)
        for start in plan.starts {
            var position = start
            var remaining = ReferenceAudioPlan.segmentFrames
            while remaining > 0 {
                try Task.checkCancellation()
                let offset = position % plan.originalFrames
                let count = min(remaining, plan.originalFrames - offset, 8_192)
                try append(file: file, start: offset, count: count, to: &output)
                position += count
                remaining -= count
            }
        }
        guard output.count == ReferenceAudioPlan.targetFrames * 2 else { throw Failure.unreadableAudio }
        return MLXArray(output).reshaped(1, ReferenceAudioPlan.targetFrames, 2)
    }

    /// Use exactly the requested prefix for a remix; don't silently pad a
    /// shorter source into a different piece of music.
    static func remix(source: URL, scratch: URL, seconds: Double) async throws -> MLXArray {
        guard seconds.isFinite, (10...180).contains(seconds), seconds.rounded(.down) == seconds else {
            throw Failure.invalidDuration
        }
        let prepared = try await ACEReferenceAudioLoader.prepare(source, in: scratch, maxSeconds: seconds)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let required = Int(seconds) * ACEReferencePCM.sampleRate
        // A decoder/resampler can end a nominally exact clip a few samples
        // short. Accept at most one 40 ms hop, already padded by the loader.
        let missing = max(0, required - prepared.info.originalFrames)
        guard missing <= ACEReferencePCM.hop, prepared.info.alignedFrames >= required else {
            throw Failure.sourceTooShort
        }
        let file = try AVAudioFile(forReading: prepared.url)
        var output: [Float] = []
        output.reserveCapacity(required * 2)
        var position = 0
        while position < required {
            try Task.checkCancellation()
            let count = min(required - position, 8_192)
            try append(file: file, start: position, count: count, to: &output)
            position += count
        }
        guard output.count == required * 2 else { throw Failure.unreadableAudio }
        return MLXArray(output).reshaped(1, required, 2)
    }

    private static func append(file: AVAudioFile, start: Int, count: Int,
                               to output: inout [Float]) throws {
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)) else { throw Failure.unreadableAudio }
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard Int(buffer.frameLength) == count, let channels = buffer.floatChannelData,
              file.processingFormat.channelCount == 2 else { throw Failure.unreadableAudio }
        for index in 0..<count {
            output.append(channels[0][index])
            output.append(channels[1][index])
        }
    }
}
#endif
