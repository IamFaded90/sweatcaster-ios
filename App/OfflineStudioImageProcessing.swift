// OfflineStudioImageProcessing.swift
// Kører modelhentning, lokal billedgenerering, ressourcekontrol og opskalering.

import CoreImage
import ImageIO
import MediaGenerationKit
import Observation
import SwiftUI
import UIKit

@MainActor enum StudioImageGeneration {
    static func render(model: StudioImageModel, prompt: String, negative: String = "", lora: String = "",
                       seed: UInt32, source: Data? = nil, variation: Bool = false, destination: URL? = nil,
                       referenceMode: StudioReferenceMode? = nil, referenceMask: StudioReferenceMask? = nil,
                       onLoaded: () throws -> Void = {}) async throws -> Data? {
        try Task.checkCancellation()
        guard model.isInstalled else { throw PhoneModelError.unavailable }
        LocalCompute.beginModelLoad()
        var pipeline = try await MediaGenerationPipeline.fromPretrained(model.id, backend: .local)
        LocalCompute.didLoadModel()
        try Task.checkCancellation()
        try onLoaded()
        model.applyRenderProfile(to: &pipeline.configuration)
        pipeline.configuration.batchCount = 1
        pipeline.configuration.batchSize = 1
        pipeline.configuration.seed = seed
        pipeline.configuration.loras = lora.isEmpty ? [] : [.init(file: lora, weight: 1, mode: .base)]
        var inputs: [MediaGenerationPipeline.Input] = []
        if let source {
            inputs = [MediaGenerationPipeline.data(source)]
            pipeline.configuration.strength = variation ? 0.32 : (referenceMode?.strength ?? 0.55)
            if let referenceMode {
                let photo = referenceSize(source)
                let frame = StudioReferenceMode.dimensions(width: Int(photo.width), height: Int(photo.height), edge: model.renderSize)
                pipeline.configuration.width = frame.width
                pipeline.configuration.height = frame.height
                pipeline.configuration.steps = model.referenceRenderSteps(masked: referenceMask != nil)
                if let referenceMask {
                    let mask = try referenceMask.encoded(source: photo, width: frame.width, height: frame.height)
                    inputs.append(MediaGenerationPipeline.data(mask).mask())
                    pipeline.configuration.strength = referenceMode.maskedStrength
                    pipeline.configuration.preserveOriginalAfterInpaint = true
                    pipeline.configuration.maskBlur = 0
                    pipeline.configuration.maskBlurOutset = 0
                    pipeline.configuration.faceRestoration = nil
                    pipeline.configuration.upscaler = nil
                }
            }
        }
        let results = try await pipeline.generate(prompt: prompt, negativePrompt: negative, inputs: inputs)
        try Task.checkCancellation()
        guard let result = results.first else { throw PhoneModelError.emptyResponse }
        return try autoreleasepool { () -> Data? in
            if let destination {
                try result.write(to: destination, type: .png, options: [.atomic, .completeFileProtection])
                return nil
            }
            guard result.width > 0, result.height > 0, let png = UIImage(result).pngData() else {
                throw PhoneModelError.emptyResponse
            }
            return png
        }
    }

    // Picker JPEGs have already been rotated to the displayed orientation.
    static func referenceSize(_ data: Data) -> CGSize {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int, height > 0 else { return .zero }
        return CGSize(width: width, height: height)
    }
}

enum StudioImageFiles {
    static var library: URL { URL.applicationSupportDirectory.appending(path: "StudioImages", directoryHint: .isDirectory) }

    static func prepare(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    static func destination(in folder: URL) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        return folder.appendingPathComponent("\(timestamp)-\(UUID()).png")
    }

