// Standalone synthetic negative tests for the research-only reconstructor.
import Foundation

@main
struct RebuildSafeTensorsFailureChecks {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Expected tool, fixture directory and pinned header hash") }
        let tool = URL(fileURLWithPath: args[1])
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let headerHash = args[3]
        let manifest = root.appendingPathComponent("synthetic-manifest.json")
        let original = root.appendingPathComponent("synthetic-python.safetensors")
        let baseline = try Data(contentsOf: original)
        func run(header: String, fragment: String, output: URL) throws -> Int32 {
            let p = Process()
            p.executableURL = tool
            p.arguments = [manifest.path, "fixture", root.appendingPathComponent(header).path,
                           root.appendingPathComponent(fragment).path, output.path, headerHash]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        for (name, header, fragment) in [("header", "bad-header", "synthetic-fragment"),
                                         ("range", "synthetic-header", "bad-fragment")] {
            let output = root.appendingPathComponent("unexpected-\(name)")
            let status = try run(header: header, fragment: fragment, output: output)
            precondition(status != 0 && !FileManager.default.fileExists(atPath: output.path), "Corrupt \(name) accepted")
        }
        let status = try run(header: "synthetic-header", fragment: "synthetic-fragment", output: original)
        let after = try Data(contentsOf: original)
        precondition(status != 0 && baseline == after, "Existing output was overwritten")
        print("PASS: corrupt header/range and existing output rejected")
    }
}
