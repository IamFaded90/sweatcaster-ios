import Foundation

/// An agent turn shares the same request and local-tool policy across the phone session and PC provider.
@MainActor struct AgentReplyDriver {
    enum Provider {
        case phone
        case computer(LiveAPI)
        case cloud
    }

    let provider: Provider
    let model: String
    var fallbackModel: String? = nil
    var onFallback: (@MainActor (String) -> Void)? = nil
    var onModel: (@MainActor (String) -> Void)? = nil

    func respond(to prompt: String, original: String, instructions: String, history: [PhoneModels.ChatExchange],
                 usesTools: Bool, showsPartialText: Bool, readCalendar: (@MainActor (Date) -> String)? = nil,
                 update: @escaping @MainActor (String) -> Void) async throws -> String {
        do {
            if case .computer(let api) = provider, fallbackModel != nil { _ = try await api.health() }
            let answer = try await respondOnProvider(to: prompt, original: original, instructions: instructions, history: history,
                usesTools: usesTools, showsPartialText: showsPartialText, readCalendar: readCalendar, update: update)
            let explicitlyRepeated = AgentReplyQuality.words(original) == history.last.map { AgentReplyQuality.words($0.prompt) }
                || original.lowercased().range(of: #"\b(?:gentag|repeat|igen ordret)\b"#, options: .regularExpression) != nil
            guard !explicitlyRepeated, !answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  AgentReplyQuality.repeats(answer, previous: history.map(\.reply)) else { return answer }
            update("Jeg retter et gentaget svar…")
            let repaired = try await respondOnProvider(to: prompt, original: original,
                instructions: AgentReplyQuality.repairInstructions(original: instructions), history: history,
                usesTools: usesTools, showsPartialText: showsPartialText, readCalendar: readCalendar, update: update)
            if AgentReplyQuality.repeats(repaired, previous: history.map(\.reply)) {
                return "Jeg sidder fast i et gentaget svar. Jeg har ikke udført en ny handling. Prøv en anden model, eller bed mig begynde forfra med netop denne opgave."
            }
            return repaired
        } catch {
            try Task.checkCancellation()
            guard case .computer = provider, let fallbackModel, PhoneModels.isReady(fallbackModel),
                  AgentInternetTools.isConnectionFailure(error) else { throw error }
            onFallback?(fallbackModel)
            let phone = AgentReplyDriver(provider: .phone, model: fallbackModel)
            return try await phone.respond(to: prompt, original: original, instructions: instructions, history: history,
                usesTools: usesTools, showsPartialText: showsPartialText, readCalendar: readCalendar, update: update)
        }
    }

    private func respondOnProvider(to prompt: String, original: String, instructions: String, history: [PhoneModels.ChatExchange],
                                   usesTools: Bool, showsPartialText: Bool, readCalendar: (@MainActor (Date) -> String)?,
                                   update: @escaping @MainActor (String) -> Void) async throws -> String {
        let text = try await request(prompt, instructions: instructions, history: history) { partial in
            guard showsPartialText, !Task.isCancelled else { return }
            let first = partial.trimmingCharacters(in: .whitespacesAndNewlines).first
            // Tool and card payloads are rendered only after their shape is known.
            if first != "{" && first != "[" && first != "\u{0060}" { update(partial) }
        }
        try Task.checkCancellation()
        guard usesTools else { return text }
        let now = Date.now
        let calendar = Calendar.current
        return try await Self.finishToolRounds(first: text) { request in
            if request.tool == "calendar", let readCalendar {
                guard let days = Int(request.input), (-365...365).contains(days),
                      let date = calendar.date(byAdding: .day, value: days, to: now) else {
                    return "Kalender kan kun læses en dag ad gangen inden for et år."
                }
                return readCalendar(date)
            }
            return AgentLocalTool.answer(request, now: now, calendar: calendar)
        } followUp: { results, final in
            let rule = final ? "Afslut nu med almindelig tekst." : "Bed kun om et nyt opslag, hvis du mangler oplysninger."
            let evidence = "\n\nVerificerede læseopslag:\n" + results.joined(separator: "\n")
            let budget = max(0, 2_000 - evidence.unicodeScalars.count)
            guard original.unicodeScalars.count <= budget else { throw AgentModelContract.Failure.question }
            let context = prompt.hasPrefix(original) && prompt.unicodeScalars.count <= budget ? prompt : original
            return try await request(context + evidence, instructions: rule + " Du har kun læst oplysninger.\n" + instructions,
                                     history: history) { _ in }
        }
    }

    static func finishToolRounds(first: String, resolve: (AgentLocalTool.Request) -> String?,
                                 followUp: ([String], Bool) async throws -> String) async throws -> String {
        var reply = first
        var seen = Set<AgentLocalTool.Request>()
        var results: [String] = []
        while true {
            try Task.checkCancellation()
            guard let calls = AgentLocalTool.requests(reply) else {
                return !results.isEmpty && isToolPayload(reply) ? results.joined(separator: "\n") : displayText(reply)
            }
            for call in calls {
                try Task.checkCancellation()
                guard seen.count < 3, seen.insert(call).inserted, let result = resolve(call) else {
                    return results.isEmpty ? displayText(reply) : results.joined(separator: "\n")
                }
                results.append(result)
            }
            do {
                try Task.checkCancellation()
                reply = try await followUp(results, seen.count == 3)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return results.joined(separator: "\n")
            }
        }
    }

    nonisolated static func displayText(_ reply: String) -> String {
        isToolPayload(reply) ? "Jeg fik ikke gennemført handlingen. Prøv at skrive, hvad du vil have mig til at gøre, eller vælg opgaven i chatmenuen." : reply
    }

    private nonisolated static func isToolPayload(_ reply: String) -> Bool {
        let text = String(decoding: ModelJSON.payload(reply), as: UTF8.self)
        guard text.first == "{" || text.first == "[" else { return false }
        return text.range(of: #""tool"\s*:"#, options: .regularExpression) != nil
    }

    private func request(_ prompt: String, instructions: String, history: [PhoneModels.ChatExchange],
                         update: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        let route: AgentModelContract.Route
        switch provider { case .phone: route = .phone; case .computer: route = .computer; case .cloud: route = .cloud }
        try AgentModelContract.validate(prompt: prompt, instructions: instructions, route: route)
        let boundedHistory = AgentModelContract.history(history.map { ($0.prompt, $0.reply) })
            .map { PhoneModels.ChatExchange(prompt: $0.prompt, reply: $0.reply) }
        var text = ""
        switch provider {
        case .phone:
            try await PhoneModels.reply(modelID: model, prompt: prompt, instructions: instructions, history: boundedHistory) {
                text = $0
                update($0)
            }
        case .computer(let api):
            text = try await api.agentChat(model: model, prompt: prompt, instructions: instructions, history: boundedHistory)
        case .cloud:
            var messages = [["role": "system", "content": instructions]]
            for item in boundedHistory {
                messages.append(["role": "user", "content": item.prompt])
                messages.append(["role": "assistant", "content": item.reply])
            }
            messages.append(["role": "user", "content": prompt])
            if OpenRouterCloud.preferredModels.contains(model) {
                let result = try await OpenRouterCloud.reply(model: model, messages: messages)
                text = result.text
                onModel?(result.modelID ?? "OpenRouter · Model ikke oplyst")
            } else if NvidiaCloud.preferredModels.contains(model) {
                text = try await NvidiaCloud.reply(model: model, messages: messages)
            } else {
                text = try await ComposioCloud.reply(model: model, messages: messages)
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
        return text
    }

    nonisolated static func computerInstructions(_ instructions: String, previous: String) -> String {
        // The PC accepts at most 3,000 Unicode scalars for both the agent profile and conversation context.
        AgentModelContract.legacyHistory(instructions: instructions, previous: previous)
    }
}

extension AgentLocalTool {
    struct Request: Hashable, Decodable {
        let tool: String
        let input: String
        private enum Field: String, CodingKey { case tool, input }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            tool = try fields.decode(String.self, forKey: .tool)
            if let text = try? fields.decode(String.self, forKey: .input) {
                input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if tool == "date" || tool == "calendar" {
                input = String(try fields.decode(Int.self, forKey: .input))
            } else {
                throw DecodingError.typeMismatch(String.self, .init(codingPath: fields.codingPath, debugDescription: "input"))
            }
        }
    }

    static func requests(_ text: String) -> [Request]? {
        let data = ModelJSON.payload(text)
        guard data.count <= 720 else { return nil }
        let decoder = JSONDecoder()
        if data.count <= 240, let call = try? decoder.decode(Request.self, from: data) { return [call] }
        if let batch = try? decoder.decode([Request].self, from: data), (1...3).contains(batch.count) { return batch }
        // Some local models emit one complete JSON object per line in the same answer.
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard (2...3).contains(lines.count), lines.allSatisfy({ $0.utf8.count <= 240 }) else { return nil }
        return try? lines.map { try decoder.decode(Request.self, from: Data($0.utf8)) }
    }
}
