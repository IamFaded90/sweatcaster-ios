// ACE-Step 1.5 remix routing. Apple compilation and device inference remain untested.
// Derived from ACE-Step's MIT-licensed task, mask and tokenizer handlers.
import Foundation

enum ReferenceContextFailure: Error {
    case invalidInput
}

/// A single item's text, ordinary cover or cover-nofsq route. This describes
/// the shaping and routing only; it does not run MLX, a VAE or an audio model.
struct ReferenceContextPlan {
    enum Mode: String, Codable { case text = "text2music", cover, rawCover = "cover-nofsq" }
    static let patchSize = 5
    static let minimumFrames = 128
    static let textInstruction = "Fill the audio semantic mask based on the given conditions:"
    static let coverInstruction = "Generate audio semantic tokens based on the given conditions:"

    let mode: Mode
    let sourceFrames: Int
    let channels: Int
    let steps: Int
    let strength: Double
    let targetFrames: Int
    let tokenizerPadding: Int
    let releaseAfter: Int?
    var instruction: String { mode == .text ? Self.textInstruction : Self.coverInstruction }
    var usesTokenizer: Bool { mode == .cover }

    init(mode: Mode, sourceFrames: Int, channels: Int, steps: Int, strength: Double) throws {
        // Restrict the research route to the iPhone studio's 180-second limit.
        guard (1...4500).contains(sourceFrames), (1...64).contains(channels),
              (1...20).contains(steps), strength.isFinite, (0...1).contains(strength)
        else { throw ReferenceContextFailure.invalidInput }
        self.mode = mode; self.sourceFrames = sourceFrames; self.channels = channels
        self.steps = steps; self.strength = strength
        targetFrames = max(Self.minimumFrames, sourceFrames)
        tokenizerPadding = (Self.patchSize - targetFrames % Self.patchSize) % Self.patchSize
        releaseAfter = strength < 1 ? Int(Double(steps) * strength) : nil
    }

    /// Target latents are padded from the *start* of the silence bed, as in
    /// ConditioningTargetMixin. `source` is interleaved frames × channels.
    func paddedTarget(source: [Float], silence: [Float]) throws -> [Float] {
        let sourceCount = sourceFrames * channels
        let padCount = (targetFrames - sourceFrames) * channels
        guard source.count == sourceCount, silence.count >= max(padCount, tokenizerPadding * channels),
              source.allSatisfy(\.isFinite), silence.allSatisfy(\.isFinite)
        else { throw ReferenceContextFailure.invalidInput }
        return source + silence.prefix(padCount)
    }

    /// ACE's tokenizer pads to five latent frames using the beginning of the
    /// silence bed. The attention mask is zero only for appended/padded frames.
    func tokenizerInput(target: [Float], silence: [Float]) throws -> (values: [Float], mask: [Float]) {
        guard target.count == targetFrames * channels, silence.count >= tokenizerPadding * channels,
              target.allSatisfy(\.isFinite), silence.allSatisfy(\.isFinite)
        else { throw ReferenceContextFailure.invalidInput }
        let values = target + silence.prefix(tokenizerPadding * channels)
        let mask = Array(repeating: Float(1), count: sourceFrames)
            + Array(repeating: Float(0), count: targetFrames - sourceFrames + tokenizerPadding)
        return (values, mask)
    }

    /// Full-span chunk mask is 1 on the current pinned PC handler, including
    /// auto mode, because its mask tensor is Boolean. Cover uses FSQ-decoded
    /// hints; text and cover-nofsq use the supplied source. Output shape is
    /// frames × (channels * 2), interleaved by frame.
    func context(source: [Float], hints: [Float]?) throws -> [Float] {
        let count = targetFrames * channels
        guard source.count == count, source.allSatisfy(\.isFinite) else { throw ReferenceContextFailure.invalidInput }
        let guide: [Float]
        if usesTokenizer {
            guard let hints, hints.count >= count, hints.prefix(count).allSatisfy(\.isFinite)
            else { throw ReferenceContextFailure.invalidInput }
            guide = Array(hints.prefix(count))
        } else { guide = source }
        var output: [Float] = []
        output.reserveCapacity(count * 2)
        for frame in 0..<targetFrames {
            let start = frame * channels
            output.append(contentsOf: guide[start..<(start + channels)])
            output.append(contentsOf: repeatElement(Float(1), count: channels))
        }
        return output
    }
}
