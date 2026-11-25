// ACE-Step 1.5 encoder weight-norm/layout conversion, based on the MIT-licensed
// upstream `acestep/models/mlx/vae_convert.py`. This does not generate songs.
import Foundation

enum SongReferenceEncoderError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return "Sangreferencens model kunne ikke klargøres: " + message }
        return "Sangreferencens model kunne ikke klargøres."
    }
}

/// Converts a verified, encoder-only BF16 file to an FP16 MLX Conv1d file.
/// It processes one output channel at a time, so it does not retain all model
/// weights or a complete FP16 output in RAM. The caller owns the staging URL.
enum SongReferenceEncoderConversion {
    private struct Spec {
        let shape: [Int]
        let start: UInt64
        let length: Int
    }
    private struct Output {
        enum Kind { case normalized(String, String), plain(String) }
        let shape: [Int]
        let elements: Int
        let kind: Kind
    }

    static func convert(input: URL, staging: URL, expectedInputCount: Int = 183,
                        expectedOutputCount: Int = 146) throws {
        let fm = FileManager.default
        guard input.isFileURL, staging.isFileURL,
              input.standardizedFileURL != staging.standardizedFileURL,
              !fm.fileExists(atPath: staging.path) else { throw SongReferenceEncoderError.invalid("Ugyldig midlertidig modelsti.") }
        try Task.checkCancellation()
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let fileSize = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard fileSize >= 8 else { throw SongReferenceEncoderError.invalid("Modelfilen er ufuldstændig.") }
        let lengthBytes = try readExact(source, count: 8)
        var headerLength: UInt64 = 0
        for i in 0..<8 { headerLength |= UInt64(lengthBytes[i]) << UInt64(i * 8) }
        guard headerLength <= 1_000_000, headerLength <= UInt64(fileSize - 8) else {
            throw SongReferenceEncoderError.invalid("Modellens header er ugyldig.")
        }
        let body = try readExact(source, count: Int(headerLength))
        guard let header = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SongReferenceEncoderError.invalid("Modellens header kan ikke læses.")
        }
        let base = UInt64(8) + headerLength
        var specs: [String: Spec] = [:]
        for (key, value) in header where key != "__metadata__" {
            guard key.hasPrefix("encoder."), let object = value as? [String: Any],
                  object["dtype"] as? String == "BF16", let shape = object["shape"] as? [Int],
                  let offsets = object["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= fileSize - Int(base) else {
                throw SongReferenceEncoderError.invalid("En modelvægt har ugyldig form.")
            }
            var elements = 1
            for dimension in shape {
                guard dimension > 0, elements <= fileSize / dimension else {
                    throw SongReferenceEncoderError.invalid("En modelvægt er for stor.")
                }
                elements *= dimension
            }
            guard elements <= fileSize / 2, offsets[1] - offsets[0] == elements * 2 else {
                throw SongReferenceEncoderError.invalid("En modelvægt er ufuldstændig.")
            }
            specs[key] = Spec(shape: shape, start: base + UInt64(offsets[0]), length: elements)
        }
        guard specs.count == expectedInputCount else { throw SongReferenceEncoderError.invalid("Modellen mangler vægte.") }
        var outputs: [String: Output] = [:]
        var consumed: Set<String> = []
        for key in specs.keys.sorted() {
            if consumed.contains(key) { continue }
            if key.hasSuffix(".weight_g") {
                let stem = String(key.dropLast(".weight_g".count))
                let v = stem + ".weight_v"
                guard let gspec = specs[key], let vspec = specs[v], vspec.shape.count == 3 else {
                    throw SongReferenceEncoderError.invalid("Modellen mangler et vægtpar.")
                }
                let (out, input, kernel) = (vspec.shape[0], vspec.shape[1], vspec.shape[2])
                guard gspec.shape == [out, 1, 1] else { throw SongReferenceEncoderError.invalid("Vægtparrets form passer ikke.") }
                outputs[stem + ".weight"] = Output(shape: [out, kernel, input], elements: vspec.length,
                                                     kind: .normalized(key, v))
                consumed.insert(key); consumed.insert(v)
            } else if key.hasSuffix(".weight_v") {
                throw SongReferenceEncoderError.invalid("Modellen mangler et vægtpar.")
            } else if key.hasSuffix(".bias") || key.hasSuffix(".alpha") || key.hasSuffix(".beta") {
                let spec = specs[key]!
                if key.hasSuffix(".bias") && spec.shape.count != 1 { throw SongReferenceEncoderError.invalid("En bias har forkert form.") }
                outputs[key] = Output(shape: key.hasSuffix(".bias") ? spec.shape : [spec.length],
                                      elements: spec.length, kind: .plain(key))
                consumed.insert(key)
            } else { throw SongReferenceEncoderError.invalid("Modellen indeholder en ukendt vægt.") }
        }
        guard outputs.count == expectedOutputCount, consumed.count == specs.count else {
            throw SongReferenceEncoderError.invalid("Modellens vægtantal passer ikke.")
        }
        var newHeader: [String: Any] = ["__metadata__": ["format": "mlx", "dtype": "float16", "component": "ace-step-1.5-vae-encoder"]]
        var offset = 0
        for key in outputs.keys.sorted() {
            let value = outputs[key]!
            guard value.elements <= (Int.max - offset) / 2 else { throw SongReferenceEncoderError.invalid("Modelvægt er for stor.") }
            let end = offset + value.elements * 2
            newHeader[key] = ["dtype": "F16", "shape": value.shape, "data_offsets": [offset, end]]
            offset = end
        }
        var newBody = try JSONSerialization.data(withJSONObject: newHeader, options: [.sortedKeys, .withoutEscapingSlashes])
        while newBody.count % 8 != 0 { newBody.append(32) }
        var prefix = Data()
        for index in 0..<8 { prefix.append(UInt8(truncatingIfNeeded: UInt64(newBody.count) >> UInt64(index * 8))) }
        prefix.append(newBody)
        try Data().write(to: staging, options: .withoutOverwriting)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: staging) } }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        try output.write(contentsOf: prefix)

        for key in outputs.keys.sorted() {
            try Task.checkCancellation()
            switch outputs[key]!.kind {
            case .plain(let original):
                let spec = specs[original]!
                try source.seek(toOffset: spec.start)
                var left = spec.length
                while left > 0 {
                    try Task.checkCancellation()
                    let count = min(left, 32_768)
                    let data = try readExact(source, count: count * 2)
                    try output.write(contentsOf: halfBytes(bf16Values(data), key: key))
                    left -= count
                }
            case .normalized(let gkey, let vkey):
                let gspec = specs[gkey]!, vspec = specs[vkey]!
                try source.seek(toOffset: gspec.start)
                let scales = try bf16Values(readExact(source, count: gspec.length * 2))
                let (out, channels, kernel) = (vspec.shape[0], vspec.shape[1], vspec.shape[2])
                let perChannel = channels * kernel
                try source.seek(toOffset: vspec.start)
                for channel in 0..<out {
                    try Task.checkCancellation()
                    let vector = try bf16Values(readExact(source, count: perChannel * 2))
                    var sum: Double = 0
                    for value in vector { sum += Double(value) * Double(value) }
                    let norm = Float(sum.squareRoot())
                    guard norm.isFinite, norm > 0 else { throw SongReferenceEncoderError.invalid("En modelvægt har ugyldig norm.") }
                    var converted = [Float](repeating: 0, count: perChannel)
                    for inputIndex in 0..<channels {
                        for k in 0..<kernel {
                            converted[k * channels + inputIndex] = scales[channel] * vector[inputIndex * kernel + k] / (norm + 1e-9)
                        }
                    }
                    try output.write(contentsOf: halfBytes(converted, key: key))
                }
            }
        }
        try Task.checkCancellation()
        try output.synchronize(); try output.close()
        guard try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize == prefix.count + offset else {
            throw SongReferenceEncoderError.invalid("Den klargjorte model er ufuldstændig.")
        }
        completed = true
    }

    private static func readExact(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            guard let bytes = try file.read(upToCount: count - result.count), !bytes.isEmpty else {
                throw SongReferenceEncoderError.invalid("En modelvægt er afbrudt.")
            }
            result.append(bytes)
        }
        return result
    }

    private static func bf16Values(_ data: Data) throws -> [Float] {
        var values: [Float] = []; values.reserveCapacity(data.count / 2)
        for i in stride(from: 0, to: data.count, by: 2) {
            let bits = UInt32(data[i]) | UInt32(data[i + 1]) << 8
            let value = Float(bitPattern: bits << 16)
            guard value.isFinite else { throw SongReferenceEncoderError.invalid("Modelvægten indeholder ugyldige tal.") }
            values.append(value)
        }
        return values
    }

    private static func halfBytes(_ values: [Float], key: String) throws -> Data {
        var result = Data(capacity: values.count * 2)
        for value in values {
            let half = Float16(value)
            guard half.isFinite else { throw SongReferenceEncoderError.invalid("En modelvægt er for stor.") }
            let bits = half.bitPattern
            result.append(UInt8(truncatingIfNeeded: bits)); result.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return result
    }
}
