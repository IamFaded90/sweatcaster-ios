// Shared on-device chat inference and model benchmarks.
import CoreML
import CoreMLLLM
import Foundation
import FoundationModels
import Observation

extension PhoneModels.ChatExchange {
    /// Keep both the introduction and late corrections when shortening a previous message.
    func excerpt(promptLimit: Int, replyLimit: Int) -> Self {
        func shorten(_ text: String, to limit: Int) -> String {
            let scalars = text.unicodeScalars
            guard scalars.count > limit else { return text }
            let omission = " […] "
            let available = limit - omission.unicodeScalars.count
            guard available >= 2 else { return String(scalars.suffix(max(0, limit))) }
            let tail = (available + 1) / 2
            return String(scalars.prefix(available - tail)) + omission + String(scalars.suffix(tail))
        }
        return .init(prompt: shorten(prompt, to: promptLimit), reply: shorten(reply, to: replyLimit))
    }

    static func recent(_ exchanges: [Self], for message: String) -> [Self] {
        let candidates = exchanges.suffix(6)
        var remaining = 3_000 - message.unicodeScalars.count
        let cost = candidates.reduce(0) { $0 + $1.prompt.unicodeScalars.count + $1.reply.unicodeScalars.count + 24 }
        if cost <= remaining { return Array(candidates) }
        var recent: [Self] = []
        for turn in candidates.reversed() {
            let available = remaining - 24
            guard available >= 32 else { break }
            let promptLimit = min(480, turn.prompt.unicodeScalars.count, available / 2)
            let clipped = turn.excerpt(promptLimit: promptLimit, replyLimit: min(960, available - promptLimit))
            recent.append(clipped)
            remaining -= clipped.prompt.unicodeScalars.count + clipped.reply.unicodeScalars.count + 24
        }
        return Array(recent.reversed())
    }

    static func studioHistory(_ exchanges: [Self], tokenBudget: Int) -> [Self] {
        // The studio estimates one token per three UTF-8 bytes and reserves 16 per message pair.
        func cost(_ turn: Self) -> Int { (turn.prompt.utf8.count + 2) / 3 + (turn.reply.utf8.count + 2) / 3 + 16 }
        var remaining = tokenBudget
        var recent: [Self] = []
        for turn in exchanges.suffix(8).reversed() {
            guard remaining >= 18 else { break }
            var candidate = turn
            var scalarLimit = min(1_440, (remaining - 16) * 3)
            while cost(candidate) > remaining {
                let promptLimit = min(turn.prompt.unicodeScalars.count, scalarLimit / 2)
                candidate = turn.excerpt(promptLimit: promptLimit, replyLimit: scalarLimit - promptLimit)
                scalarLimit /= 2
            }
            guard !candidate.prompt.isEmpty, !candidate.reply.isEmpty else { break }
            recent.append(candidate)
            remaining -= cost(candidate)
        }
        return Array(recent.reversed())
    }
}

extension PhoneModels {
    @available(iOS 26.0, *)
    static func appleTranscript(instructions: String, history: [ChatExchange]) -> Transcript {
        func segment(_ text: String) -> Transcript.Segment { .text(.init(id: UUID().uuidString, content: text)) }
        var entries: [Transcript.Entry] = [.instructions(.init(segments: [segment(instructions)], toolDefinitions: []))]
        for turn in history {
            entries.append(.prompt(.init(segments: [segment(turn.prompt)])))
            entries.append(.response(.init(assetIDs: [], segments: [segment(turn.reply)])))
        }
        return Transcript(entries: entries)
    }

