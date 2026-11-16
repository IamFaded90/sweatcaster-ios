import Foundation

/// An agent turn shares the same request and local-tool policy across the phone session and PC provider.
@MainActor struct AgentReplyDriver {
    enum Provider {
        case phone
        case computer(LiveAPI)
    }

    let provider: Provider
    let model: String

    func respond(to prompt: String, original: String, instructions: String, history: [PhoneModels.ChatExchange],
                 usesTools: Bool, showsPartialText: Bool, update: @escaping @MainActor (String) -> Void) async throws -> String {
        let text = try await request(prompt, instructions: instructions, history: history) { partial in
            guard showsPartialText, !Task.isCancelled else { return }
            let first = partial.trimmingCharacters(in: .whitespacesAndNewlines).first
            // Tool and card payloads are rendered only after their shape is known.
            if first != "{" && first != "\u{0060}" { update(partial) }
        }
        guard usesTools, let tool = AgentLocalTool.answer(text) else { return text }
        do {
            return try await request(original + "\n\nVerificeret værktøjsresultat: " + tool,
                                     instructions: instructions + "\nBrug værktøjsresultatet i svaret. Svar med almindelig tekst.",
                                     history: history, update: update)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return tool
        }
    }

    private func request(_ prompt: String, instructions: String, history: [PhoneModels.ChatExchange],
                         update: @escaping @MainActor (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        var text = ""
        switch provider {
        case .phone:
            try await PhoneModels.reply(modelID: model, prompt: prompt, instructions: instructions, history: history) {
                text = $0
                update($0)
            }
        case .computer(let api):
            let brief = history.suffix(2).map { "Dig: \($0.prompt)\nAgent: \($0.reply)" }.joined(separator: "\n")
            text = try await api.agentChat(model: model, prompt: String(prompt.unicodeScalars.prefix(2_000)),
                                           instructions: String(instructions.prefix(1_800)) + "\nTidligere samtale:\n" + brief)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
        return text
    }
}
