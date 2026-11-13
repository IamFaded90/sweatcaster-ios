// On-device text inference and background model downloads.
import CoreML
import CoreMLLLM
import CoreGraphics
import Foundation
import FoundationModels
import Observation
import UIKit
import UserNotifications

enum PhoneModelError: Error {
    case unavailable, invalidBundle, emptyResponse, downloadBusy, contextLimit
}

enum PhoneModels {
    static let selectionKey = AppStorageKeys.phoneModel
    static let favoritesKey = AppStorageKeys.phoneModelFavorites
    static let liteBatteryKey = AppStorageKeys.phoneModelLiteBattery
    static let downloadedRoot = URL.documentsDirectory.appending(path: "Models", directoryHint: .isDirectory)

    struct ChatExchange {
        let prompt: String
        let reply: String
    }

    struct Entry: Identifiable {
        enum PackageFormat: String {
            case coreML = "Core ML"
            case coreAI = "Core AI"
        }

        let id, name, description: String
        let bestFor: String
        let model: ModelDownloader.ModelInfo?
        let modelCardRepository: String
        let packageFormat: PackageFormat
        let estimatedDownloadBytes: Int64
        let minimumFreeBytes: Int64
        let unavailableReason: String?

        var modelCardURL: URL? { URL(string: "https://huggingface.co/\(modelCardRepository)") }
        var recommendsPC: Bool { estimatedDownloadBytes > 3_000_000_000 }
    }

