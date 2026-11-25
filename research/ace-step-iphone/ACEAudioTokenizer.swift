// Experimental port of ACE-Step 1.5's audio-tokenizer path.
// Architecture and FSQ math adapted from xocialize/mlx-ace-step-swift,
// Sources/ACEStepCore/Model/AudioTokens.swift (MIT). NOT included in a target.
// Expects the existing OfflineSongRuntime ACEEncoderStack in the same module.
import Foundation
import MLX

/// 25 Hz acoustic latents → 5 Hz FSQ token IDs. This is the missing tokenizer,
/// not the existing ACEHints detokenizer. Requires its own checkpoint weights.
struct ACEAudioTokenizer {
    static let framesPerCode = 5
    static let hiddenSize = 2048
    static let levels: [Float] = [8, 8, 8, 5, 5, 5]

    enum Failure: LocalizedError {
        case missingWeights([String])
        case invalidInput
        case invalidChunk

        var errorDescription: String? {
            switch self {
            case .missingWeights(let keys): return "Audio tokenizer weights are missing: \(keys.joined(separator: ", "))"
            case .invalidInput: return "Expected [1, frames, 64] latent audio with frames divisible by five."
            case .invalidChunk: return "Tokenizer chunk size must be positive."
            }
        }
    }

    let weights: [String: MLXArray]

    init(weights: [String: MLXArray]) throws {
        var required = ["tokenizer.audio_acoustic_proj.weight", "tokenizer.audio_acoustic_proj.bias",
                        "tokenizer.attention_pooler.embed_tokens.weight", "tokenizer.attention_pooler.embed_tokens.bias",
                        "tokenizer.attention_pooler.special_token", "tokenizer.attention_pooler.norm.weight",
                        "tokenizer.quantizer.project_in.weight", "tokenizer.quantizer.project_in.bias",
                        "tokenizer.quantizer.project_out.weight", "tokenizer.quantizer.project_out.bias"]
        for layer in 0..<2 {
            let prefix = "tokenizer.attention_pooler.layers.\(layer)"
            for part in ["input_layernorm", "post_attention_layernorm"] { required.append("\(prefix).\(part).weight") }
            for part in ["q_proj", "k_proj", "v_proj", "o_proj", "q_norm", "k_norm"] { required.append("\(prefix).self_attn.\(part).weight") }
            for part in ["gate_proj", "up_proj", "down_proj"] { required.append("\(prefix).mlp.\(part).weight") }
        }
        let missing = required.filter { weights[$0] == nil }
        guard missing.isEmpty else { throw Failure.missingWeights(missing) }
        self.weights = weights
    }

    /// Returns [1, frames/5] int32 code IDs and [1, frames/5, 2048]
    /// quantized vectors. Small chunks limit attention activation memory.
    /// Latents must already be padded to a complete five-frame patch.
    func tokenize(latents: MLXArray, chunkCodes: Int = 32) throws -> (codes: MLXArray, quantized: MLXArray) {
        guard latents.shape.count == 3, latents.dim(0) == 1, latents.dim(2) == 64,
              latents.dim(1) > 0, latents.dim(1) % Self.framesPerCode == 0 else { throw Failure.invalidInput }
        guard chunkCodes > 0 else { throw Failure.invalidChunk }

        let count = latents.dim(1) / Self.framesPerCode
        let stack = ACEEncoderStack(weights: weights, prefix: "tokenizer.attention_pooler", layerCount: 2)
        let special = weight("tokenizer.attention_pooler.special_token")
        var codePieces: [MLXArray] = []
        var quantizedPieces: [MLXArray] = []
        for start in stride(from: 0, to: count, by: chunkCodes) {
            let end = min(start + chunkCodes, count)
            let n = end - start
            let input = latents[0..., (start * Self.framesPerCode)..<(end * Self.framesPerCode), 0...]
            let projected = linear(input, "tokenizer.audio_acoustic_proj")
                .reshaped(n, Self.framesPerCode, Self.hiddenSize)
            let embedded = stack.embed(projected)
            let cls = MLXArray.ones([n, 1, 1], dtype: .float32) * special
            let pooled = stack.encode(embedded: concatenated([cls, embedded], axis: 1))[0..., 0, 0...]
                .reshaped(1, n, Self.hiddenSize)
            let (codes, quantized) = quantize(pooled)
            eval(codes, quantized)
            codePieces.append(codes)
            quantizedPieces.append(quantized)
        }
        return (codePieces.count == 1 ? codePieces[0] : concatenated(codePieces, axis: 1),
                quantizedPieces.count == 1 ? quantizedPieces[0] : concatenated(quantizedPieces, axis: 1))
    }

    /// Symmetry-preserving scalar quantization and mixed-radix code packing.
    /// Arithmetic is deliberately float32, matching ResidualFSQ inference.
    private func quantize(_ input: MLXArray) -> (MLXArray, MLXArray) {
        let levels = MLXArray(Self.levels, [1, 1, 6])
        let basis = MLXArray([Float(1), 8, 64, 512, 2560, 12800], [1, 1, 6])
        let softClamp = 1 + 1 / (levels - 1)
        var z = linear(input, "tokenizer.quantizer.project_in").asType(.float32)
        z = tanh(z / softClamp) * softClamp
        z = clip(z, min: -1, max: 1)
        let bracket = floor((levels - 1) * (z + 1) / 2 + 0.5)
        let scalarCodes = (2 / (levels - 1)) * bracket - 1
        let ids = ((scalarCodes + 1) / (2 / (levels - 1)) * basis).sum(axis: -1).round().asType(.int32)
        let quantized = linear(scalarCodes, "tokenizer.quantizer.project_out")
        return (ids, quantized)
    }

    private func weight(_ key: String) -> MLXArray { weights[key]!.asType(.float32) }
    private func linear(_ x: MLXArray, _ prefix: String) -> MLXArray {
        matmul(x.asType(.float32), weight("\(prefix).weight").T) + weight("\(prefix).bias")
    }
}
