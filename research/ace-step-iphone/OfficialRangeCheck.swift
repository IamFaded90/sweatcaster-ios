// Research-only, bounded 64 KiB check against the pinned official source.
// The expected bytes must be read from the separately whole-file-verified PC
// checkpoint. This is not in the app and downloads no full model.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class RedirectCounter {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct OfficialRangeCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Expected component, reference file and partial output") }
        let component = CommandLine.arguments[1]
        let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard expected.count == 65_536 else { fatalError("Invalid reference size") }
        let name: String, offset: Int64, total: Int64, etag: String
        switch component {
        case "vae":
            name = "vae/diffusion_pytorch_model.safetensors"; offset = 168_868_700; total = 337_431_388
            etag = "\"e8d754cd5cb69cf864a2d44a61b39bf61354ebac7fc70680bbfdb8ed49b1bc8b\""
        case "tokenizer":
            name = "acestep-v15-turbo/model.safetensors"; offset = 4_577_761_208; total = 4_787_825_604
            etag = "\"077d06c5a16c9f9ff327389b66b0dd355fe3b8f7ad2777ef6767cbd9022d2a7c\""
        default: fatalError("Unknown component")
        }
        let source = URL(string: "https://huggingface.co/ACE-Step/Ace-Step1.5/resolve/571cee88618ae5ef3d3fcdf79c46068ce4e2d727/" + name)!
        let partial = URL(fileURLWithPath: CommandLine.arguments[3])
        let redirects = RedirectCounter()
        let downloader = RangeFileDownload(chunkBytes: 65_536) { _ in redirects.record() }
        let result = try await downloader.fetch(url: source, partial: partial, size: 65_536,
                                                sourceOffset: offset, sourceBytes: total, strongETag: etag) {
            try Data(contentsOf: $0) == expected
        }
        let actual = try Data(contentsOf: result)
        guard actual == expected else { fatalError("Downloaded bytes do not match verified local checkpoint") }
        let redirectCount = redirects.count()
        guard redirectCount > 0 else { fatalError("Expected at least one redirect") }
        print("Redirects followed: \(redirectCount)")
        print("PASS: 65,536 official range bytes equal the independently verified local checkpoint")
        print("Linux URLSession test only; no iPhone or full-model-download test.")
    }
}
