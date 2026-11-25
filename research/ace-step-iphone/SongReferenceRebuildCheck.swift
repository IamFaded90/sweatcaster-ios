// PC-only entry point to test the runtime's safetensors reconstructor.
import Foundation

@main
struct SongReferenceRebuildCheck {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count == 7 else { fatalError("Expected manifest, component, header, range, output, header hash") }
        let data = try Data(contentsOf: URL(fileURLWithPath: a[1]))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let components = json["components"] as? [[String: Any]],
              let component = components.first(where: { $0["component"] as? String == a[2] }) else {
            fatalError("Invalid fixture manifest")
        }
        try RebuildSafeTensors.run(component: SourceComponent(component), headerURL: URL(fileURLWithPath: a[3]),
                                   fragmentURL: URL(fileURLWithPath: a[4]), outputURL: URL(fileURLWithPath: a[5]),
                                   headerSHA: a[6])
        print("PASS: runtime reconstructor completed")
    }
}
