// Isolated ACE-Step safetensors reconstruction; no existing song model is changed.
// The caller must pin and trust both the official-source manifest and the
// locally-derived header digest; this utility does not establish provenance.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif os(Linux)
@_silgen_name("EVP_MD_CTX_new") private func evpNew() -> OpaquePointer?
@_silgen_name("EVP_MD_CTX_free") private func evpFree(_ ctx: OpaquePointer?)
@_silgen_name("EVP_sha256") private func evpSHA256() -> OpaquePointer?
@_silgen_name("EVP_DigestInit_ex") private func evpInit(_ ctx: OpaquePointer?, _ type: OpaquePointer?, _ impl: OpaquePointer?) -> Int32
@_silgen_name("EVP_DigestUpdate") private func evpUpdate(_ ctx: OpaquePointer?, _ data: UnsafeRawPointer?, _ count: Int) -> Int32
@_silgen_name("EVP_DigestFinal_ex") private func evpFinal(_ ctx: OpaquePointer?, _ output: UnsafeMutablePointer<UInt8>?, _ size: UnsafeMutablePointer<UInt32>?) -> Int32
#else
#error("SHA-256 implementation unavailable on this platform")
#endif

enum RebuildFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { if case .invalid(let message) = self { return message }; return "Rebuild error" }
}

