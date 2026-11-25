// Tests the standalone converter's failure behaviour; never part of the app.
import Foundation

@main
struct EncoderWeightsConvertFailureChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected converter and fixture directory") }
        let tool = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        func run(_ input: URL, _ output: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = tool
            process.arguments = [input.path, output.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for name in ["missing", "zero_norm", "nonfinite", "overflow", "wrong_shape"] {
            let output = root.appendingPathComponent("unexpected-\(name).safetensors")
            precondition(!FileManager.default.fileExists(atPath: output.path))
            let status = try run(root.appendingPathComponent(name + ".safetensors"), output)
            precondition(status != 0 && !FileManager.default.fileExists(atPath: output.path), "Invalid \(name) was accepted")
        }
        let existing = root.appendingPathComponent("python.safetensors")
        let before = try Data(contentsOf: existing)
        let status = try run(root.appendingPathComponent("input.safetensors"), existing)
        let after = try Data(contentsOf: existing)
        precondition(status != 0 && before == after, "Existing output was replaced")
        print("PASS: missing pair, zero norm, nonfinite, FP16 overflow, wrong shape and no overwrite")
    }
}
