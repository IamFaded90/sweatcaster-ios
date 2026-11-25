// PC-only executable checks for the standalone production converter.
import Foundation

@main
struct SongReferenceEncoderConversionChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = root.appendingPathComponent("swift.safetensors")
        try SongReferenceEncoderConversion.convert(input: root.appendingPathComponent("input.safetensors"),
                                                   staging: output, expectedInputCount: 8, expectedOutputCount: 6)
        for name in ["missing", "zero_norm", "nonfinite", "overflow", "wrong_shape"] {
            let path = root.appendingPathComponent("stream-invalid-\(name)")
            do {
                try SongReferenceEncoderConversion.convert(input: root.appendingPathComponent(name + ".safetensors"),
                                                           staging: path, expectedInputCount: 8, expectedOutputCount: 6)
                fatalError("Invalid case \(name) was accepted")
            } catch is SongReferenceEncoderError { }
            guard !FileManager.default.fileExists(atPath: path.path) else { fatalError("Invalid output remained") }
        }
        let oldOutput = try Data(contentsOf: output)
        do {
            try SongReferenceEncoderConversion.convert(input: root.appendingPathComponent("input.safetensors"),
                                                       staging: output, expectedInputCount: 8, expectedOutputCount: 6)
            fatalError("Existing output accepted")
        } catch is SongReferenceEncoderError { }
        guard try Data(contentsOf: output) == oldOutput else { fatalError("Existing output changed") }
        let cancelledOutput = root.appendingPathComponent("stream-cancelled")
        let task = Task {
            try SongReferenceEncoderConversion.convert(input: root.appendingPathComponent("input.safetensors"),
                                                       staging: cancelledOutput, expectedInputCount: 8, expectedOutputCount: 6)
        }
        task.cancel()
        do { try await task.value; fatalError("Cancelled conversion accepted") }
        catch is CancellationError { }
        guard !FileManager.default.fileExists(atPath: cancelledOutput.path) else { fatalError("Cancelled output remained") }
        print("PASS: fixture converted; invalid weights, overwrite and immediate cancellation rejected")
    }
}
