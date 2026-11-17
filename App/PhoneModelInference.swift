// Shared on-device chat inference and model benchmarks.
import CoreML
import CoreMLLLM
import Foundation
import FoundationModels

extension PhoneModels {
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
        if let model = GGUFPhoneModel.installed(id: modelID) {
            _ = try await GGUFPhoneRuntime.generate(model, prompt: prompt, instructions: instructions,
                                                    history: history, maximumTokens: 384, update: update)
            return
        } else if modelID == "apple" {
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
            var messages: [CoreMLLLM.Message] = []
            if !instructions.isEmpty { messages.append(.init(role: .system, content: instructions)) }
            for exchange in history {
                messages.append(.init(role: .user, content: exchange.prompt))
                messages.append(.init(role: .assistant, content: exchange.reply))
            }
            messages.append(.init(role: .user, content: prompt))
            _ = try await streamCoreML(folder: folder, modelID: modelID, messages: messages) {
                answer = $0
                update(answer)
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneModelError.emptyResponse
        }
    }

    @MainActor private static func streamCoreML(
        folder: URL, modelID: String, messages: [CoreMLLLM.Message], maxTokens: Int = 384,
        update: @escaping (String) -> Void
    ) async throws -> Double {
        let units: [MLComputeUnits] = modelID == ModelDownloader.ModelInfo.lfm2_5_350m.id
            ? [.cpuAndNeuralEngine, .cpuOnly] : [.cpuAndNeuralEngine]
        for (attempt, computeUnits) in units.enumerated() {
            var answer = ""
            do {
                LocalCompute.beginModelLoad()
                let model = try await CoreMLLLM.load(from: folder, computeUnits: computeUnits)
                try Task.checkCancellation()
                LocalCompute.didLoadModel()
                for await token in try await model.stream(messages, maxTokens: maxTokens) {
                    try Task.checkCancellation()
                    answer += token
                    update(answer)
                }
                try Task.checkCancellation()
                // The upstream AsyncStream finishes silently when inference throws.
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PhoneModelError.emptyResponse
                }
                return model.tokensPerSecond
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), answer.isEmpty,
                      attempt + 1 < units.count else { throw error }
                AppDiagnostics.record(error)
            }
        }
        throw PhoneModelError.emptyResponse
    }

    @MainActor static func benchmark(modelID: String) async throws -> String {
        let prompt = "Skriv to korte sætninger om, hvordan regn dannes."
        return try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            if let model = GGUFPhoneModel.installed(id: modelID) {
                let sample = "Hvad mener jeg med: I wud lik to boock a tabel for too on Fryday? Svar kort på dansk."
                let result = try await GGUFPhoneRuntime.generate(model, prompt: sample,
                    instructions: "Svar med højst to sætninger og uden at vise din fremgangsmåde.",
                    history: [], maximumTokens: 128, update: { _ in })
                let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                let ram = result.footprint.map { " · RAM målt under testen: " + ModelDiskStorage.gigabytes(Int64($0)) } ?? ""
                return "\(model.name)\nFørste tekst: \(result.firstToken.formatted(format)) sek. · \(result.tokensPerSecond.formatted(format)) tokens/sek.\(ram)\n\nPrøvesvar: \(result.reply)"
            }
            if modelID == "apple" {
                guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
                let session = LanguageModelSession()
                LocalCompute.didLoadModel()
                let start = Date()
                // An English prompt also works when Apple's installed model lacks Danish.
                let result = try await session.respond(to: "In two short sentences, explain how rain forms.")
                try Task.checkCancellation()
                guard !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PhoneModelError.emptyResponse
                }
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
            var reply = ""
            let start = ContinuousClock.now
            let rate = try await streamCoreML(folder: folder, modelID: modelID,
                                             messages: [.init(role: .user, content: prompt)], maxTokens: 64) {
                reply = $0
            }
            try Task.checkCancellation()
            guard !reply.isEmpty else { throw PhoneModelError.emptyResponse }
            let name = catalog.first(where: { $0.id == modelID })?.name ?? "Importeret model"
            if !rate.isFinite || rate <= 0 {
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                return "\(name): \(seconds.formatted(.number.precision(.fractionLength(1)))) sek. pr. svar."
            }
            return "\(name): \(rate.formatted(.number.precision(.fractionLength(1)))) tokens/sek."
        }
    }

}
