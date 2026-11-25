// Platform-independent frame selection for ACE-Step 1.5's timbre reference.
// Based on ACE-Step's IoAudioMixin.process_reference_audio (MIT).
// Kept separate from the existing text-to-song path.
import Foundation

enum ReferenceAudioPlanError: Error, Equatable {
    case invalidFrameCount
    case invalidOffset
}

struct ReferenceAudioPlan: Equatable {
    static let sampleRate = 48_000
    static let segmentFrames = 10 * sampleRate
    static let targetFrames = 3 * segmentFrames

    let originalFrames: Int
    let repeats: Int
    /// Indices into the virtually repeated input, inclusive segment starts.
    let starts: [Int]

    /// The caller supplies an inclusive RNG, so tests can use fixed offsets.
    /// Frame counts refer to audio already normalized to 48 kHz stereo.
    static func make(originalFrames: Int,
                     chooseOffset: (Int, Int) throws -> Int) throws -> Self {
        guard originalFrames > 0 else { throw ReferenceAudioPlanError.invalidFrameCount }
        // Quotient + remainder avoids overflowing for a very large frame count.
        let needed = targetFrames / originalFrames
            + (targetFrames % originalFrames == 0 ? 0 : 1)
        let repeats = max(1, needed)
        let total = originalFrames * repeats
        let size = total / 3
        let ranges = [(0, size), (size, size), (2 * size, total - 2 * size)]
        var starts: [Int] = []
        for (base, available) in ranges {
            let upper = max(0, available - segmentFrames)
            let offset = try chooseOffset(0, upper)
            guard (0...upper).contains(offset) else { throw ReferenceAudioPlanError.invalidOffset }
            starts.append(base + offset)
        }
        return Self(originalFrames: originalFrames, repeats: repeats, starts: starts)
    }
}
