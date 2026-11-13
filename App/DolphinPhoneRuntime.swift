// Downloads a pinned Core ML conversion and runs Dolphin privately on this device.
import CoreML
import CryptoKit
import Foundation
import Tokenizers

enum DolphinPhoneRuntime {
    static let modelID = "dolphin-private-3b"
    static let modelName = "Dolphin 3.0 3B"
    static let contextLimit = 2_048
    static let minimumFreeBytes: Int64 = 5_000_000_000
    static let modelCardURL = URL(string: "https://huggingface.co/ales27pm/Dolphin3.0-CoreML")!

    private struct Asset: Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }

    // Core ML conversion of dphn/Dolphin3.0-Llama3.2-3B (Llama 3.2 Community License).
    private static let revision = "95671cf9a2f56d2a381816ae264cd9aae335d96f"
    private static let package = "Dolphin3.0-Llama3.2-3B-stateful-int4.mlpackage"
    private static let modelAssets: [Asset] = [
        .init(path: "\(package)/Manifest.json", bytes: 617,
              sha256: "5b8ac347a822f02ba3a6d9ccff60dd723f2649424c8e88570961f12b1c59afb6"),
        .init(path: "\(package)/Data/com.apple.CoreML/model.mlmodel", bytes: 809_496,
              sha256: "a34a00a253c98153cf3b231105493edddde532086e224443e40b255b0f10a924"),
        .init(path: "\(package)/Data/com.apple.CoreML/weights/weight.bin", bytes: 1_807_737_412,
              sha256: "6240edc377b1a0158812454c4bb6e3053d8e8a75a7eedb751b9740fffdfd3e15")
    ]
    private static let tokenizerAssets: [Asset] = [
        .init(path: "tokenizer.json", bytes: 17_210_298,
              sha256: "e40b93124a3e29f62d5f4ff41be56cb2af34ecacf9239acd9da53a98860380b5"),
        .init(path: "tokenizer_config.json", bytes: 53_573,
              sha256: "51ad9580aba8d00016efda43357185a0d8ff9884584dcc82ab58ca552afd14e1"),
        .init(path: "config.json", bytes: 935,
              sha256: "e21ff53ea39726f972362beba869807216775d5e308bc2f531784846c06a0249"),
        .init(path: "special_tokens_map.json", bytes: 444,
              sha256: "2df2c4620bb1a9eb877bc7c90c7fa04608bda9fa7c0cf2cdcc0a17b849649683")
    ]
    static let downloadBytes: Int64 = (modelAssets + tokenizerAssets).reduce(0) { $0 + Int64($1.bytes) }

    static let storageRoot = URL.applicationSupportDirectory.appending(path: "PrivateStudioModels", directoryHint: .isDirectory)
    private static let folder = storageRoot.appending(path: "Dolphin-v2", directoryHint: .isDirectory)
    private static let compiledName = "Dolphin.mlmodelc"
    private static let compiled = folder.appending(path: compiledName, directoryHint: .isDirectory)
    private static let maxQuery = 512
    private static let maxReply = 384
    private static let stopTokens: Set<Int> = [128_256, 128_001, 128_008, 128_009]
    @MainActor private(set) static var isInstalling = false

    static var isInstalled: Bool {
        guard let flags = try? compiled.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              flags.isDirectory == true, flags.isSymbolicLink != true else { return false }
        return tokenizerAssets.allSatisfy { asset in
            matchesSize(folder.appending(path: asset.path), bytes: asset.bytes)
        }
    }

    @MainActor static func install(progress: @escaping (Double) -> Void) async throws {
        if isInstalled { progress(1); return }
        guard !isInstalling else { throw PhoneModelError.downloadBusy }
        isInstalling = true
        defer { isInstalling = false }
        let files = FileManager.default
        let support = URL.applicationSupportDirectory
        var destination = try LocalFileStore.safeWriteURL(folder.appending(path: ".model-install"), within: support)
            .deletingLastPathComponent()
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)

        // Verified files from an interrupted installation are reused.
        var bytesDone: Int64 = 0
        for asset in modelAssets + tokenizerAssets {
            try Task.checkCancellation()
            let target = try LocalFileStore.safeWriteURL(destination.appending(path: asset.path), within: destination)
            let startingBytes = bytesDone
            if !(try await verified(target, asset: asset)) {
                try await fetch(asset, to: target) { bytes in
                    progress(0.97 * Double(startingBytes + bytes) / Double(downloadBytes))
                }
            }
            bytesDone += Int64(asset.bytes)
            progress(0.97 * Double(bytesDone) / Double(downloadBytes))
        }

        try Task.checkCancellation()
        let source = destination.appending(path: package, directoryHint: .isDirectory)
        let compiledModel = try await MLModel.compileModel(at: source)
        defer { try? files.removeItem(at: compiledModel) }
        try Task.checkCancellation()
        let target = destination.appending(path: compiledName, directoryHint: .isDirectory)
        if files.fileExists(atPath: target.path) {
            let flags = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard flags.isDirectory == true, flags.isSymbolicLink != true else { throw PhoneModelError.invalidBundle }
            _ = try files.replaceItemAt(target, withItemAt: compiledModel, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: compiledModel, to: target)
        }
        guard isInstalled else { throw PhoneModelError.invalidBundle }
        try? files.removeItem(at: source)
        progress(1)
    }

    @MainActor static func stream(prompt: String, instructions: String, history: [PhoneModels.ChatExchange],
                                  update: @escaping (String) -> Void) async throws {
        guard isInstalled else { throw PhoneModelError.unavailable }
        try await LocalCompute.run(minimumMiB: 2_700) {
            LocalCompute.beginModelLoad()
            let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
            let tokens = try inputTokens(prompt: prompt, instructions: instructions, history: history, tokenizer: tokenizer)
            let configuration = MLModelConfiguration()
            // This stateful conversion is published for CPU + GPU inference.
            configuration.computeUnits = .cpuAndGPU
            let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            let state = model.makeState()
            var next: Int?
            for offset in stride(from: 0, to: tokens.count, by: maxQuery) {
                let end = min(tokens.count, offset + maxQuery)
                next = try await predict(model, state: state, tokens: Array(tokens[offset..<end]), end: end,
                                         sample: end == tokens.count)
            }
            var generated: [Int] = []
            for index in 0..<maxReply {
                try Task.checkCancellation()
                guard let token = next, !stopTokens.contains(token), token != tokenizer.eosTokenId else { break }
                generated.append(token)
                if generated.count == 1 || generated.count.isMultiple(of: 4) {
                    update(tokenizer.decode(tokens: generated, skipSpecialTokens: true))
                }
                if index + 1 < maxReply {
                    next = try await predict(model, state: state, tokens: [token], end: tokens.count + generated.count,
                                             sample: true)
                }
            }
            try Task.checkCancellation()
            let answer = tokenizer.decode(tokens: generated, skipSpecialTokens: true)
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
            update(answer)
        }
    }

    private static func inputTokens(prompt: String, instructions: String, history: [PhoneModels.ChatExchange],
                                    tokenizer: any Tokenizer) throws -> [Int] {
        // Keep the new message intact. Drop the oldest turns when the real token count exceeds the budget.
        for first in 0...history.count {
            var messages: [Tokenizers.Message] = [["role": "system", "content": instructions]]
            for exchange in history.dropFirst(first) {
                messages.append(["role": "user", "content": exchange.prompt])
                messages.append(["role": "assistant", "content": exchange.reply])
            }
            messages.append(["role": "user", "content": prompt])
            let tokens = try tokenizer.applyChatTemplate(messages: messages)
            if !tokens.isEmpty, tokens.count + maxReply <= contextLimit { return tokens }
        }
        throw PhoneModelError.contextLimit
    }

    @MainActor private static func predict(_ model: MLModel, state: MLState, tokens: [Int], end: Int,
                                           sample: Bool) async throws -> Int? {
        try Task.checkCancellation()
        let query = tokens.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: query)], dataType: .int32)
        let idStride = ids.strides[1].intValue
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        for (index, token) in tokens.enumerated() { idPointer[index * idStride] = Int32(token) }

        let mask = try MLMultiArray(shape: [1, 1, NSNumber(value: query), NSNumber(value: end)], dataType: .float16)
        let rowStride = mask.strides[2].intValue
        let columnStride = mask.strides[3].intValue
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
        for row in 0..<query {
            for column in 0..<end {
                maskPointer[row * rowStride + column * columnStride] = column <= end - query + row ? 0 : 0xfbff
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputIds": MLFeatureValue(multiArray: ids), "causalMask": MLFeatureValue(multiArray: mask)
        ])
        let output = try await model.prediction(from: input, using: state)
        guard sample else { return nil }
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else { throw PhoneModelError.invalidBundle }
        return try sampleToken(logits)
    }

    private static func sampleToken(_ logits: MLMultiArray) throws -> Int {
        let shape = logits.shape.map(\.intValue)
        let strides = logits.strides.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] == 128_258,
              logits.dataType == .float16 || logits.dataType == .float32 else { throw PhoneModelError.invalidBundle }
        let offset = (shape[1] - 1) * strides[1]
        let stride = strides[2]
        let half = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
        let full = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let isHalf = logits.dataType == .float16
        var choices: [(token: Int, score: Float)] = []
        choices.reserveCapacity(12)
        for token in 0..<shape[2] {
            let index = offset + token * stride
            let score = isHalf ? Float(Float16(bitPattern: half[index])) : full[index]
            guard score.isFinite else { continue }
            if choices.count == 12, let last = choices.last, score <= last.score { continue }
            let position = choices.firstIndex { score > $0.score } ?? choices.endIndex
            choices.insert((token, score), at: position)
            if choices.count > 12 { choices.removeLast() }
        }
        guard let best = choices.first else { throw PhoneModelError.emptyResponse }
        let weights = choices.map { exp(Double($0.score - best.score) / 0.8) }
        var draw = Double.random(in: 0..<weights.reduce(0, +))
        for (choice, weight) in zip(choices, weights) {
            draw -= weight
            if draw <= 0 { return choice.token }
        }
        return best.token
    }

    private final class DownloadObserver: NSObject, URLSessionDownloadDelegate {
        let report: @Sendable (Int64) -> Void

        init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) { }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            DolphinPhoneRuntime.validHubURL(request.url) ? request : nil
        }
    }

    private static let downloads: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        return URLSession(configuration: configuration)
    }()

    private static func validHubURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    @MainActor private static func fetch(_ asset: Asset, to destination: URL,
                                        progress: @escaping @MainActor (Int64) -> Void) async throws {
        guard let source = URL(string: "https://huggingface.co/ales27pm/Dolphin3.0-CoreML/resolve/\(revision)/\(asset.path)"),
              validHubURL(source) else { throw PhoneModelError.invalidBundle }
        let observer = DownloadObserver { written in
            Task { @MainActor in progress(min(Int64(asset.bytes), max(0, written))) }
        }
        let (temporary, response) = try await downloads.download(from: source, delegate: observer)
        let files = FileManager.default
        defer { try? files.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, validHubURL(http.url),
              try await verified(temporary, asset: asset) else { throw PhoneModelError.invalidBundle }
        try Task.checkCancellation()
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LocalFileStore.protectFile(temporary)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
    }

    private static func matchesSize(_ url: URL, bytes: Int) -> Bool {
        (try? LocalFileStore.checkedFileSize(url, maximumBytes: bytes)) == bytes
    }

    private static func verified(_ url: URL, asset: Asset) async throws -> Bool {
        guard matchesSize(url, bytes: asset.bytes) else { return false }
        let check = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
        }
        return try await withTaskCancellationHandler {
            try await check.value
        } onCancel: {
            check.cancel()
        }
    }
}
