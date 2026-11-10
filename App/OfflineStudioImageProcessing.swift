// OfflineStudioImageProcessing.swift
// Kører lokal billedgenerering, ressourcekontrol og opskalering.

import CoreImage
import MediaGenerationKit
import SwiftUI
import UIKit

extension OfflineStudio {
    func prepareImageFolder(_ url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    func imageDestination(in folder: URL) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        return folder.appendingPathComponent("\(timestamp)-\(UUID()).png")
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

    func renderStudioImage(model: StudioImageModel, prompt: String, lora: String, seed: UInt32,
                                   sourceImage: Data?, variation: URL?, destination: URL?, within outputDirectory: URL,
                                   label: String, negativePrompt: String = "",
                                   requireOffline: Bool = false) async throws -> Data? {
        let destination = try destination.map { try LocalFileStore.safeWriteURL($0, within: outputDirectory) }
        if requireOffline { privateImageRendering = true }
        defer { imageCooling = false; privateImageRendering = false }
        var mustCool = isImageThermallyConstrained
        while true {
            try Task.checkCancellation()
            if requireOffline && !canRenderPrivateImages { throw StudioImageInterruption.network }
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
                            if requireOffline && !canRenderPrivateImages { throw StudioImageInterruption.network }
                            LocalCompute.beginModelLoad()
                            var pipeline = try await MediaGenerationPipeline.fromPretrained(model.id, backend: .local)
                            LocalCompute.didLoadModel()
                            try Task.checkCancellation()
                            if requireOffline && !canRenderPrivateImages { throw StudioImageInterruption.network }
                            model.applyRenderProfile(to: &pipeline.configuration)
                            pipeline.configuration.batchCount = 1
                            pipeline.configuration.batchSize = 1
                            pipeline.configuration.seed = seed
                            pipeline.configuration.loras = lora.isEmpty ? [] : [.init(file: lora, weight: 1, mode: .base)]
                            var inputs: [MediaGenerationPipeline.Input] = []
                            if let variation, let bytes = privateImages[variation] {
                                inputs = [MediaGenerationPipeline.data(bytes)]
                                pipeline.configuration.strength = 0.32
                            } else if let variation, variation.isFileURL, !requireOffline {
                                inputs = [MediaGenerationPipeline.file(variation.path)]
                                pipeline.configuration.strength = 0.32
                            } else if let sourceImage {
                                inputs = [MediaGenerationPipeline.data(sourceImage)]
                                pipeline.configuration.strength = 0.55
                            }
                            let results = try await pipeline.generate(prompt: prompt, negativePrompt: negativePrompt, inputs: inputs)
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
                        group.addTask { @MainActor in
                            while !Task.isCancelled {
                                try self.checkImageBattery()
                                if requireOffline && !self.canRenderPrivateImages { throw StudioImageInterruption.network }
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
        let requireOffline = privateSession
        let directory = FileManager.default.temporaryDirectory
        let destination = requireOffline ? nil : directory.appendingPathComponent("\(UUID()).png")
        imageBenchmark = nil
        run("Måler billedmodellens hastighed…") {
            defer { if let destination { try? FileManager.default.removeItem(at: destination) } }
            let start = ContinuousClock.now
            do {
                _ = try await renderStudioImage(model: selected, prompt: "A red apple on a light table", lora: "",
                                                seed: 42, sourceImage: nil, variation: nil, destination: destination, within: directory,
                                                label: "Måler billedmodellens hastighed…", requireOffline: requireOffline)
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
