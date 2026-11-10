// Loads the pinned Qwen Core ML bundles and their local tokenizers.
import CoreGraphics
import CoreMLLLM
import Foundation
import Tokenizers

enum QwenPhoneRuntime {
    enum Variant {
        case compact, vision

        init?(modelID: String) {
            switch modelID {
            case ModelDownloader.ModelInfo.qwen35_08b.id: self = .compact
            case ModelDownloader.ModelInfo.qwen3vl_2b.id: self = .vision
            default: return nil
            }
        }

        var modelID: String {
            switch self {
            case .compact: ModelDownloader.ModelInfo.qwen35_08b.id
            case .vision: ModelDownloader.ModelInfo.qwen3vl_2b.id
            }
        }

        var chunks: String {
            switch self {
            case .compact: "qwen3_5_0_8b_decode_chunks_mlkv"
            case .vision: "qwen3_vl_2b_decode_chunks"
            }
        }

        var contextLimit: Int {
            switch self {
            case .compact: 2_048
            case .vision: 1_024
            }
        }

        var requiredModels: [String] {
            switch self {
            case .compact: ["chunk_a", "chunk_b", "chunk_c", "chunk_d"].map { "\(chunks)/\($0)" }
            case .vision:
                ["chunk_0", "chunk_1", "chunk_2", "chunk_3", "chunk_head", "chunk_0_vision"].map { "\(chunks)/\($0)" }
                    + ["qwen3_vl_2b_vision/vision"]
            }
        }

        var embeddingBytes: Int {
            switch self {
            case .compact: 248_320 * 1_024 * 2
            case .vision: 151_936 * 2_048 * 2
            }
        }

        var source: (repo: String, revision: String) {
            switch self {
            case .compact: ("Qwen3.5-0.8B", "2fc06364715b967f1860aea9cf38778875588b17")
            case .vision: ("Qwen3-VL-2B-Instruct", "89644892e4d85e24eaac8bacfd4f463576704203")
            }
        }

        var tokenizerFiles: [(name: String, bytes: Int)] {
            switch self {
            case .compact: [("tokenizer.json", 12_807_982), ("tokenizer_config.json", 16_709), ("config.json", 2_907)]
            case .vision: [("tokenizer.json", 7_032_403), ("tokenizer_config.json", 10_868), ("config.json", 1_505)]
            }
        }

        var tokenizerBytes: Int64 { tokenizerFiles.reduce(0) { $0 + Int64($1.bytes) } }
    }

    static let visionAssets: [(path: String, bytes: Int64)]? = {
        let layout = Variant.vision
        let modelSizes: [Int64] = [207_029, 207_085, 207_127, 207_127, 5_493, 209_391, 395_493]
        let weightSizes: [Int64] = Array(repeating: 352_419_520, count: 4) + [311_169_792, 352_419_520, 405_955_200]
        guard modelSizes.count == layout.requiredModels.count,
              weightSizes.count == layout.requiredModels.count else { return nil }
        var assets = [(path: "\(layout.chunks)/embed_weight.bin", bytes: Int64(layout.embeddingBytes))]
        for (name, sizes) in zip(layout.requiredModels, zip(modelSizes, weightSizes)) {
            let prefix = "\(name).mlpackage"
            assets += [("\(prefix)/Manifest.json", 617),
                       ("\(prefix)/Data/com.apple.CoreML/model.mlmodel", sizes.0),
                       ("\(prefix)/Data/com.apple.CoreML/weights/weight.bin", sizes.1)]
        }
        return assets
    }()

    static let visionWeightsBytes = visionAssets?.reduce(Int64(0)) { $0 + $1.bytes } ?? 0