    static func hasDownloadSpace(bytes: Int64) -> Bool {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0) >= bytes
    }

    static var catalog: [Entry] {
        [
            .init(id: ModelDownloader.ModelInfo.lfm2_5_350m.id, name: "LFM2.5 350M",
                  description: "Den letteste tekstmodel i kataloget.", bestFor: "Korte svar og automatisk skift ved lavt batteri.",
                  model: .lfm2_5_350m, modelCardRepository: "mlboydaisuke/lfm2.5-350m-coreml", packageFormat: .coreML,
                  estimatedDownloadBytes: 850_000_000, minimumFreeBytes: 1_200_000_000,
                  unavailableReason: nil),
            .init(id: ModelDownloader.ModelInfo.qwen35_08b.id, name: "Qwen3.5 0.8B",
                  description: "Kompakt tekstmodel til almindelig chat.", bestFor: "Korte spørgsmål, enkle opgaver og kodeforklaringer.",
                  model: .qwen35_08b, modelCardRepository: "mlboydaisuke/qwen3.5-0.8B-CoreML", packageFormat: .coreML,
                  estimatedDownloadBytes: 1_261_991_992 + QwenPhoneRuntime.Variant.compact.tokenizerBytes,
                  minimumFreeBytes: 2_200_000_000,
                  unavailableReason: nil),
            .init(id: "minicpm5-1b", name: "MiniCPM5 1B",
                  description: "Kompakt tekstmodel med særskilt tilstand til ræsonnement.", bestFor: "Korte spørgsmål og logiske opgaver.",
                  model: nil, modelCardRepository: "mlboydaisuke/MiniCPM5-1B-CoreAI", packageFormat: .coreAI,
                  estimatedDownloadBytes: 1_300_000_000, minimumFreeBytes: 0,
                  unavailableReason: "iPhone-pakken kræver iOS 27 og en Core AI-motor. FadedAI har endnu ikke denne motor."),
            .init(id: ModelDownloader.ModelInfo.qwen3vl_2b.id, name: "Qwen3-VL 2B",
                  description: "Denne pakke kan læse tekst og analysere ét billede ad gangen.", bestFor: "At beskrive billeder og svare på spørgsmål om dem.",
                  model: .qwen3vl_2b, modelCardRepository: "mlboydaisuke/qwen3-vl-2b-coreml", packageFormat: .coreML,
                  estimatedDownloadBytes: QwenPhoneRuntime.visionWeightsBytes + QwenPhoneRuntime.Variant.vision.tokenizerBytes,
                  minimumFreeBytes: 7_000_000_000, unavailableReason: nil),
            .init(id: ModelDownloader.ModelInfo.gemma4e2b.id, name: "Gemma 4 E2B",
                  description: "Større model til tekst og billedanalyse, når billedfilerne er installeret.", bestFor: "Komplekse spørgsmål og længere svar.",
                  model: .gemma4e2b, modelCardRepository: "mlboydaisuke/gemma-4-E2B-coreml", packageFormat: .coreML,
                  estimatedDownloadBytes: 5_400_000_000, minimumFreeBytes: 7_000_000_000,
                  unavailableReason: nil)
        ]
    }

    static var appleAvailable: Bool {
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var importedFolder: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedPhoneModels", directoryHint: .isDirectory)
    }

    static func supportsLocalInference(_ id: String) -> Bool {
        if id == "apple" || id == "imported" { return true }
        return catalog.contains { $0.id == id && $0.model != nil && $0.unavailableReason == nil }
    }

    static func isReady(_ id: String) -> Bool {
        id == "apple" ? appleAvailable : installedDirectory(id) != nil
    }

    static func installedDirectory(_ id: String) -> URL? {
        guard supportsLocalInference(id) else { return nil }
        if id == "imported" {
            return compatibleBundle(importedFolder) ? importedFolder : nil
        }
        guard let model = catalog.first(where: { $0.id == id })?.model else { return nil }
        let downloader = ModelDownloader.shared
        guard !downloader.isDownloading || downloader.downloadingModelId != id else { return nil }
        let folder = downloadedRoot.appending(path: model.folderName, directoryHint: .isDirectory)
        let chunked = id == ModelDownloader.ModelInfo.gemma4e2b.id
        return compatibleBundle(folder, expectsChunked: chunked, qwen: .init(modelID: id)) ? folder : nil
    }

    private static func compatibleBundle(_ folder: URL, expectsChunked: Bool? = nil,
                                         qwen: QwenPhoneRuntime.Variant? = nil,
                                         requireTokenizer: Bool = true) -> Bool {
        // Checking availability must not call the package's cache invalidation code.
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let root = folder.resolvingSymlinksInPath()
        func hasFile(_ path: String, exactSize: Int? = nil) -> Bool {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let file = root.appending(path: path)
            guard file.path == file.resolvingSymlinksInPath().path,
                  let info = try? file.resourceValues(forKeys: keys) else { return false }
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size > 0 else { return false }
            return exactSize.map { size == $0 } ?? true
        }
        func hasCompiledModel(_ name: String) -> Bool {
            hasFile("\(name).mlmodelc/coremldata.bin") && hasFile("\(name).mlmodelc/weights/weight.bin")
        }
        func hasModel(_ name: String) -> Bool {
            let package = hasFile("\(name).mlpackage/Manifest.json")
                && hasFile("\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
                && hasFile("\(name).mlpackage/Data/com.apple.CoreML/weights/weight.bin")
            return hasCompiledModel(name) || package
        }
        if let qwen {
            let weightsAreComplete: Bool
            switch qwen {
            case .compact: weightsAreComplete = qwen.requiredModels.allSatisfy(hasModel)
            case .vision:
                weightsAreComplete = qwen.requiredModels.allSatisfy(hasCompiledModel) || (QwenPhoneRuntime.visionAssets?.allSatisfy {
                    hasFile($0.path, exactSize: Int($0.bytes))
                } ?? false)
            }
            return (!requireTokenizer || qwen.tokenizerFiles.allSatisfy { hasFile("hf_model/\($0.name)", exactSize: $0.bytes) })
                && hasFile("\(qwen.chunks)/embed_weight.bin", exactSize: qwen.embeddingBytes)
                && weightsAreComplete
        }
        guard hasFile("model_config.json"), hasFile("hf_model/tokenizer.json"), hasFile("hf_model/tokenizer_config.json") else {
            return false
        }
        let chunked = ["chunk1.mlmodelc", "chunk1.mlpackage"].contains { name in
            FileManager.default.fileExists(atPath: folder.appending(path: name).path)
        }
        if let expectsChunked, expectsChunked != chunked { return false }
        guard chunked else { return hasModel("model") }
        let fourChunks = ["chunk2", "chunk3", "chunk4"].allSatisfy(hasModel)
        let threeChunks = ["chunk2_3way", "chunk3_3way"].allSatisfy(hasModel)
        let sidecars = ["embed_tokens_q8.bin", "embed_tokens_scales.bin", "embed_tokens_per_layer_q8.bin",
                        "embed_tokens_per_layer_scales.bin", "per_layer_projection.bin", "per_layer_norm_weight.bin",
                        "cos_sliding.npy", "sin_sliding.npy", "cos_full.npy", "sin_full.npy"]
        return hasModel("chunk1") && (fourChunks || threeChunks) && sidecars.allSatisfy { hasFile($0) }
    }

    static var compactQwenWeightsFolder: URL? {
        let model = ModelDownloader.ModelInfo.qwen35_08b
        let folder = downloadedRoot.appending(path: model.folderName, directoryHint: .isDirectory)
        return compatibleBundle(folder, qwen: .compact, requireTokenizer: false) ? folder : nil
    }

    @MainActor static func effectiveModelID(_ selected: String) -> String {
        liteModeActive(for: selected) ? ModelDownloader.ModelInfo.lfm2_5_350m.id : selected
    }

    @MainActor static func liteModeActive(for selected: String) -> Bool {
        selected != ModelDownloader.ModelInfo.lfm2_5_350m.id && shouldUseLiteModel
    }

    @MainActor static var shouldUseLiteModel: Bool {
        let level = UIDevice.current.batteryLevel
        return UserDefaults.standard.bool(forKey: liteBatteryKey)
            && level >= 0 && level < 0.20
            && installedDirectory(ModelDownloader.ModelInfo.lfm2_5_350m.id) != nil
    }

    static func prefersPC(_ message: String, previousCharacters: Int) -> Bool {
        if message.count + previousCharacters > 3_000 || message.count > 1_200 { return true }
        let text = message.lowercased()
        return ["video", "klip", "render", "researcher", "søg på", "søg efter", "websøg",
                "seneste nyt", "min pc", "på pc", "file explorer", "agent-hub"].contains { text.contains($0) }
    }

    private static func minimumMemory(for modelID: String) -> UInt64 {
        switch modelID {
        case "apple": 256
        case ModelDownloader.ModelInfo.lfm2_5_350m.id: 512
        case ModelDownloader.ModelInfo.qwen35_08b.id: 1_536
        case ModelDownloader.ModelInfo.qwen3vl_2b.id: 2_560
        default: 2_048
        }
    }

    @MainActor static func reply(modelID: String, prompt: String, instructions: String = "",
                                 history: [ChatExchange] = [], update: @escaping (String) -> Void) async throws {
        try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            try await streamReply(modelID: modelID, prompt: prompt, instructions: instructions, history: history, update: update)
        }
    }

    @MainActor private static func streamReply(modelID: String, prompt: String, instructions: String,
                                              history: [ChatExchange],
                                              update: @escaping (String) -> Void) async throws {
        var answer = ""
        if modelID == "apple" {
            guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
            let defaults = "Svar kort på brugerens sprog. Du har kun adgang til teksten i chatten."
            let session = LanguageModelSession(instructions: instructions.isEmpty ? defaults : instructions)
            LocalCompute.didLoadModel()
            for try await snapshot in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                answer = snapshot.content
                update(answer)
            }
        } else {
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            if let variant = QwenPhoneRuntime.Variant(modelID: modelID) {
                _ = try await QwenPhoneRuntime.generate(variant, folder: folder, prompt: prompt, instructions: instructions,
                                                       history: history, maxTokens: 384, update: update)
                return
            }
            LocalCompute.beginModelLoad()
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            var messages: [CoreMLLLM.Message] = []
            if !instructions.isEmpty { messages.append(.init(role: .system, content: instructions)) }
            for exchange in history {
                messages.append(.init(role: .user, content: exchange.prompt))
                messages.append(.init(role: .assistant, content: exchange.reply))
            }
            messages.append(.init(role: .user, content: prompt))
            for await token in try await model.stream(messages, maxTokens: 384) {
                try Task.checkCancellation()
                answer += token
                update(answer)
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneModelError.emptyResponse
        }
    }

    static var readyVisionModelIDs: [String] {
        let qwen = ModelDownloader.ModelInfo.qwen3vl_2b.id
        let gemma = ModelDownloader.ModelInfo.gemma4e2b.id
        var ready: [String] = []
        if installedDirectory(qwen) != nil { ready.append(qwen) }
        if let folder = installedDirectory(gemma), ["vision.mlmodelc", "vision.mlpackage"].contains(where: { name in
            let url = folder.appending(path: name)
            let flags = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return flags?.isDirectory == true && flags?.isSymbolicLink != true
        }) { ready.append(gemma) }
        return ready
    }

    static func routingCapabilities(for id: String) -> [String] {
        switch id {
        case ModelDownloader.ModelInfo.qwen35_08b.id: ["code"]
        case ModelDownloader.ModelInfo.gemma4e2b.id: ["vision", "long_context"]
        case ModelDownloader.ModelInfo.qwen3vl_2b.id: ["vision"]
        case "minicpm5-1b": ["long_context"]
        default: []
        }
    }

    @MainActor static func analyzeImage(modelID: String, image: CGImage, prompt: String) async throws -> String {
        guard readyVisionModelIDs.contains(modelID) else { throw PhoneModelError.unavailable }
        return try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            if let variant = QwenPhoneRuntime.Variant(modelID: modelID) {
                return try await QwenPhoneRuntime.generate(variant, folder: folder, prompt: prompt, instructions: "",
                                                           image: image, maxTokens: 256, update: { _ in }).text
            }
            LocalCompute.beginModelLoad()
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            guard model.supportsVision else { throw PhoneModelError.invalidBundle }
            LocalCompute.didLoadModel()
            let result = try await model.generate(prompt, image: image, maxTokens: 256)
            try Task.checkCancellation()
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
            return result
        }
    }

    @MainActor static func benchmark(modelID: String) async throws -> String {
        let prompt = "Skriv to korte sætninger om, hvordan regn dannes."
        return try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            if modelID == "apple" {
                guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
                let session = LanguageModelSession()
                LocalCompute.didLoadModel()
                let start = Date()
                _ = try await session.respond(to: prompt)
                try Task.checkCancellation()
                let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
                return "Apple Foundation Models: \(seconds) sek. pr. svar."
            }
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            if let variant = QwenPhoneRuntime.Variant(modelID: modelID) {
                let result = try await QwenPhoneRuntime.generate(variant, folder: folder, prompt: prompt, instructions: "",
                                                                maxTokens: 64, update: { _ in })
                let name = catalog.first(where: { $0.id == modelID })?.name ?? "Qwen"
                return "\(name): \(result.rate.formatted(.number.precision(.fractionLength(1)))) tokens/sek. inkl. promptbehandling."
            }
            LocalCompute.beginModelLoad()
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            let reply = try await model.generate(prompt, maxTokens: 64)
            try Task.checkCancellation()
            let rate = model.tokensPerSecond
            guard !reply.isEmpty, rate.isFinite, rate > 0 else { throw PhoneModelError.emptyResponse }
            let name = catalog.first(where: { $0.id == modelID })?.name ?? "Importeret model"
            return "\(name): \(rate.formatted(.number.precision(.fractionLength(1)))) tokens/sek."
        }
    }

    static func importFolder(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        guard compatibleBundle(source) else { throw PhoneModelError.invalidBundle }
        let bytes = try inspectImportTree(source)
        guard hasDownloadSpace(bytes: bytes) else { throw CocoaError(.fileWriteOutOfSpace) }
        let parent = importedFolder.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { throw PhoneModelError.invalidBundle }
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = parent.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw PhoneModelError.invalidBundle
        }
        let staging = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        guard try inspectImportTree(staging, protectFiles: true) == bytes else { throw PhoneModelError.invalidBundle }
        guard compatibleBundle(staging) else { throw PhoneModelError.invalidBundle }
        var modelDirectory = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try modelDirectory.setResourceValues(values)
        if files.fileExists(atPath: importedFolder.path) {
            let existing = try importedFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard existing.isDirectory == true, existing.isSymbolicLink != true else { throw PhoneModelError.invalidBundle }
            _ = try files.replaceItemAt(importedFolder, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: importedFolder)
        }
    }

    private static func inspectImportTree(_ folder: URL, protectFiles: Bool = false) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = try folder.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw PhoneModelError.invalidBundle }
        var failure: Error?
        guard let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
                                                            options: [], errorHandler: { _, error in
            failure = error
            return false
        }) else { throw PhoneModelError.invalidBundle }
        var bytes: Int64 = 0
        for case let file as URL in contents {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw PhoneModelError.invalidBundle }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw PhoneModelError.invalidBundle
            }
            if protectFiles { try LocalFileStore.protectFile(file) }
            let (total, overflow) = bytes.addingReportingOverflow(Int64(size))
            guard !overflow else { throw PhoneModelError.invalidBundle }
            bytes = total
        }
        if let failure { throw failure }
        return bytes
    }
}

