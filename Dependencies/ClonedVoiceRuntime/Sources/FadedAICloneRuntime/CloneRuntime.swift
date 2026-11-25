import ChatterboxCoreML
import CoreML
import Foundation
import PerthCoreML

public enum CloneRuntime {
    public static func modelDirectory(root: URL) -> URL {
        ModelRepository.downloadDirectory(hfHome: root, repoId: ModelRepository.defaultMultilingualRepoId)
    }
    public static func watermarkDirectory(root: URL) -> URL {
        ModelRepository.downloadDirectory(hfHome: root, repoId: ModelRepository.perthRepoId)
    }
    /// Explicit installation only. Normal synthesis never calls the Hub.
    public static func download(root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [String: Int] {
        let packs = [(ModelRepository.defaultMultilingualRepoId, ModelRepository.Variant.multilingual.runtimeGlobs),
                     (ModelRepository.perthRepoId, ModelRepository.perthGlobs)]
        var installed: [String: Int] = [:]
        for (index, (repo, globs)) in packs.enumerated() {
            try Task.checkCancellation()
            guard let remote = await ModelRepository.remoteManifest(repoId: repo), !remote.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
            let expected = remote.filter { path, size in size > 0 && globs.contains { glob in
                if let star = glob.firstIndex(of: "*") { return path.hasPrefix(String(glob[..<star])) }
                return path == glob
            } }
            guard !expected.isEmpty, expected.count <= 1_000 else { throw URLError(.cannotParseResponse) }
            let target = ModelRepository.downloadDirectory(hfHome: root, repoId: repo)
            let needed = expected.reduce(Int64(0)) { total, entry in
                let size = (try? target.appendingPathComponent(entry.key).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + Int64(size == entry.value ? 0 : entry.value)
            }
            let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, available < needed + 128_000_000 { throw CocoaError(.fileWriteOutOfSpace) }
            let result = try await ModelRepository.download(repoId: repo, hfHome: root, matching: globs, manifest: remote) { fraction in
                progress(index == 0 ? min(0.96, fraction * 0.96) : 0.96 + min(0.04, fraction * 0.04))
            }
            try Task.checkCancellation()
            guard result.stillStale.isEmpty, !result.isPartiallyApplied else { throw URLError(.cannotDecodeContentData) }
            for (path, size) in expected {
                let url = result.directory.appendingPathComponent(path).resolvingSymlinksInPath()
                let prefix = root.resolvingSymlinksInPath().path + "/"
                guard url.path.hasPrefix(prefix), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size else { throw URLError(.cannotDecodeContentData) }
                installed[String(url.path.dropFirst(prefix.count))] = size
            }
        }
        progress(1); return installed
    }
}

/// Serial ownership of synthesis; model unloading never removes saved voices.
public actor CloneVoiceEngine {
    public static let shared = CloneVoiceEngine()
    private var model: ChatterboxCoreMLModel?
    private var cachedDirectory: URL?
    private var idle: Task<Void, Never>?
    public func unload() { idle?.cancel(); idle = nil; model = nil; cachedDirectory = nil }
    public func clone(reference: URL, root: URL, output: URL) async throws {
        unload(); try Task.checkCancellation()
        let cloner = try await VoiceCloner(modelDirectory: CloneRuntime.modelDirectory(root: root))
        try Task.checkCancellation(); try cloner.cloneVoice(from: reference, to: output)
        try Task.checkCancellation()
    }
    public func samples(text: String, voice: URL, root: URL, language: String) async throws -> [Float] {
        try Task.checkCancellation(); idle?.cancel()
        let directory = CloneRuntime.modelDirectory(root: root)
        if model == nil || cachedDirectory != directory {
            // Load an installed watermark directly: no automatic network fallback.
            let mark = try PerthWatermarker(modelDirectory: CloneRuntime.watermarkDirectory(root: root), computeUnits: .cpuAndNeuralEngine)
            model = try await ChatterboxCoreMLModel.load(from: directory, watermarker: PerthWatermark(watermarker: mark))
            cachedDirectory = directory
        }
        guard let model, model.loadedVariant == .multilingual else { throw URLError(.cannotDecodeContentData) }
        defer { idle = Task { do { try await Task.sleep(for: .seconds(15)) } catch { return }; unload() } }
        let options = GenerationOptions.multilingual(language: language, maxTokens: 700)
        var samples: [Float] = []
        for try await chunk in model.generateStream(text, voice: voice, options: options) {
            try Task.checkCancellation()
            guard samples.count + chunk.samples.count <= 24_000 * 180 else { throw URLError(.dataLengthExceedsMaximum) }
            samples.append(contentsOf: chunk.samples)
        }
        return samples
    }
}
