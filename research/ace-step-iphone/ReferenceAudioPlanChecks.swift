// Standalone executable; fixtures were verified against the installed
// ACE-Step handler by check_reference_audio_plan.py. Not in production.
import Foundation

@main
struct ReferenceAudioPlanChecks {
    static func main() throws {
        typealias Fixture = (Int, Int, [[Int]])
        let fixtures: [Fixture] = [
            (1, 1_440_000, [[0,480_000,960_000], [0,480_000,960_000], [0,480_000,960_000]]),
            (480_000, 3, [[0,480_000,960_000], [0,480_000,960_000], [0,480_000,960_000]]),
            (1_439_999, 2, [[0,959_999,1_919_998], [239_999,1_199_998,2_159_998], [479_999,1_439_998,2_399_998]]),
            (1_440_000, 1, [[0,480_000,960_000], [0,480_000,960_000], [0,480_000,960_000]]),
            (1_800_001, 1, [[0,600_000,1_200_000], [60_000,660_000,1_260_000], [120_000,720_000,1_320_001]])
        ]
        for (length, repeats, expected) in fixtures {
            for choice in 0..<3 {
                let result = try ReferenceAudioPlan.make(originalFrames: length) { low, high in
                    choice == 0 ? low : choice == 1 ? low + (high - low) / 2 : high
                }
                precondition(result.repeats == repeats && result.starts == expected[choice],
                             "Mismatch for length \(length), selection \(choice): \(result)")
            }
        }
        for invalid in [0, -1] {
            do {
                _ = try ReferenceAudioPlan.make(originalFrames: invalid) { low, _ in low }
                preconditionFailure("Invalid frame count accepted")
            } catch ReferenceAudioPlanError.invalidFrameCount { }
        }
        do {
            _ = try ReferenceAudioPlan.make(originalFrames: 1_440_000) { _, high in high + 1 }
            preconditionFailure("Invalid random offset accepted")
        } catch ReferenceAudioPlanError.invalidOffset { }
        let maximum = try ReferenceAudioPlan.make(originalFrames: Int.max) { low, _ in low }
        precondition(maximum.repeats == 1 && maximum.starts[0] == 0)
        print("PASS: 15 PC-verified reference fixtures plus invalid-input and overflow checks")
        print("This does not test iOS audio decoding, resampling, MLX or song generation.")
    }
}