    static func savedImage(_ name: String) -> URL? {
        guard name.utf8.count < 80,
              name.range(of: #"^[0-9]{1,20}-[0-9a-fA-F-]{36}\.png$"#, options: .regularExpression) != nil else { return nil }
        return try? LocalFileStore.safeWriteURL(library.appendingPathComponent(name), within: library)
    }

    static func hasSavedPNG(_ name: String) -> Bool {
        guard let file = savedImage(name),
              let header = try? LocalFileStore.readPrefix(from: file, count: 8, maximumBytes: 15_000_000)
        else { return false }
        return header.elementsEqual([137, 80, 78, 71, 13, 10, 26, 10])
    }

    static func deleteSavedImage(_ file: URL) throws {
        let folder = library
        guard file.isFileURL,
              file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                  == folder.resolvingSymlinksInPath().standardizedFileURL.path,
              file.pathExtension.lowercased() == "png" else { throw LocalFileStore.Failure.invalidPath }
        let store = LocalFileStore(root: folder)
        try store.delete(file)
        try? store.delete(file.appendingPathExtension("json"))
    }
}

extension OfflineStudio {
    var privatePCModelPicker: some View {
        StudioPCImageModelPicker(selection: $sessionPreferences.pcImageModel, catalog: pcImageCatalog) {
            pcImageRefresh += 1
        }
        .task(id: "\(privateImagePC?.queueTargetID ?? ""):\(pcImageRefresh)") {
            guard let api = privateImagePC else { return }
            pcImageCatalog = .checking
            let catalog = await StudioPCImageCatalog.inspect(api)
            if !Task.isCancelled { pcImageCatalog = catalog }
        }
    }