final class StreamingSHA256 {
    #if canImport(CryptoKit)
    var hash = SHA256()
    #elseif os(Linux)
    private let context: OpaquePointer
    init() throws {
        guard let ctx = evpNew() else { throw RebuildFailure.invalid("SHA-256 context unavailable") }
        context = ctx
        guard evpInit(ctx, evpSHA256(), nil) == 1 else {
            evpFree(ctx); throw RebuildFailure.invalid("SHA-256 init failed")
        }
    }
    deinit { evpFree(context) }
    #endif
    #if canImport(CryptoKit)
    init() throws { }
    #endif
    func update(_ data: Data) throws {
        #if canImport(CryptoKit)
        hash.update(data: data)
        #elseif os(Linux)
        let status = data.withUnsafeBytes { evpUpdate(context, $0.baseAddress, $0.count) }
        guard status == 1 else { throw RebuildFailure.invalid("SHA-256 update failed") }
        #endif
    }
    func finish() throws -> String {
        #if canImport(CryptoKit)
        let bytes = Array(hash.finalize())
        #elseif os(Linux)
        var bytes = [UInt8](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard evpFinal(context, &bytes, &count) == 1, count == 32 else { throw RebuildFailure.invalid("SHA-256 final failed") }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct SourceComponent {
    let headerLength: Int
    let prefix: String
    let count: Int
    let dtype: String
    let start: Int64
    let end: Int64
    let bytes: Int64
    let rangeSHA: String
    init(_ obj: [String: Any]) throws {
        guard let headerLength = obj["safetensors_header_bytes"] as? Int,
              let prefix = obj["tensor_prefix"] as? String,
              let count = obj["tensor_count"] as? Int,
              let dtype = obj["tensor_dtype"] as? String,
              let start = obj["range_start_inclusive"] as? Int64,
              let end = obj["range_end_inclusive"] as? Int64,
              let bytes = obj["range_bytes"] as? Int64,
              let rangeSHA = obj["range_sha256"] as? String,
              headerLength >= 0, headerLength <= 100_000_000, !prefix.isEmpty,
              count > 0, dtype == "BF16", start >= 0, end >= start,
              end < Int64.max, end - start + 1 == bytes, bytes > 0,
              rangeSHA.count == 64, rangeSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw RebuildFailure.invalid("Invalid source component")
        }
        self.headerLength = headerLength; self.prefix = prefix; self.count = count; self.dtype = dtype
        self.start = start; self.end = end; self.bytes = bytes; self.rangeSHA = rangeSHA
    }
}

enum RebuildSafeTensors {
    private struct Tensor {
        let name: String
        let shape: [Int]
        let start: Int64
        let end: Int64
    }
    static func run(component: SourceComponent, headerURL: URL, fragmentURL: URL,
                    outputURL: URL, headerSHA: String) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard headerURL.isFileURL, fragmentURL.isFileURL, outputURL.isFileURL,
              !fm.fileExists(atPath: outputURL.path), headerSHA.count == 64,
              headerSHA.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw RebuildFailure.invalid("Invalid output or header hash")
        }
        guard try headerURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == component.headerLength + 8 else {
            throw RebuildFailure.invalid("Header byte count mismatch")
        }
        let header = try Data(contentsOf: headerURL)
        guard header.count == component.headerLength + 8 else { throw RebuildFailure.invalid("Header byte count mismatch") }
        let headerDigest = try StreamingSHA256(); try headerDigest.update(header)
        guard try headerDigest.finish() == headerSHA else { throw RebuildFailure.invalid("Header SHA-256 mismatch") }
        var declared: UInt64 = 0
        for i in 0..<8 { declared |= UInt64(header[i]) << UInt64(8 * i) }
        guard declared == UInt64(component.headerLength) else { throw RebuildFailure.invalid("Header length mismatch") }
        let body = header.subdata(in: 8..<header.count)
        guard let document = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw RebuildFailure.invalid("Invalid header JSON")
        }
        let origin = Int64(header.count)
        guard component.start >= origin else { throw RebuildFailure.invalid("Range overlaps header") }
        let first = component.start - origin
        var selected: [Tensor] = []
        for (name, value) in document where name.hasPrefix(component.prefix) {
            try Task.checkCancellation()
            guard let object = value as? [String: Any], Set(object.keys) == Set(["dtype", "shape", "data_offsets"]),
                  object["dtype"] as? String == "BF16", let shape = object["shape"] as? [Int],
                  let offsets = object["data_offsets"] as? [Int64], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0] else { throw RebuildFailure.invalid("Invalid tensor \(name)") }
            var elements: Int64 = 1
            for dimension in shape {
                guard dimension >= 0, Int64(dimension) <= component.bytes / max(1, elements) else {
                    throw RebuildFailure.invalid("Invalid shape \(name)")
                }
                elements *= Int64(dimension)
            }
            guard elements <= component.bytes / 2, offsets[1] - offsets[0] == elements * 2 else {
                throw RebuildFailure.invalid("Tensor byte count mismatch \(name)")
            }
            selected.append(Tensor(name: name, shape: shape, start: offsets[0], end: offsets[1]))
        }
        guard selected.count == component.count else { throw RebuildFailure.invalid("Tensor count mismatch") }
        selected.sort { $0.start < $1.start }
        var cursor = first
        var result: [String: Any] = [:]
        if let metadata = document["__metadata__"] as? [String: String], !metadata.isEmpty { result["__metadata__"] = metadata }
        for tensor in selected {
            guard tensor.start == cursor else { throw RebuildFailure.invalid("Selected range has a gap or overlap") }
            result[tensor.name] = ["dtype": "BF16", "shape": tensor.shape,
                                   "data_offsets": [tensor.start - first, tensor.end - first]]
            cursor = tensor.end
        }
        guard cursor == component.end + 1 - origin else { throw RebuildFailure.invalid("Selected range length mismatch") }
        var newHeader = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        while newHeader.count % 8 != 0 { newHeader.append(32) }
        var prefix = Data()
        let len = UInt64(newHeader.count)
        for i in 0..<8 { prefix.append(UInt8(truncatingIfNeeded: len >> UInt64(i * 8))) }
        prefix.append(newHeader)
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".swift-rebuild-" + UUID().uuidString)
        try Data().write(to: temporary, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temporary) }
        let source = try FileHandle(forReadingFrom: fragmentURL); defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: temporary); defer { try? destination.close() }
        try destination.write(contentsOf: prefix)
        let digest = try StreamingSHA256()
        var count: Int64 = 0
        while let block = try source.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            guard Int64(block.count) <= component.bytes - count else { throw RebuildFailure.invalid("Range exceeds expected length") }
            try digest.update(block); try destination.write(contentsOf: block)
            count += Int64(block.count)
        }
        guard count == component.bytes, try digest.finish() == component.rangeSHA else {
            throw RebuildFailure.invalid("Range length or SHA-256 mismatch")
        }
        try Task.checkCancellation()
        try destination.synchronize(); try destination.close()
        // Foundation refuses an existing destination. Atomic/exclusive move
        // semantics and directory protection require device validation before
        // this research code can be used in production.
        try fm.moveItem(at: temporary, to: outputURL)
        print("Reconstructed \(selected.count) original-layout BF16 tensors")
    }
}
