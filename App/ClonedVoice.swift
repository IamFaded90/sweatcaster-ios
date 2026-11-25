import Foundation

enum ClonedVoice {
    struct Voice: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var name: String
        var created = Date()
        var previewApproved = false
        var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 }
    }
    struct Install: Codable, Equatable, Sendable {
        let files: [String: Int]
        func valid(in directory: URL) -> Bool {
            !files.isEmpty && files.count <= 1_000 && files.allSatisfy { path, size in
                guard size > 0, let url = try? safeFile(path, in: directory) else { return false }
                return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
            }
        }
    }
    enum Failure: LocalizedError {
        case name, model, recording, samples, missing
        var errorDescription: String? { switch self {
        case .name: "Giv stemmen et navn på højst 60 tegn."
        case .model: "Hent den flersprogede stemmemodel færdig, før du fortsætter."
        case .recording: "Brug 10–60 sekunders tydelig tale uden musik, højst 20 MB. Omkring 25–30 sekunder er bedst."
        case .samples: "Stemmemodellen gav ingen brugbar lyd. Prøv en kortere tekst."
        case .missing: "Stemmen mangler på denne iPhone. Vælg en anden stemme eller opret den igen."
        } }
    }
    static func safeFile(_ name: String, in root: URL) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && !$0.contains("\\") }) else { throw Failure.model }
        let url = root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw Failure.model }; return url
    }
    static func recording(seconds: Double, bytes: Int) throws {
        guard seconds.isFinite, (10...60).contains(seconds), (1...20_000_000).contains(bytes) else { throw Failure.recording }
    }
    static func wav(_ samples: [Float], sampleRate: Int = 24_000) throws -> Data {
        guard (8_000...48_000).contains(sampleRate), !samples.isEmpty, samples.count <= sampleRate * 180,
              samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.00001 }) else { throw Failure.samples }
        var output = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { output.append(contentsOf: $0) } }
        output.append(Data("RIFF".utf8)); word(UInt32(36 + samples.count * 2)); output.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(sampleRate)); word(UInt32(sampleRate * 2)); word(UInt16(2)); word(UInt16(16))
        output.append(Data("data".utf8)); word(UInt32(samples.count * 2))
        for sample in samples { word(Int16((min(1, max(-1, sample)) * 32_767).rounded())) }
        return output
    }
    struct Store {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/OwnVoices", isDirectory: true)
        func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
        func conditions(_ id: UUID) throws -> URL { try ClonedVoice.safeFile(id.uuidString.lowercased() + "/voice.safetensors", in: root) }
        func list() throws -> [Voice] {
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }.prefix(50).compactMap { folder in
                    guard let id = UUID(uuidString: folder.lastPathComponent),
                          let url = try? ClonedVoice.safeFile(id.uuidString.lowercased() + "/voice.json", in: root),
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000,
                          let data = try? Data(contentsOf: url), let voice = try? JSONDecoder().decode(Voice.self, from: data), voice.id == id, voice.valid else { return nil }
                    return voice
                }.sorted { $0.created > $1.created }
        }
        func ready(_ id: UUID) -> Bool {
            guard (try? list().contains { $0.id == id }) == true, let file = try? conditions(id),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return (256...12_000_000).contains(size)
        }
        func save(_ voice: Voice) throws {
            guard voice.valid else { throw Failure.name }
            let url = try ClonedVoice.safeFile(voice.id.uuidString.lowercased() + "/voice.json", in: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(voice).write(to: url, options: [.atomic, .completeFileProtection])
        }
        func remove(_ id: UUID) throws {
            let target = try ClonedVoice.safeFile(id.uuidString.lowercased(), in: root)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }
}
