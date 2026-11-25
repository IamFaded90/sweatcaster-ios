// Test the actual runtime initializers against metadata from real local weights.
// MLX is a no-math stub here: this does not perform inference or validate dtype.
import Foundation
import MLX

struct ACEEncoderStack {
    init(weights: [String: MLXArray], prefix: String, layerCount: Int) {}
    func embed(_ input: MLXArray) -> MLXArray { input }
    func encode(embedded: MLXArray) -> MLXArray { embedded }
}

struct ShapeFixture: Decodable {
    let encoder, tokenizer: [String: [Int]]
}

enum CheckFailure: Error { case wrongResult(String) }

@main struct ReferenceWeightShapeChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.wrongResult("fixture path missing") }
        let fixture = try JSONDecoder().decode(ShapeFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var encoder = fixture.encoder.mapValues { MLXArray(shape: $0) }
        var tokenizer = fixture.tokenizer.mapValues { MLXArray(shape: $0) }
        guard encoder.count == 146, tokenizer.count == 32 else { throw CheckFailure.wrongResult("incomplete model metadata") }
        _ = try ACEAudioEncoder(weights: encoder)
        _ = try ACEAudioTokenizer(weights: tokenizer)
        encoder.removeValue(forKey: "encoder.conv1.bias")
        do { _ = try ACEAudioEncoder(weights: encoder); throw CheckFailure.wrongResult("missing encoder bias accepted") }
        catch ACEAudioEncoder.Failure.missingWeights { }
        encoder["encoder.conv1.bias"] = MLXArray(shape: [1])
        do { _ = try ACEAudioEncoder(weights: encoder); throw CheckFailure.wrongResult("bad encoder shape accepted") }
        catch ACEAudioEncoder.Failure.invalidWeights { }
        tokenizer.removeValue(forKey: "tokenizer.quantizer.project_in.bias")
        do { _ = try ACEAudioTokenizer(weights: tokenizer); throw CheckFailure.wrongResult("missing tokenizer bias accepted") }
        catch ACEAudioTokenizer.Failure.missingWeights { }
        tokenizer["tokenizer.quantizer.project_in.bias"] = MLXArray(shape: [1])
        do { _ = try ACEAudioTokenizer(weights: tokenizer); throw CheckFailure.wrongResult("bad tokenizer shape accepted") }
        catch ACEAudioTokenizer.Failure.invalidWeights { }
        print("PASS: actual 146 encoder and 32 tokenizer shapes; missing and invalid weights rejected")
    }
}
