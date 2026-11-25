// Oobleck audio encoder used by ACE-Step 1.5.
// Architecture: https://github.com/xocialize/mlx-ace-step-swift (MIT),
// and the existing ACE-Step Python MLX implementation. Encoder weights must
// be converted separately; this experimental component is not yet wired to UI.
import Foundation
import MLX

/// Converts 48 kHz stereo audio to the 25 Hz posterior used for audio
/// conditioning. Unlike the decoder, this requires the encoder checkpoint.
/// Inputs are already resampled and aligned to the 1,920-sample latent hop.
struct ACEAudioEncoder {
    static let hopLength = 1920
    static let strides = [2, 4, 4, 6, 10]

    enum Failure: LocalizedError {
        case missingWeights([String])
        case invalidAudio
        case invalidNoise
        case invalidWindow

        var errorDescription: String? {
            switch self {
            case .missingWeights(let keys): return "Audio encoder weights are missing: \(keys.joined(separator: ", "))"
            case .invalidAudio: return "Expected 48 kHz stereo audio with one batch and a whole number of 1,920-sample frames."
            case .invalidNoise: return "Posterior noise must have the same shape as its mean."
            case .invalidWindow: return "Encoder window and overlap must be non-negative and the window must be positive."
            }
        }
    }

    let weights: [String: MLXArray]
    var dtype: DType = .float32

    init(weights: [String: MLXArray]) throws {
        var required = ["encoder.conv1.weight", "encoder.conv2.weight", "encoder.snake1.alpha", "encoder.snake1.beta"]
        for block in 0..<5 {
            let prefix = "encoder.block.\(block)"
            required += ["\(prefix).snake1.alpha", "\(prefix).snake1.beta", "\(prefix).conv1.weight"]
            for unit in 1...3 {
                let part = "\(prefix).res_unit\(unit)"
                required += ["\(part).snake1.alpha", "\(part).snake1.beta", "\(part).snake2.alpha", "\(part).snake2.beta", "\(part).conv1.weight", "\(part).conv2.weight"]
            }
        }
        let missing = required.filter { weights[$0] == nil }
        guard missing.isEmpty else { throw Failure.missingWeights(missing) }
        self.weights = weights
    }

    /// Returns [1, frames, 128]: 64 means followed by 64 raw scale values.
    /// Windowing is overlap/discard: avoid materializing full-rate hidden
    /// activations for a whole reference. Caller should measure peak memory on
    /// the device; no duration or quality guarantee is implied here.
    func moments(audio: MLXArray, coreFrames: Int = 48, overlapFrames: Int = 12) throws -> MLXArray {
        guard audio.shape.count == 3, audio.dim(0) == 1, audio.dim(2) == 2,
              audio.dim(1) > 0, audio.dim(1) % Self.hopLength == 0 else { throw Failure.invalidAudio }
        guard coreFrames > 0, overlapFrames >= 0 else { throw Failure.invalidWindow }
        let frames = audio.dim(1) / Self.hopLength
        var chunks: [MLXArray] = []
        var start = 0
        while start < frames {
            let end = min(start + coreFrames, frames)
            let lower = max(0, start - overlapFrames)
            let upper = min(frames, end + overlapFrames)
            let input = audio[0..., (lower * Self.hopLength)..<(upper * Self.hopLength), 0...].asType(dtype)
            let output = run(input)
            let kept = output[0..., (start - lower)..<(end - lower), 0...]
            eval(kept)
            chunks.append(kept)
            start = end
        }
        return chunks.count == 1 ? chunks[0] : concatenated(chunks, axis: 1)
    }

    /// Noise is explicit, so a fixed tensor can be compared with PyTorch.
    /// ACE's posterior uses softplus(scale), not exp(scale).
    func sample(moments: MLXArray, noise: MLXArray) throws -> MLXArray {
        guard moments.shape.count == 3, moments.dim(2) == 128 else { throw Failure.invalidNoise }
        let parts = moments.split(parts: 2, axis: 2)
        guard noise.shape == parts[0].shape else { throw Failure.invalidNoise }
        let scale = parts[1].asType(.float32)
        let standardDeviation = MLX.where(scale .> Float(20), scale, log(1 + exp(scale))) + Float(1e-4)
        return parts[0].asType(.float32) + standardDeviation * noise.asType(.float32)
    }

    private func run(_ audio: MLXArray) -> MLXArray {
        var h = convolve(audio, prefix: "encoder.conv1", kernel: 7, dilation: 1)
        for (index, stride) in Self.strides.enumerated() {
            let prefix = "encoder.block.\(index)"
            for (unit, dilation) in [(1, 1), (2, 3), (3, 9)] {
                h = residual(h, prefix: "\(prefix).res_unit\(unit)", dilation: dilation)
                eval(h)
            }
            h = snake(h, prefix: "\(prefix).snake1")
            h = convolve(h, prefix: "\(prefix).conv1", kernel: 2 * stride, dilation: 1, stride: stride, padding: (stride + 1) / 2)
            eval(h)
        }
        return convolve(snake(h, prefix: "encoder.snake1"), prefix: "encoder.conv2", kernel: 3, dilation: 1)
    }

    private func residual(_ x: MLXArray, prefix: String, dilation: Int) -> MLXArray {
        var h = convolve(snake(x, prefix: "\(prefix).snake1"), prefix: "\(prefix).conv1", kernel: 7, dilation: dilation)
        h = convolve(snake(h, prefix: "\(prefix).snake2"), prefix: "\(prefix).conv2", kernel: 1, dilation: 1)
        let trim = (x.dim(1) - h.dim(1)) / 2
        return (trim > 0 ? x[0..., trim..<(x.dim(1) - trim), 0...] : x) + h
    }

    private func convolve(_ x: MLXArray, prefix: String, kernel: Int, dilation: Int, stride: Int = 1, padding: Int? = nil) -> MLXArray {
        var y = conv1d(x, weights["\(prefix).weight"]!.asType(dtype), stride: stride,
                       padding: padding ?? ((kernel - 1) * dilation) / 2, dilation: dilation)
        if let bias = weights["\(prefix).bias"] { y = y + bias.asType(dtype) }
        return y
    }

    private func snake(_ x: MLXArray, prefix: String) -> MLXArray {
        let alpha = exp(weights["\(prefix).alpha"]!.asType(dtype).reshaped(1, 1, -1))
        let beta = exp(weights["\(prefix).beta"]!.asType(dtype).reshaped(1, 1, -1))
        return Self.fusedSnake(x, alpha, beta)
    }

    private static let fusedSnake = compile(shapeless: true) {
        (x: MLXArray, alpha: MLXArray, beta: MLXArray) -> MLXArray in
        let value = sin(alpha * x)
        return x + (value * value) / (beta + 1e-9)
    }
}
