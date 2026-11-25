// PC-only test of cancellation during runtime reconstruction.
import Foundation

@main
struct SongReferenceRebuildCancellationCheck {
    static func main() async throws {
        let a = CommandLine.arguments
        guard a.count == 6 else { fatalError("Expected manifest, header, fragment, new output and header hash") }
        let data = try Data(contentsOf: URL(fileURLWithPath: a[1]))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["components"] as? [[String: Any]],
              let object = values.first(where: { $0["component"] as? String == "vae_audio_encoder" }) else {
            fatalError("Invalid test manifest")
        }
        let component = try SourceComponent(object)
        let output = URL(fileURLWithPath: a[4])
        let task = Task.detached {
            try RebuildSafeTensors.run(component: component, headerURL: URL(fileURLWithPath: a[2]),
                                       fragmentURL: URL(fileURLWithPath: a[3]), outputURL: output, headerSHA: a[5])
        }
        let root = output.deletingLastPathComponent()
        var started = false
        for _ in 0..<2_000 {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            if files.contains(where: {
                $0.lastPathComponent.hasPrefix(".swift-rebuild-") &&
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000
            }) { started = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard started else { task.cancel(); fatalError("Rebuild did not start") }
        task.cancel()
        do { try await task.value; fatalError("Cancelled rebuild finished") }
        catch is CancellationError { }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard !FileManager.default.fileExists(atPath: output.path),
              !files.contains(where: { $0.lastPathComponent.hasPrefix(".swift-rebuild-") }) else {
            fatalError("Cancelled reconstruction left staging output")
        }
        print("PASS: cancelled after rebuild started; no incomplete output or staging remains")
    }
}