    @MainActor static func reply(modelID: String, prompt: String, instructions: String = "",
                                 history: [ChatExchange] = [], prefixCache: PhonePromptCache.Scope? = nil,
                                 update: @escaping (String) -> Void) async throws {
        await AgentVoiceDownload.releaseSynthesisResources()
        try Task.checkCancellation()
        try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            try await streamReply(modelID: modelID, prompt: prompt, instructions: instructions, history: history,
                                  prefixCache: prefixCache, update: update)
        }
    }

    @MainActor private static func streamReply(modelID: String, prompt: String, instructions: String,
                                              history: [ChatExchange], prefixCache: PhonePromptCache.Scope?,
                                              update: @escaping (String) -> Void) async throws {
        var answer = ""
        if let model = GGUFPhoneModel.installed(id: modelID) {
            _ = try await GGUFPhoneRuntime.generate(model, prompt: prompt, instructions: instructions,
                                                    history: history, maximumTokens: 384, prefixCache: prefixCache, update: update)
            return
        } else if modelID == "apple" {
            guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
            let defaults = "Svar kort på brugerens sprog. Du har kun adgang til teksten i chatten."
            let rules = instructions.isEmpty ? defaults : instructions
            let session = history.isEmpty ? LanguageModelSession(instructions: rules)
                : LanguageModelSession(transcript: appleTranscript(instructions: rules, history: history))
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
                guard !Task.isCancelled, !(error is CancellationError), answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      attempt + 1 < units.count else { throw error }
                AppDiagnostics.record(error)
            }
        }
        throw PhoneModelError.emptyResponse
    }

    @MainActor static func benchmark(modelID: String, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        let prompt = "In one short English sentence, explain this message: I wud lik to boock a tabel for too on Fryday."
        let limit = 64
        await AgentVoiceDownload.releaseSynthesisResources()
        try Task.checkCancellation()
        return try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            progress("Indlæser modellen og venter på første tekst…")
            let start = ContinuousClock.now
            var firstText: ContinuousClock.Instant?
            var reply = ""
            var rate: Double?
            var memory: UInt64?
            var rateSuffix = ""
            let update: (String) -> Void = { snapshot in
                reply = snapshot
                if firstText == nil, !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstText = .now
                    progress("Modellen skriver prøvesvaret…")
                }
            }
            if let model = GGUFPhoneModel.installed(id: modelID) {
                let result = try await GGUFPhoneRuntime.generate(model, prompt: prompt, instructions: "",
                    history: [], maximumTokens: Int32(limit), update: update)
                rate = result.tokensPerSecond
                memory = result.footprint
            } else if modelID == "apple" {
                guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
                let session = LanguageModelSession()
                LocalCompute.didLoadModel()
                let options = GenerationOptions(maximumResponseTokens: limit)
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    update(snapshot.content)
                }
            } else if let folder = installedDirectory(modelID) {
                if let variant = QwenPhoneRuntime.Variant(modelID: modelID) {
                    let result = try await QwenPhoneRuntime.generate(variant, folder: folder, prompt: prompt,
                        instructions: "", maxTokens: limit, update: update)
                    rate = result.rate
                    rateSuffix = " inkl. promptbehandling"
                } else {
                    rate = try await streamCoreML(folder: folder, modelID: modelID,
                        messages: [.init(role: .user, content: prompt)], maxTokens: limit, update: update)
                }
            } else { throw PhoneModelError.unavailable }
            try Task.checkCancellation()
            guard let firstText, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
            func elapsed(to end: ContinuousClock.Instant) -> String {
                let parts = start.duration(to: end).components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                return seconds.formatted(.number.precision(.fractionLength(1)))
            }
            var lines = [textModelName(modelID), "Første tekst: \(elapsed(to: firstText)) sek. · Hele svaret: \(elapsed(to: .now)) sek."]
            if let rate, rate.isFinite, rate > 0 {
                lines.append("\(rate.formatted(.number.precision(.fractionLength(1)))) tokens/sek.\(rateSuffix)")
            }
            if let memory { lines.append("RAM målt under testen: " + ModelDiskStorage.gigabytes(Int64(memory))) }
            return lines.joined(separator: "\n") + "\n\nPrøvesvar: " + reply
        }
    }
}

@MainActor @Observable final class PhoneBenchmarkRun {
    private(set) var modelID: String?
    private(set) var notice: String?
    private(set) var result: String?
    private(set) var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    func start(modelID: String, measure: @escaping @MainActor (String, @escaping (String) -> Void) async throws -> String = PhoneModels.benchmark) {
        guard task == nil else { return }
        self.modelID = modelID
        result = nil
        notice = "Venter på telefonens modelmotor…"
        task = Task {
            defer { task = nil }
            do {
                try Task.checkCancellation()
                let report = try await measure(modelID) { if !Task.isCancelled { self.notice = $0 } }
                try Task.checkCancellation()
                result = report
                notice = nil
            } catch {
                if Task.isCancelled || error is CancellationError { notice = "Målingen blev afbrudt. Du kan starte den igen." }
                else if case LocalComputeError.busy = error { notice = "Telefonen arbejder allerede. Prøv igen om lidt." }
                else if case LocalComputeError.lowMemory = error { notice = "Der er for lidt fri hukommelse. Vælg en mindre model." }
                else if case PhoneModelError.unavailable = error { notice = "Modellen er ikke længere klar. Vælg en anden model." }
                else if case PhoneModelError.emptyResponse = error { notice = "Modellen gav intet svar på prøven. Prøv en anden model." }
                else { AppDiagnostics.record(error); notice = "Modellen kunne ikke gennemføre prøven. Vælg en anden model." }
            }
        }
    }

    func stop() {
        guard let task, !task.isCancelled else { return }
        notice = "Stopper målingen…"
        task.cancel()
    }
}