@MainActor @Observable final class PhoneModelDownloads {
    static let shared = PhoneModelDownloads()
    static let backgroundIdentifier = "com.coreml-llm.model-download"
    private let key = AppStorageKeys.phoneModelPendingDownload
    private let previousSelectionKey = AppStorageKeys.phoneModelSelectionBeforeDownload
    private var observing = false
    private var tokenizerPreparation: Task<Void, Error>?
    private(set) var preparingModelID: String?
    private(set) var directModelID: String?
    private(set) var directProgress = 0.0

    func activate() {
        let downloader = ModelDownloader.shared
        if !observing {
            observing = true
            observeChanges()
        }
        if downloader.isPaused,
           let pending = UserDefaults.standard.string(forKey: key), pending == downloader.downloadingModelId {
            if PhoneModels.supportsLocalInference(pending) { downloader.resumeDownload() }
            else { cancel() }
        }
        Task { await finishPendingDownload() }
    }

    func resumeInterruptedVisionDownload() async {
        await finishPendingDownload(resumeVision: true)
    }

    func download(_ model: ModelDownloader.ModelInfo) async throws {
        let downloader = ModelDownloader.shared
        guard PhoneModels.supportsLocalInference(model.id) else { throw PhoneModelError.unavailable }
        let defaults = UserDefaults.standard
        if PhoneModels.installedDirectory(model.id) != nil {
            defaults.set(model.id, forKey: PhoneModels.selectionKey)
            return
        }
        guard tokenizerPreparation == nil,
              !downloader.isDownloading || (downloader.isPaused && downloader.downloadingModelId == model.id) else {
            throw PhoneModelError.downloadBusy
        }
        defaults.set(model.id, forKey: key)
        defaults.set(defaults.string(forKey: PhoneModels.selectionKey) ?? "apple", forKey: previousSelectionKey)
        do {
            switch QwenPhoneRuntime.Variant(modelID: model.id) {
            case .compact?:
                if PhoneModels.compactQwenWeightsFolder == nil || downloader.isDownloading {
                    _ = try await downloader.download(model, repair: true)
                }
                guard let folder = PhoneModels.compactQwenWeightsFolder else { throw PhoneModelError.invalidBundle }
                try await prepareQwen(.compact, modelID: model.id, folder: folder)
            case .vision?:
                let folder = PhoneModels.downloadedRoot.appending(path: model.folderName, directoryHint: .isDirectory)
                try await prepareQwen(.vision, modelID: model.id, folder: folder)
            case nil:
                _ = try await downloader.download(model, repair: true)
            }
            try Task.checkCancellation()
            guard PhoneModels.installedDirectory(model.id) != nil else { throw PhoneModelError.invalidBundle }
            await publishCompletionIfReady()
        } catch {
            AppDiagnostics.record(error)
            if defaults.string(forKey: key) == model.id && !downloader.isDownloading {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: previousSelectionKey)
            }
            throw error
        }
    }

    private func prepareQwen(_ variant: QwenPhoneRuntime.Variant, modelID: String, folder: URL) async throws {
        try Task.checkCancellation()
        if let work = tokenizerPreparation, preparingModelID == modelID {
            try await work.value
            return
        }
        if UserDefaults.standard.string(forKey: key) != modelID {
            guard PhoneModels.installedDirectory(modelID) != nil else { throw CancellationError() }
            return
        }
        guard tokenizerPreparation == nil else { throw PhoneModelError.downloadBusy }
        preparingModelID = modelID
        let work = Task {
            try await QwenPhoneRuntime.prepareTokenizer(for: variant, folder: folder)
            // Existing weights can already be complete once the local tokenizer is repaired.
            if case .vision = variant, PhoneModels.installedDirectory(modelID) == nil {
                self.directModelID = modelID
                self.directProgress = 0
                try await QwenPhoneRuntime.installVisionWeights(in: folder) { self.directProgress = $0 }
            }
        }
        tokenizerPreparation = work
        defer { tokenizerPreparation = nil; preparingModelID = nil; directModelID = nil }
        try await work.value
    }

    private func finishPendingDownload(resumeVision: Bool = false) async {
        let defaults = UserDefaults.standard
        if !ModelDownloader.shared.isDownloading, tokenizerPreparation == nil,
           let modelID = defaults.string(forKey: key), PhoneModels.installedDirectory(modelID) == nil,
           let variant = QwenPhoneRuntime.Variant(modelID: modelID) {
            let folder: URL?
            switch variant {
            case .compact:
                folder = PhoneModels.compactQwenWeightsFolder
            case .vision:
                let model = ModelDownloader.ModelInfo.qwen3vl_2b
                folder = resumeVision ? PhoneModels.downloadedRoot.appending(path: model.folderName, directoryHint: .isDirectory) : nil
            }
            if let folder {
                do { try await prepareQwen(variant, modelID: modelID, folder: folder) }
                catch is CancellationError { return }
                catch { AppDiagnostics.record(error); return }
            }
        }
        await publishCompletionIfReady()
    }

    func cancel() {
        tokenizerPreparation?.cancel()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: previousSelectionKey)
        ModelDownloader.shared.cancelDownload()
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        ModelDownloader.shared.backgroundCompletionHandler = {
            Task { @MainActor in
                await self.finishPendingDownload()
                completion()
            }
        }
        activate()
    }

    private func observeChanges() {
        withObservationTracking {
            _ = ModelDownloader.shared.isDownloading
            _ = ModelDownloader.shared.refreshTrigger
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeChanges()
                await self.finishPendingDownload()
            }
        }
    }

    private func publishCompletionIfReady() async {
        let downloader = ModelDownloader.shared
        let defaults = UserDefaults.standard
        guard !downloader.isDownloading,
              let id = defaults.string(forKey: key),
              let entry = PhoneModels.catalog.first(where: { $0.id == id }),
              PhoneModels.installedDirectory(id) != nil else { return }
        let previousSelection = defaults.string(forKey: previousSelectionKey)
        if previousSelection == (defaults.string(forKey: PhoneModels.selectionKey) ?? "apple") {
            defaults.set(id, forKey: PhoneModels.selectionKey)
        }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: previousSelectionKey)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Din lokale model er klar!"
        content.body = entry.name
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "model-download-\(UUID())", content: content, trigger: nil))
    }
}

@MainActor final class FadedAIModelDownloadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = JobNotifications.shared
        UIDevice.current.isBatteryMonitoringEnabled = true
        PhoneModelDownloads.shared.activate()
        StudioImageDownloads.shared.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        switch identifier {
        case PhoneModelDownloads.backgroundIdentifier:
            PhoneModelDownloads.shared.handleBackgroundEvents(completion: completionHandler)
        case StudioImageDownloads.backgroundIdentifier:
            StudioImageDownloads.shared.handleBackgroundEvents(completion: completionHandler)
        default:
            completionHandler()
        }
    }
}
