// Research-only ACE-Step Oobleck encoder conversion. Not in the app/build.
// Weight-norm and layout follow ACE-Step 1.5's MIT-licensed MLX converter.
// Reads a *previously verified* encoder-only BF16 safetensors file.
import Foundation

enum ConvertError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let message) = self { return message }; return "Conversion error" }
}

struct TensorSpec {
    let shape: [Int]
    let start: Int
    let end: Int
}

struct ConvertedTensor {
    let shape: [Int]
    let bytes: Data
}

enum EncoderWeightsConvert {
    static let maxInputBytes = 256 * 1024 * 1024

    static func run(input: URL, output: URL) throws {
        guard input.isFileURL, output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ConvertError.invalid("Input and new output must be distinct; refusing to overwrite")
        }
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 8, size <= maxInputBytes else { throw ConvertError.invalid("Input exceeds research limit or is truncated") }
        let file = try Data(contentsOf: input, options: .mappedIfSafe)
        var headerSize: UInt64 = 0
        for i in 0..<8 { headerSize |= UInt64(file[i]) << UInt64(i * 8) }
        guard headerSize <= 10_000_000, headerSize <= UInt64(file.count - 8) else {
            throw ConvertError.invalid("Invalid header length")
        }
        let dataStart = 8 + Int(headerSize)
        guard let header = try JSONSerialization.jsonObject(with: file.subdata(in: 8..<dataStart)) as? [String: Any] else {
            throw ConvertError.invalid("Invalid header")
        }
        var specs: [String: TensorSpec] = [:]
        for (name, value) in header where name != "__metadata__" {
            guard name.hasPrefix("encoder."), let desc = value as? [String: Any],
                  let dtype = desc["dtype"] as? String, dtype == "BF16",
                  let shape = desc["shape"] as? [Int], let offsets = desc["data_offsets"] as? [Int],
                  offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0],
                  offsets[1] <= file.count - dataStart else { throw ConvertError.invalid("Invalid tensor \(name)") }
            var count = 1
            for dimension in shape {
                guard dimension >= 0, count <= maxInputBytes / max(1, dimension) else {
                    throw ConvertError.invalid("Invalid shape \(name)")
                }
                count *= dimension
            }
            guard offsets[1] - offsets[0] == count * 2 else { throw ConvertError.invalid("Invalid byte count \(name)") }
            specs[name] = TensorSpec(shape: shape, start: offsets[0], end: offsets[1])
        }
        guard !specs.isEmpty else { throw ConvertError.invalid("No encoder tensors") }

        func values(_ name: String) throws -> [Float] {
            guard let spec = specs[name] else { throw ConvertError.invalid("Missing \(name)") }
            var result: [Float] = []
            result.reserveCapacity((spec.end - spec.start) / 2)
            for offset in stride(from: dataStart + spec.start, to: dataStart + spec.end, by: 2) {
                let bits = UInt32(file[offset]) | (UInt32(file[offset + 1]) << 8)
                let value = Float(bitPattern: bits << 16)
                guard value.isFinite else { throw ConvertError.invalid("Non-finite value in \(name)") }
                result.append(value)
            }
            return result
        }
        func halfBytes(_ values: [Float], _ name: String) throws -> Data {
            var bytes = Data(capacity: values.count * 2)
            for value in values {
                let half = Float16(value)
                guard half.isFinite else { throw ConvertError.invalid("FP16 overflow in \(name)") }
                let bits = half.bitPattern
                bytes.append(UInt8(truncatingIfNeeded: bits))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            return bytes
        }
        var result: [String: ConvertedTensor] = [:]
        var consumed: Set<String> = []
        for key in specs.keys.sorted() {
            if consumed.contains(key) { continue }
            if key.hasSuffix(".weight_g") {
                let base = String(key.dropLast(".weight_g".count))
                let vectorKey = base + ".weight_v"
                guard let gSpec = specs[key], let vSpec = specs[vectorKey], vSpec.shape.count == 3 else {
                    throw ConvertError.invalid("Missing weight-norm pair for \(base)")
                }
                let (out, inputChannels, kernel) = (vSpec.shape[0], vSpec.shape[1], vSpec.shape[2])
                guard out > 0, inputChannels > 0, kernel > 0, gSpec.shape == [out, 1, 1] else {
                    throw ConvertError.invalid("Invalid weight-norm shape for \(base)")
                }
                let scales = try values(key), vectors = try values(vectorKey)
                var fused = [Float](repeating: 0, count: vectors.count)
                for channel in 0..<out {
                    let begin = channel * inputChannels * kernel
                    var sum: Double = 0
                    for index in begin..<(begin + inputChannels * kernel) {
                        let value = Double(vectors[index]); sum += value * value
                    }
                    let norm = Float(sum.squareRoot())
                    guard norm.isFinite, norm > 0 else { throw ConvertError.invalid("Invalid norm for \(base)") }
                    for i in 0..<inputChannels {
                        for k in 0..<kernel {
                            let source = begin + i * kernel + k
                            let target = begin + k * inputChannels + i
                            fused[target] = scales[channel] * vectors[source] / (norm + 1e-9)
                        }
                    }
                }
                result[base + ".weight"] = ConvertedTensor(shape: [out, kernel, inputChannels],
                                                            bytes: try halfBytes(fused, base))
                consumed.insert(key); consumed.insert(vectorKey)
            } else if key.hasSuffix(".weight_v") {
                throw ConvertError.invalid("Missing weight-norm scale for \(key)")
            } else if key.hasSuffix(".alpha") || key.hasSuffix(".beta") || key.hasSuffix(".bias") {
                let numbers = try values(key)
                let shape = key.hasSuffix(".bias") ? specs[key]!.shape : [numbers.count]
                result[key] = ConvertedTensor(shape: shape, bytes: try halfBytes(numbers, key))
                consumed.insert(key)
            } else {
                throw ConvertError.invalid("Unsupported tensor \(key)")
            }
        }
        var outputHeader: [String: Any] = ["__metadata__": ["format": "mlx", "dtype": "float16", "component": "ace-step-1.5-vae-encoder"]]
        var offset = 0
        for key in result.keys.sorted() {
            let tensor = result[key]!
            outputHeader[key] = ["dtype": "F16", "shape": tensor.shape,
                                 "data_offsets": [offset, offset + tensor.bytes.count]]
            offset += tensor.bytes.count
        }
        var body = try JSONSerialization.data(withJSONObject: outputHeader, options: [.sortedKeys, .withoutEscapingSlashes])
        while body.count % 8 != 0 { body.append(32) }
        var outputData = Data(capacity: 8 + body.count + offset)
        let length = UInt64(body.count)
        for i in 0..<8 { outputData.append(UInt8(truncatingIfNeeded: length >> UInt64(i * 8))) }
        outputData.append(body)
        for key in result.keys.sorted() { outputData.append(result[key]!.bytes) }
        // Experimental: exclusive creation; a failed write may leave a partial
        // new output. Production must use a verified atomic staging strategy.
        try outputData.write(to: output, options: .withoutOverwriting)
        print("Converted \(specs.count) BF16 tensors to \(result.count) FP16 tensors")
    }
}

@main
struct EncoderWeightsConvertTool {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw ConvertError.invalid("Usage: EncoderWeightsConvert INPUT OUTPUT")
        }
        try EncoderWeightsConvert.run(input: URL(fileURLWithPath: CommandLine.arguments[1]),
                                      output: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
