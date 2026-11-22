import Foundation
import OnnxRuntimeBindings

/// A single speaker and a bounded passage, following the Supertonic 3 ONNX example.
/// https://github.com/supertone-inc/supertonic/tree/1e9799e964ea4c0dad7cde993b65c3c813a7b373
public final class SupertonicVoice {
    public enum Failure: Error { case invalidInput, invalidModel, invalidAudio }
    private struct Configuration: Decodable {
        struct AE: Decodable { let sample_rate, base_chunk_size: Int }
        struct TTL: Decodable { let chunk_compress_factor, latent_dim: Int }
        let ae: AE
        let ttl: TTL
    }
    private struct Style: Decodable {
        struct Component: Decodable { let data: [[[Float]]]; let dims: [Int] }
        let style_ttl, style_dp: Component
    }

    private let env: ORTEnv
    private let duration, encoder, estimator, vocoder: ORTSession
    private let config: Configuration
    private let alphabet: [Int64]
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        let onnx = directory.appendingPathComponent("onnx", isDirectory: true)
        let json = JSONDecoder()
        config = try json.decode(Configuration.self, from: Data(contentsOf: onnx.appendingPathComponent("tts.json")))
        alphabet = try json.decode([Int64].self, from: Data(contentsOf: onnx.appendingPathComponent("unicode_indexer.json")))
        guard config.ae.sample_rate == 44100, (1...4096).contains(config.ae.base_chunk_size),
              (1...16).contains(config.ttl.chunk_compress_factor), (1...256).contains(config.ttl.latent_dim)
        else { throw Failure.invalidModel }
        let environment = try ORTEnv(loggingLevel: .error)
        env = environment
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        func load(_ name: String) throws -> ORTSession {
            try ORTSession(env: environment, modelPath: onnx.appendingPathComponent(name + ".onnx").path,
                           sessionOptions: options)
        }
        duration = try load("duration_predictor")
        encoder = try load("text_encoder")
        estimator = try load("vector_estimator")
        vocoder = try load("vocoder")
    }

    public func render(_ text: String, style name: String, language: String, rate: Double = 1) throws -> Data {
        guard ["F1","F2","F3","F4","F5","M1","M2","M3","M4","M5"].contains(name),
              ["da", "en"].contains(language), rate.isFinite,
              (1...300).contains(text.unicodeScalars.count) else { throw Failure.invalidInput }
        try Task.checkCancellation()
        let styleURL = directory.appendingPathComponent("voice_styles").appendingPathComponent(name + ".json")
        let style = try JSONDecoder().decode(Style.self, from: Data(contentsOf: styleURL))
        func embed(_ component: Style.Component) throws -> ORTValue {
            let flat = component.data.flatMap { $0.flatMap { $0 } }
            guard component.dims.count == 3, component.dims[0] == 1,
                  component.dims.allSatisfy({ (1...4096).contains($0) }),
                  flat.count == component.dims.reduce(1, *) else { throw Failure.invalidModel }
            return try tensor(flat, .float, component.dims)
        }
        let styleDP = try embed(style.style_dp)
        let styleTTL = try embed(style.style_ttl)
        let normalized = preprocessText(text, lang: language)
        let ids = normalized.unicodeScalars.compactMap { c -> Int64? in
            let i = Int(c.value)
            guard i < alphabet.count, alphabet[i] >= 0 else { return nil }
            return alphabet[i]
        }
        let textIDs = try tensor(ids, .int64, [1, ids.count])
        let mask = try tensor([Float](repeating: 1, count: ids.count), .float, [1,1,ids.count])
        let shared = ["text_ids": textIDs, "text_mask": mask]
        let prediction = try output(duration, shared.merging(["style_dp": styleDP]) { $1 }, "duration")
        guard let durationSec = try floats(prediction).first else { throw Failure.invalidAudio }
        let seconds = durationSec / Float(min(max(rate, 0.7), 1.3) * 1.05)
        guard seconds.isFinite, seconds > 0, seconds <= 60 else { throw Failure.invalidAudio }
        let samples = Int(seconds * Float(config.ae.sample_rate))
        guard samples > 0 else { throw Failure.invalidAudio }
        let embedding = try output(encoder, shared.merging(["style_ttl": styleTTL]) { $1 }, "text_emb")
        let stride = config.ae.base_chunk_size * config.ttl.chunk_compress_factor
        let frames = (samples + stride - 1) / stride
        let channels = config.ttl.latent_dim * config.ttl.chunk_compress_factor
        let noise = (0..<(channels * frames)).map { _ -> Float in
            sqrt(-2 * log(Float.random(in: 0.0001...1))) * cos(2 * .pi * Float.random(in: 0...1))
        }
        var latent = try tensor(noise, .float, [1,channels,frames])
        let latentMask = try tensor([Float](repeating: 1, count: frames), .float, [1,1,frames])
        let steps = 5
        let total = try tensor([Float(steps)], .float, [1])
        for step in 0..<steps {
            try Task.checkCancellation()
            latent = try output(estimator, [
                "noisy_latent": latent, "text_emb": embedding, "style_ttl": styleTTL,
                "latent_mask": latentMask, "text_mask": mask, "total_step": total,
                "current_step": try tensor([Float(step)], .float, [1])
            ], "denoised_latent")
        }
        try Task.checkCancellation()
        let wave = try floats(output(vocoder, ["latent": latent], "wav_tts"))
        guard !wave.isEmpty else { throw Failure.invalidAudio }
        return makeWave(Array(wave.prefix(samples)), config.ae.sample_rate)
    }

    private func output(_ session: ORTSession, _ inputs: [String: ORTValue], _ name: String) throws -> ORTValue {
        guard let value = try session.run(withInputs: inputs, outputNames: [name], runOptions: nil)[name]
        else { throw Failure.invalidModel }
        return value
    }

    private func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ dimensions: [Int]) throws -> ORTValue {
        let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: bytes, elementType: type, shape: dimensions.map { NSNumber(value: $0) })
    }

    private func floats(_ tensor: ORTValue) throws -> [Float] {
        // ONNX returns a non-owning view of this tensor's result buffer.
        try withExtendedLifetime(tensor) {
            let bytes = try tensor.tensorData() as Data
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
}
