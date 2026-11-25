import Foundation
import MLX

public struct PhoneSongInput: Sendable {
    public let id: UUID
    public let style, lyrics: String
    public let seconds: Double
    public let instrumental, enhancePrompt: Bool
    public let language: String
    public let referenceAudio, remixAudio: URL?
    public init(id: UUID, style: String, lyrics: String, seconds: Double, instrumental: Bool,
                enhancePrompt: Bool = true, language: String = "da",
                referenceAudio: URL? = nil, remixAudio: URL? = nil) {
        self.id = id; self.style = style; self.lyrics = lyrics; self.seconds = seconds
        self.instrumental = instrumental; self.enhancePrompt = enhancePrompt; self.language = language
        self.referenceAudio = referenceAudio; self.remixAudio = remixAudio
    }
}

public enum PhoneSongFailure: LocalizedError {
    case unsupported, missing, busy, input, download, invalidModel
    public var errorDescription: String? {
        switch self {
        case .unsupported: "ACE-Step kræver en rigtig iPhone med iOS 18 eller nyere og understøttet grafik."
        case .missing: "Hent først ACE-Step-sangmodellen på telefonen."
        case .busy: "Telefonen arbejder allerede på en sang eller hentning."
        case .input: "Sangens beskrivelse, tekst eller længde kunne ikke bruges."
        case .download: "En modelfil var ufuldstændig. Prøv hentningen igen; færdige filer bevares."
        case .invalidModel: "En af sangmodellens filer kunne ikke læses. Slet sangmodellen, og hent den igen. Dine færdige sange bevares."
        }
    }
}

private final class SongCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Staged ACE session per song. Nothing loads at startup or after downloading.
public actor PhoneSongEngine {
    public static let shared = PhoneSongEngine()
    private static let foreground = SongForeground()
    private var busy = false
    public nonisolated static var downloadBytes: Int64 { PhoneSongAsset.downloadBytes }
    public nonisolated static func requiredSpace(at root: URL) -> Int64 { PhoneSongAsset.requiredSpace(at: root) }
    public nonisolated static func suspend() { foreground.set(false) }
    public nonisolated static func resume() { foreground.set(true) }
    public nonisolated static func cleanupReferenceScratch() {
        ACEReferenceScratch.clean(FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-SongReference", isDirectory: true))
    }
    public nonisolated static func installed(at root: URL) -> Bool {
        PhoneSongAsset.all.allSatisfy { $0.present(at: root) }
    }
    public func download(to root: URL, progress: @Sendable @escaping (String) -> Void) async throws {
        guard !busy else { throw PhoneSongFailure.busy }
        busy = true; defer { busy = false }
        try await PhoneSongDownload.fetch(to: root, progress: progress)
    }
    public func removeModel(at root: URL) throws {
        guard !busy else { throw PhoneSongFailure.busy }
        guard root.lastPathComponent == "OfflineSongs" else { throw PhoneSongFailure.input }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    public func generate(_ input: PhoneSongInput, models: URL, output: URL,
                         progress: @Sendable @escaping (String) -> Void) async throws -> Double {
        #if targetEnvironment(simulator) || !arch(arm64)
        throw PhoneSongFailure.unsupported
        #else
        guard #available(iOS 18, macOS 15, *) else { throw PhoneSongFailure.unsupported }
        guard !busy else { throw PhoneSongFailure.busy }
        guard Self.installed(at: models) else { throw PhoneSongFailure.missing }
        guard (10...180).contains(input.seconds), !input.style.isEmpty, input.style.count <= 1_500,
              input.lyrics.count <= 6_000, input.instrumental || !input.lyrics.isEmpty else { throw PhoneSongFailure.input }
        busy = true
        let token = SongCancellation()
        defer { busy = false; StageMemory.release() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard Self.foreground.open else { throw CancellationError() }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            var generator = ACEGenerator(directory: models)
            generator.transformerEngine = .neuralEngine
            generator.plannerExpandsCaption = input.enhancePrompt
            if input.referenceAudio != nil || input.remixAudio != nil {
                generator.referenceDirectory = try await PhoneSongReferenceModels.shared.preparedDirectory(at: models)
            }
            var metadata = PromptMetadata(parsing: input.style)
            metadata.seconds = Int(input.seconds)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-SongReference", isDirectory: true)
            if input.referenceAudio != nil || input.remixAudio != nil { Self.cleanupReferenceScratch() }
            let timbre: MLXArray?
            if let source = input.referenceAudio {
                progress("Forbereder lydreferencen på iPhone…")
                timbre = try await ACEReferenceAudioTensor.timbre(source: source, scratch: scratch)
            } else { timbre = nil }
            let remix: MLXArray?
            if let source = input.remixAudio {
                progress("Forbereder remixets lydfil på iPhone…")
                remix = try await ACEReferenceAudioTensor.remix(source: source, scratch: scratch, seconds: input.seconds)
            } else { remix = nil }
            try Task.checkCancellation()
            _ = try generator.generate(caption: input.style, lyrics: input.instrumental ? "" : input.lyrics,
                language: input.language, seconds: input.seconds, seed: UInt64.random(in: 1...UInt64.max),
                to: output, known: metadata, referenceTimbreAudio: timbre, remixAudio: remix,
                isCancelled: { token.cancelled || !Self.foreground.open }) { stage in
                    progress(Self.description(stage))
                }
            try Task.checkCancellation()
            guard !token.cancelled, Self.foreground.open else { throw CancellationError() }
            return input.seconds
        } onCancel: { token.cancel() }
        #endif
    }
    private nonisolated static func description(_ stage: ACEGenerator.Stage) -> String {
        switch stage {
        case .planning: "ACE-Step planlægger sangen…"
        case .writing(let done, let total): "Planlægger forløbet · \(done)/\(total)"
        case .preparingEngine: "Gør Neural Engine klar · første gang kan tage længere tid…"
        case .readingPrompt: "Læser din musikstil og sangtekst…"
        case .conditioning: "Forbereder instrumenter og stemme…"
        case .step(let done, let total): "Skaber musikken · \(done)/\(total)"
        case .lengthening: "Tilpasser sangen til den valgte længde…"
        case .decoding(let fraction): "Gemmer lyden · \(Int(fraction * 100))%"
        }
    }
}

private final class SongForeground: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func set(_ value: Bool) { lock.lock(); self.value = value; lock.unlock() }
    var open: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