    // The Hub redirects pinned files to its own Xet and LFS hosts.
    private final class HubRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            QwenPhoneRuntime.isHubDownloadURL(request.url) ? request : nil
        }
    }

    private static let hubDownloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration, delegate: HubRedirectPolicy(), delegateQueue: nil)
    }()

    private static func isHubDownloadURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }

    private static func downloadHubFile(_ source: URL) async throws -> URL {
        guard isHubDownloadURL(source) else { throw PhoneModelError.invalidBundle }
        do {
            let (temporary, response) = try await hubDownloads.download(from: source)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, isHubDownloadURL(http.url) else {
                try? FileManager.default.removeItem(at: temporary)
                throw PhoneModelError.invalidBundle
            }
            return temporary
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    // The published snapshot provides recurrent decoding. The SDK's optional prefill files are absent.
    @MainActor static func installVisionWeights(in folder: URL, progress: (Double) -> Void) async throws {
        guard let visionAssets else { throw V2Failure.invalidResponse }
        let revision = "44e0c8401d253a8e7b331a55332f2ce9aac954ca"
        let root = folder.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: folder.lastPathComponent)
        guard root.path == root.resolvingSymlinksInPath().path else { throw PhoneModelError.invalidBundle }
        var modelFolder = root
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        try modelFolder.setResourceValues(options)
        let manager = FileManager.default
        let missing = try visionAssets.filter { asset in
            let destination = root.appending(path: asset.path)
            guard destination.path == destination.resolvingSymlinksInPath().path else { throw PhoneModelError.invalidBundle }
            return !matchesFile(destination, bytes: asset.bytes)
        }
        var completed = visionWeightsBytes - missing.reduce(Int64(0)) { $0 + $1.bytes }
        progress(Double(completed) / Double(visionWeightsBytes))
        for asset in missing {
            try Task.checkCancellation()
            let destination = root.appending(path: asset.path)
            guard let source = URL(string: "https://huggingface.co/mlboydaisuke/qwen3-vl-2b-coreml/resolve/\(revision)/\(asset.path)") else {
                throw PhoneModelError.invalidBundle
            }
            let temporary = try await downloadHubFile(source)
            defer { try? manager.removeItem(at: temporary) }
            guard matchesFile(temporary, bytes: asset.bytes) else { throw PhoneModelError.invalidBundle }
            try Task.checkCancellation()
            let checkedDestination = try LocalFileStore.safeWriteURL(destination, within: root)
            try manager.createDirectory(at: checkedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LocalFileStore.protectFile(temporary)
            if manager.fileExists(atPath: checkedDestination.path) {
                _ = try manager.replaceItemAt(checkedDestination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: temporary, to: checkedDestination)
            }
            completed += asset.bytes
            progress(Double(completed) / Double(visionWeightsBytes))
        }
    }

    private static func matchesFile(_ url: URL, bytes: Int64) -> Bool {
        guard let flags = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              flags.isRegularFile == true, flags.isSymbolicLink != true, let size = flags.fileSize else { return false }
        return Int64(size) == bytes
    }

    @MainActor static func prepareTokenizer(for variant: Variant, folder: URL) async throws {
        let base = folder.deletingLastPathComponent().resolvingSymlinksInPath()
        let directory = base.appending(path: folder.lastPathComponent).appending(path: "hf_model", directoryHint: .isDirectory)
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw PhoneModelError.invalidBundle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in variant.tokenizerFiles {
            try Task.checkCancellation()
            let destination = directory.appending(path: name)
            if matchesFile(destination, bytes: Int64(bytes)) { continue }
            guard destination.path == destination.resolvingSymlinksInPath().path,
                  let url = URL(string: "https://huggingface.co/Qwen/\(variant.source.repo)/resolve/\(variant.source.revision)/\(name)") else {
                throw PhoneModelError.invalidBundle
            }
            let temporary = try await downloadHubFile(url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try LocalFileStore.readBytes(from: temporary, maximumBytes: bytes)
            guard data.count == bytes, (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw PhoneModelError.invalidBundle
            }
            try Task.checkCancellation()
            try LocalFileStore.writeBytes(data, to: destination, within: directory)
        }
    }

    @MainActor static func generate(_ variant: Variant, folder: URL, prompt: String, instructions: String,
                                    history: [PhoneModels.ChatExchange] = [],
                                    image: CGImage? = nil, maxTokens: Int, update: @escaping (String) -> Void) async throws -> (text: String, rate: Double) {
        LocalCompute.beginModelLoad()
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder.appending(path: "hf_model"))
        let start = try token("<|im_start|>", tokenizer: tokenizer)
        let end = try token("<|im_end|>", tokenizer: tokenizer)
        let stop = try token("<|endoftext|>", tokenizer: tokenizer)
        let eos: Set<Int32> = [start, end, stop]
        let textExcluded: Set<Int32>
        if case .vision = variant {
            textExcluded = try eos.union(["<|vision_start|>", "<|image_pad|>", "<|vision_end|>"].map { try token($0, tokenizer: tokenizer) })
        } else {
            textExcluded = eos
        }
        func encode(_ text: String) -> [Int32] {
            tokenizer.encode(text: text, addSpecialTokens: false).map(Int32.init)
        }
        func message(_ role: String, _ text: String) -> [Int32] {
            var tokens = [start] + encode(role + "\n")
            tokens += encode(text).filter { !textExcluded.contains($0) }
            tokens.append(end)
            tokens += encode("\n")
            return tokens
        }
        let (tokens, continuation) = AsyncStream<Int32>.makeStream()
        let delivery = Task { @MainActor in
            var emitted: [Int] = []
            for await id in tokens {
                guard !Task.isCancelled, !eos.contains(id) else { break }
                emitted.append(Int(id))
                if emitted.count == 1 || emitted.count.isMultiple(of: 4) {
                    update(tokenizer.decode(tokens: emitted, skipSpecialTokens: true))
                }
            }
        }
        let emit: @Sendable (Int32) -> Void = { id in
            if !Task.isCancelled { _ = continuation.yield(id) }
        }
        defer { continuation.finish(); delivery.cancel() }
        let generated: [Int32]
        let started: ContinuousClock.Instant
        switch variant {
        case .compact:
            guard image == nil else { throw PhoneModelError.unavailable }
            let input = encode(compactPrompt(prompt, instructions: instructions, history: history))
            let budget = try outputLimit(context: variant.contextLimit, input: input.count, requested: maxTokens)
            let generator = Qwen35MLKVGenerator(cfg: .default0_8B)
            generator.setModelFolder(folder)
            try await generator.load()
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            started = .now
            // CoreML-LLM v1.9.0's full-logit sampler ignores topP when temperature is nonzero.
            // Use its documented iPhone argmax path with a repetition penalty.
            generated = try await generator.generate(inputIds: input, maxNewTokens: budget, temperature: 0,
                                                     repetitionPenalty: 1.1, eosTokenIds: eos, onToken: emit)
        case .vision:
            var input: [Int32] = []
            if !instructions.isEmpty { input += message("system", instructions) }
            for exchange in history {
                input += message("user", exchange.prompt)
                input += message("assistant", exchange.reply)
            }
            input += [start] + encode("user\n")
            let generator = Qwen3VL2BGenerator()
            generator.modelFolderOverride = folder
            try generator.load()
            var features: Qwen3VL2BVisionFeatures?
            var imagePad: Int32 = 151_655
            if let image {
                guard let visionURL = Qwen3VL2BVisionEncoder.resolveModel(folder: folder) else { throw PhoneModelError.invalidBundle }
                let encoder = Qwen3VL2BVisionEncoder()
                try encoder.load(modelURL: visionURL)
                let encoded = try await encoder.encode(image)
                guard (1...256).contains(encoded.count) else { throw PhoneModelError.invalidBundle }
                features = encoded
                imagePad = try token("<|image_pad|>", tokenizer: tokenizer)
                input += [try token("<|vision_start|>", tokenizer: tokenizer)]
                input += Array(repeating: imagePad, count: encoded.count)
                input += [try token("<|vision_end|>", tokenizer: tokenizer)]
            }
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            input += encode(prompt).filter { !textExcluded.contains($0) } + [end] + encode("\n")
            input += [start] + encode("assistant\n")
            let budget = try outputLimit(context: variant.contextLimit, input: input.count, requested: maxTokens)
            started = .now
            generated = try await generator.generate(inputIds: input, maxNewTokens: budget, eosTokenIds: eos,
                                                     visionFeatures: features, imagePadTokenId: imagePad, onToken: emit)
        }
        let elapsed = started.duration(to: .now).components
        try Task.checkCancellation()
        continuation.finish()
        await delivery.value
        try Task.checkCancellation()
        let output = generated.prefix { !eos.contains($0) }.map(Int.init)
        let text = tokenizer.decode(tokens: output, skipSpecialTokens: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
        update(text)
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return (text, Double(output.count) / max(0.001, seconds))
    }

    // Text-only subset of the pinned Qwen3.5 template with thinking disabled.
    // Encode the entire rendered prompt together to preserve tokenizer boundaries.
    private static func compactPrompt(_ prompt: String, instructions: String, history: [PhoneModels.ChatExchange]) -> String {
        let controls = ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "<think>", "</think>",
                        "<tool_call>", "</tool_call>", "<tool_response>", "</tool_response>",
                        "<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>"]
        func turn(_ role: String, _ text: String) -> String {
            let content = controls.reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        var result = instructions.isEmpty ? "" : turn("system", instructions)
        for exchange in history {
            result += turn("user", exchange.prompt)
            result += turn("assistant", exchange.reply)
        }
        return result + turn("user", prompt) + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    private static func token(_ text: String, tokenizer: any Tokenizer) throws -> Int32 {
        guard let id = tokenizer.convertTokenToId(text), let safe = Int32(exactly: id) else { throw PhoneModelError.invalidBundle }
        return safe
    }

    private static func outputLimit(context: Int, input: Int, requested: Int) throws -> Int {
        let remaining = context - input - 1
        guard remaining > 0 else { throw PhoneModelError.contextLimit }
        return min(requested, remaining)
    }
}
