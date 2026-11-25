import Foundation

/// Pinned ACE-Step 1.5 2B releases. Exact sizes detect incomplete files.
/// Upstream publishes no SHA256 manifest; these are not cryptographic checksums.
struct PhoneSongAsset {
    let path: String
    let bytes: Int64
    let release: String
    var assetName: String? = nil
    var url: URL { URL(string: "https://github.com/yu314-coder/WhisperKit/releases/download/\(release)/\(assetName ?? path)")! }
    func present(at root: URL) -> Bool {
        let values = try? root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        return values?.isSymbolicLink != true && Int64(values?.fileSize ?? -1) == bytes
    }
    static let all: [Self] = {
        var result = [
            Self(path: "ace_qwen_f16.safetensors", bytes: 1_191_586_112, release: "acestep-v2"),
            Self(path: "ace_vae_f16.safetensors", bytes: 168_807_360, release: "acestep-v2"),
            Self(path: "ace_silence_full.safetensors", bytes: 1_920_128, release: "acestep-v2"),
            Self(path: "ace_vocab.json", bytes: 2_776_833, release: "acestep-v2"),
            Self(path: "ace_merges.txt", bytes: 1_671_853, release: "acestep-v2"),
            Self(path: "ace_cond_f16.safetensors", bytes: 1_216_753_088, release: "acestep-v4"),
            Self(path: "ace_hints_f16.safetensors", bytes: 211_591_744, release: "acestep-v4"),
            Self(path: "ace_lm_bf16.part1.safetensors", bytes: 1_896_403_904, release: "acestep-v4"),
            Self(path: "ace_lm_bf16.part2.safetensors", bytes: 1_812_117_376, release: "acestep-v4"),
            Self(path: "ace_dit_outer_f16.safetensors", bytes: 130_111_616, release: "acestep-v3")
        ]
        let programs: [Int64] = [8_262_897, 8_266_317, 8_273_157, 8_273_157]
        for index in 0..<4 {
            let folder = "ace_dit_ane_c\(index).mlmodelc"
            let files: [(String, Int64)] = [("model.mil", programs[index]), ("coremldata.bin", 8_186),
                ("metadata.json", 122_343), ("analytics/coremldata.bin", 243), ("weights/weight.bin", 755_752_384)]
            for (name, bytes) in files {
                result.append(Self(path: folder + "/" + name, bytes: bytes, release: "acestep-v3",
                    assetName: folder + "__" + name.replacingOccurrences(of: "/", with: "__")))
            }
        }
        return result
    }()
    static var downloadBytes: Int64 { all.reduce(0) { $0 + $1.bytes } }
    static func requiredSpace(at root: URL) -> Int64 {
        let missing = all.filter { !$0.present(at: root) }
        guard !missing.isEmpty else { return 0 }
        return missing.reduce(0) { $0 + $1.bytes } + 1_000_000_000
    }
}
