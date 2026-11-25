// PC-only test: cancel a real, streaming encoder conversion after staging starts.
import Foundation

@main
struct SongReferenceEncoderCancellationCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected input and new output") }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let task = Task.detached { try SongReferenceEncoderConversion.convert(input: input, staging: output) }
        var started = false
        for _ in 0..<200 {
            if let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 32_768 {
                started = true; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard started else { task.cancel(); fatalError("Conversion did not start in time") }
        task.cancel()
        do { try await task.value; fatalError("Cancelled conversion finished") }
        catch is CancellationError { }
        guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Cancelled staging file remained") }
        print("PASS: cancelled after output began; incomplete staging file removed")
    }
}