    var loraPreviews: URL { URL.applicationSupportDirectory.appending(path: "StudioLoRAPreviews", directoryHint: .isDirectory) }
    var loraLabels: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: loraLabelsData)) ?? [:]
    }

    func removeImportedLoRA(_ name: String) {
        let prefix = "fadedai-"
        let suffix = "_lora_f16.ckpt"
        guard !privateSession, task == nil, name.hasPrefix(prefix), name.hasSuffix(suffix),
              UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { return }
        let roots = ModelDiskStorage.allowedImageRoots(MediaGenerationEnvironment.default.externalUrls)
        guard let file = roots.lazy.map({ $0.appendingPathComponent(name) }).first(where: {
            (try? LocalFileStore.checkedFileSize($0, maximumBytes: Int.max)) != nil
        }) else { return }
        loraPreviewSelection = nil
        run("Sletter LoRA…") {
            try await LocalCompute.run(minimumMiB: 0) {
                try ModelDiskStorage.delete(.init(url: file, name: name, kind: "LoRA", bytes: 0), within: roots)
            }
            try? LocalFileStore(root: loraPreviews).delete(loraPreviews.appendingPathComponent(name + ".jpg"))
            var labels = loraLabels
            labels.removeValue(forKey: name)
            loraLabelsData = try JSONEncoder().encode(labels)
            if loraName == name { loraName = ""; useLoRA = false }
            loraPreviewRefresh += 1
            status = "LoRA er slettet."
        }
    }

    func downloadImageModel() {
        guard !privateSession, task == nil, let selected = StudioImageModel(rawValue: imageModel) else { return }
        StudioImageDownloads.shared.start(selected)
    }

    func prepareImageFolder(_ url: URL) throws {
        try StudioImageFiles.prepare(url)
    }

    func imageDestination(in folder: URL) -> URL {
        StudioImageFiles.destination(in: folder)
    }

    var isImageThermallyConstrained: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    func checkImageBattery() throws {
        guard imageBatteryProtection else { return }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        if level >= 0, level < 0.15, device.batteryState == .unplugged {
            throw StudioImageInterruption.battery
        }
    }

    func studioImageFailureMessage(_ error: Error, model: String) -> String? {
        let downloadHelp = "Hent billedmodellen under Lokale modeller → Billeder, og prøv igen."
        if let storageError = error as? CocoaError, storageError.code == .fileWriteOutOfSpace {
            return "Der er ikke plads til billedet. Frigør plads på telefonen, og prøv igen."
        }
        switch error {
        case LocalComputeError.busy:
            return "Telefonen kører allerede en lokal AI-opgave. Vent på den, og prøv igen."
        case PhoneModelError.unavailable:
            return downloadHelp
        case PhoneModelError.emptyResponse:
            return "Billedmodellen gav intet resultat. Prøv igen med en enkel prompt, fx En rød stol."
        default:
            break
        }
        guard let failure = error as? MediaGenerationKitError else { return nil }
        switch failure {
        case .unresolvedModelReference, .modelNotFoundInCatalog, .hashMismatch:
            return downloadHelp
        case .insufficientStorage:
            return "Der er for lidt ledig plads. Frigør plads på telefonen, og prøv igen."
        case .invalidModelsDirectory:
            return "Telefonen kunne ikke åbne billedmodellerne. Genåbn FadedAI, og prøv igen."
        case .generationFailed:
            return model == StudioImageModel.fluxKlein.id
                ? "FLUX.2 stoppede under genereringen. Vælg Stable Diffusion 1.5 i billedindstillingerne, og prøv igen."
                : "Billedmodellen stoppede under genereringen. Luk andre tunge opgaver, og prøv igen med en enkel prompt."
        default:
            return nil
        }
    }

    func generateQueuedImages(_ request: StudioImageRequest) async throws {
        guard request.isPrivate == privateSession else { throw CancellationError() }
        let sessionID = temporaryImagesID
        let folder = request.isPrivate ? privateImageFolder : historyFolder
        if request.isPrivate {
            guard request.route != .automatic, isCurrentPrivateSession(sessionID) else { throw CancellationError() }
        }
        let pcAllowed = request.supportsPC && !privateSession && api != nil
        let canFallBack = request.route == .automatic && request.allowPCFallback && pcAllowed
        try Task.checkCancellation()
        var created: [URL] = []
        var photosDenied = false
        if !request.isPrivate { try prepareImageFolder(folder) }
        for index in 0..<request.count {
            try Task.checkCancellation()
            let destination = imageDestination(in: folder)
            let seed = request.seed.map { $0 &+ UInt32(index) } ?? UInt32.random(in: 1...UInt32.max)
            let variation = request.referenceMask == nil && request.seed != nil && index > 0 ? created.first : nil
            let source: String
            let metadata: StudioImageDetails
            if request.isPrivate && request.route == .pc {
                metadata = try await renderPrivateStudioImageOnPC(request, seed: seed, sessionID: sessionID, destination: destination)
                source = "PC"
            } else if request.route == .pc {
                metadata = try await renderStudioImageOnPC(request, to: destination, in: folder)
                source = "PC"
            } else {
                do {
                    guard let model = StudioImageModel(rawValue: request.model) else { throw PhoneModelError.unavailable }
                    try await renderStudioImageOnPhone(request, model: model, seed: seed, index: index,
                                                      variation: variation, sessionID: sessionID,
                                                      destination: destination, folder: folder)
                    source = "Telefon"
                    metadata = StudioImageDetails(prompt: request.prompt, negativePrompt: request.negative,
                                                  seed: seed, model: model.id,
                                                  steps: request.referenceMode == nil ? model.renderSteps :
                                                    model.referenceRenderSteps(masked: request.referenceMask != nil))
                } catch {
                    try Task.checkCancellation()
                    guard canFallBack else { throw error }
                    AppDiagnostics.record(error)
                    metadata = try await renderStudioImageOnPC(request, to: destination, in: folder)
                    source = "PC"
                }
            }
            try Task.checkCancellation()
            storeImageDetails(metadata, for: destination)
            created.append(destination)
            if request.isPrivate { created.removeAll { privateImages[$0] == nil } }
            if index == 0 {
                if !imageOnly {
                    let turn = PrivateChatTurn(prompt: request.prompt, reply: "Billede klar.",
                                               imageName: destination.lastPathComponent, source: source, botID: request.botID)
                    batchTurnID = turn.id
                    turns.append(turn)
                }
                imageURL = destination
                imageComparisonSource = StudioImageComparisonSource(result: destination, bytes: request.sourceImage,
                                                                   mask: request.referenceMask)
            } else {
                imageComparisonSource?.results.insert(destination)
            }
            batchImageURLs = created
            savePrivateConversation()
            if request.autoSave && !request.isPrivate && autoSaveStudioPhotos && !privateSession {
                if !(await saveStudioPhoto(destination)) { photosDenied = true }
            }
        }
        status = request.count > 1 ? "Forslagene er klar. Vælg dit bedste billede." : "Billede klar."
        if photosDenied { status += " Billedet er gemt i studiet. Tjek tilladelsen til Fotos." }
        offlineSuccessHaptic()
    }

    private func renderStudioImageOnPhone(_ request: StudioImageRequest, model: StudioImageModel, seed: UInt32,
                                          index: Int, variation: URL?, sessionID: UUID, destination: URL,
                                          folder: URL) async throws {
        guard model.isInstalled else { throw PhoneModelError.unavailable }
        try checkImageBattery()
        let part = request.count > 1 ? "Genererer \(index + 1) af \(request.count)…" : "Genererer billede på telefonen…"
        let label = request.sourceImage != nil || variation != nil ? part + " Bruger dit billede som base…" : part
        let data = try await renderStudioImage(model: model, prompt: request.prompt, lora: request.lora, seed: seed,
                                               sourceImage: request.sourceImage, variation: variation,
                                               destination: request.isPrivate ? nil : destination, within: folder,
                                               label: label, negativePrompt: request.negative,
                                               privateOutput: request.isPrivate, referenceMode: request.referenceMode,
                                               referenceMask: request.referenceMask)
        try Task.checkCancellation()
        if request.isPrivate {
            guard privateSession, sessionUnlocked, !sessionExpired, sessionID == temporaryImagesID else { throw CancellationError() }
            guard let data else { throw PhoneModelError.emptyResponse }
            try storePrivateImage(data, for: destination)
        }
    }

    private func renderPrivateStudioImageOnPC(_ request: StudioImageRequest, seed: UInt32,
                                               sessionID: UUID, destination: URL) async throws -> StudioImageDetails {
        guard privateSession, request.isPrivate, request.route == .pc,
              let api = privateImagePC else { throw V2Failure.invalidInput }
        var mask: Data?
        if let reference = request.sourceImage, let selection = request.referenceMask {
            let size = StudioImageGeneration.referenceSize(reference)
            mask = try selection.encoded(source: size, width: Int(size.width), height: Int(size.height), repaintValue: 255)
        }
        status = "\(request.pcModel.title) laver dit billede på PC’en…"
        let mode = request.referenceMode
        let bytes = try await api.privateStudioImage(prompt: request.prompt, negative: request.negative,
                                                      reference: request.sourceImage, mask: mask,
                                                      strength: mask == nil ? mode?.strength : mode?.maskedStrength, seed: seed,
                                                      engine: request.pcModel == .realvis ? nil : request.pcModel.rawValue)
        try Task.checkCancellation()
        guard isCurrentPrivateSession(sessionID) else { throw CancellationError() }
        try storePrivateImage(bytes, for: destination)
        return StudioImageDetails(prompt: request.prompt, negativePrompt: request.negative, seed: seed, model: request.pcModel.title)
    }

    private func renderStudioImageOnPC(_ request: StudioImageRequest, to destination: URL,
                                       in folder: URL) async throws -> StudioImageDetails {
        guard !privateSession, request.supportsPC, let api else { throw V2Failure.invalidInput }
        status = "PC’en laver dit billede…"
        let png = try await api.v2GenerateImage(prompt: request.prompt)
        try Task.checkCancellation()
        try LocalFileStore.writeBytes(png, to: destination, within: folder)
        return StudioImageDetails(prompt: request.prompt, model: "PC’ens billedmodel")
    }

    func studioImageErrorMessage(_ error: Error, model: String) -> String {
        if case APIError.http(_, let problem) = error, let message = problem?.message { return message }
        if let failure = error as? V2Failure, case .http(let status, let code, let message) = failure {
            if status == 401 { return "PC’en afviste forbindelsen. Forbind til PC’en igen fra Hjem." }
            if status == 404 { return "Denne PC-installation mangler billedgenerering. Vælg Telefon, eller opdatér FadedAI på PC’en." }
            if code == "DEPENDENCY_MISSING" {
                if message?.contains("Stable Diffusion") == true {
                    return "PC’en mangler sin Stable Diffusion-billedmodel. Tjek modellen i ComfyUI."
                }
                if message?.contains("lang tid") == true {
                    return "PC’en nåede ikke at lave billedet. Vent på den, og prøv igen."
                }
                if message?.contains("fejlede") == true || message?.contains("gyldigt PNG") == true {
                    return "Billedmotoren gav intet brugbart billede. Tjek ComfyUI, og prøv igen."
                }
                return "Tjek, at ComfyUI kører på PC’en, og prøv igen."
            }
        }
        if error is APIError || error is URLError {
            return "Forbindelsen til PC’en blev afbrudt. Tjek forbindelsen, og prøv igen."
        }
        return studioImageFailureMessage(error, model: model) ?? pcBusyMessage(error)
            ?? "Billedet kunne ikke laves. Tjek billedmodel og ledig plads, og prøv igen."
    }

    func renderStudioImage(model: StudioImageModel, prompt: String, lora: String, seed: UInt32,
                                   sourceImage: Data?, variation: URL?, destination: URL?, within outputDirectory: URL,
                                   label: String, negativePrompt: String = "",
                                   privateOutput: Bool = false, referenceMode: StudioReferenceMode? = nil,
                                   referenceMask: StudioReferenceMask? = nil) async throws -> Data? {
        if privateOutput, destination != nil { throw CocoaError(.fileWriteUnsupportedScheme) }
        let destination = try destination.map { try LocalFileStore.safeWriteURL($0, within: outputDirectory) }
        defer { imageCooling = false }
        var mustCool = isImageThermallyConstrained
        while true {
            try Task.checkCancellation()
            try checkImageBattery()
            if mustCool || isImageThermallyConstrained {
                imageCooling = true
                status = "Telefonen er varm. Generering genoptages tidligst om 30 sekunder."
                try await Task.sleep(for: .seconds(30))
                mustCool = false
                continue
            }
            imageCooling = false
            status = label
            do {
                let data: Data? = try await LocalCompute.run(minimumMiB: model.minimumWorkingMemoryMiB) {
                    try await withThrowingTaskGroup(of: Optional<Data>.self) { group in
                        group.addTask { @MainActor in
                            try Task.checkCancellation()
                            status = "Indlæser \(model.title) på telefonen…"
                            let input: Data?
                            let isVariation: Bool
                            if let variation, let bytes = privateImages[variation] {
                                input = bytes
                                isVariation = true
                            } else if let variation, variation.isFileURL, !privateOutput {
                                input = try LocalFileStore.readBytes(from: variation, maximumBytes: 80_000_000)
                                isVariation = true
                            } else {
                                input = sourceImage
                                isVariation = false
                            }
                            return try await StudioImageGeneration.render(model: model, prompt: prompt, negative: negativePrompt,
                                                                          lora: lora, seed: seed, source: input,
                                                                          variation: isVariation, destination: destination,
                                                                          referenceMode: referenceMode, referenceMask: referenceMask) {
                                status = label
                            }
                        }
                        group.addTask { @MainActor in
                            while !Task.isCancelled {
                                try self.checkImageBattery()
                                if self.isImageThermallyConstrained { throw StudioImageInterruption.heat }
                                try await Task.sleep(for: .seconds(1))
                            }
                            throw CancellationError()
                        }
                        defer { group.cancelAll() }
                        guard let result = try await group.next() else { throw PhoneModelError.emptyResponse }
                        return result
                    }
                }
                try Task.checkCancellation()
                return data
            } catch StudioImageInterruption.heat {
                AppDiagnostics.record(StudioImageInterruption.heat)
                if let destination { try? FileManager.default.removeItem(at: destination) }
                mustCool = true
            } catch {
                AppDiagnostics.record(error)
                if let destination { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
        }
    }

    func benchmarkImageModel() {
        guard let selected = StudioImageModel(rawValue: imageModel) else { return }
        let privateOutput = privateSession
        let directory = FileManager.default.temporaryDirectory
        let destination = privateOutput ? nil : directory.appendingPathComponent("\(UUID()).png")
        imageBenchmark = nil
        run("Måler billedmodellens hastighed…") {
            defer { if let destination { try? FileManager.default.removeItem(at: destination) } }
            let start = ContinuousClock.now
            do {
                _ = try await renderStudioImage(model: selected, prompt: "A red apple on a light table", lora: "",
                                                seed: 42, sourceImage: nil, variation: nil, destination: destination, within: directory,
                                                label: "Måler billedmodellens hastighed…", privateOutput: privateOutput)
                let time = start.duration(to: .now).components
                let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
                imageBenchmark = "\(selected.title): \(seconds.formatted(.number.precision(.fractionLength(1)))) sek. pr. billede (\(selected.renderSize) px, \(selected.renderSteps) trin, inkl. indlæsning)."
                status = "Benchmark færdig."
            } catch StudioImageInterruption.battery {
                AppDiagnostics.record(StudioImageInterruption.battery)
                status = "Batteriet er lavt. Sæt telefonen til opladning for at fortsætte."
            }
        }
    }

    func upscaleImage(_ source: URL) {
        let isPrivate = privateSession
        let sessionID = temporaryImagesID
        let input = isPrivate ? privateImages[source] : nil
        guard !isPrivate || input != nil else { return }
        let folder = isPrivate ? privateImageFolder : historyFolder
        let destination = imageDestination(in: folder)
        let details = imageDetails(source)
        studioPage = .images
        run("Opgraderer billede til 4K…") {
            let output: URL?
            if isPrivate {
                output = nil
            } else {
                try prepareImageFolder(folder)
                output = try LocalFileStore.safeWriteURL(destination, within: folder)
            }
            upscaleProgress = 0.05
            var finished = false
            defer {
                upscaleProgress = nil
                if !finished, let output { try? FileManager.default.removeItem(at: output) }
            }
            let result: Data? = try await LocalCompute.run(minimumMiB: 512) {
                let worker = Task.detached(priority: .userInitiated) {
                    try await Self.renderUpscale(from: source, data: input, to: output) { progress in
                        await MainActor.run { upscaleProgress = progress }
                    }
                }
                return try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            }
            try Task.checkCancellation()
            if isPrivate {
                guard isCurrentPrivateSession(sessionID), let result else { throw CancellationError() }
                try storePrivateImage(result, for: destination)
            }
            finished = true
            storeImageDetails(details, for: destination)
            selectHistoryImage(destination)
            status = isPrivate ? "4K-billede klar i sessionen." : "4K-billede klar og gemt."
            offlineSuccessHaptic()
        }
    }

    nonisolated private static func renderUpscale(from source: URL, data: Data?, to destination: URL?,
                                                  progress: @Sendable (Double) async -> Void) async throws -> Data? {
        try Task.checkCancellation()
        let input: CIImage?
        if let data { input = CIImage(data: data, options: [.applyOrientationProperty: true]) }
        else if source.isFileURL { input = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) }
        else { input = nil }
        guard let input,
              input.extent.width > 0, input.extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let scale = 3_840 / max(input.extent.width, input.extent.height)
        guard let filter = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: input,
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ]), let output = filter.outputImage else { throw CocoaError(.fileWriteUnknown) }
        await progress(0.40)
        try Task.checkCancellation()
        let encoded: Data? = try autoreleasepool {
            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            if let destination {
                try context.writePNGRepresentation(of: output, to: destination, format: .RGBA8, colorSpace: colorSpace)
                return nil
            }
            guard let data = context.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
        try Task.checkCancellation()
        await progress(1)
        return encoded
    }
}

private extension StudioImageModel {
    func referenceRenderSteps(masked: Bool) -> Int {
        self == .stableDiffusion ? (masked ? 28 : 24) : renderSteps
    }

    func applyRenderProfile(to configuration: inout MediaGenerationPipeline.Configuration) {
        // The SDK may fall back to a generic preset when its catalog cannot be loaded offline.
        configuration.width = renderSize
        configuration.height = renderSize
        configuration.steps = renderSteps
        configuration.strength = 1
        configuration.seedMode = .scaleAlike
        configuration.resolutionDependentShift = false
        configuration.hiresFix = false
        configuration.teaCache = false
        configuration.controls = []
        switch self {
        case .stableDiffusion:
            configuration.sampler = .DPMPP2MAYS
            configuration.guidanceScale = 5
            configuration.clipSkip = 1
            configuration.shift = 1
            configuration.speedUpWithGuidanceEmbed = false
        case .fluxKlein:
            configuration.sampler = .dDIMTrailing
            configuration.guidanceScale = 1
            configuration.clipSkip = 2
            configuration.shift = 3
            configuration.speedUpWithGuidanceEmbed = true
            configuration.t5TextEncoder = true
        }
    }
}
