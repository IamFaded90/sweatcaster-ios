import Foundation

enum ModelRouter {
    static let enabledKey = AppStorageKeys.chatAutoModelRouter

    enum Location: Equatable { case phone, pc }
    enum Intent: Equatable { case text, code, long, image, cardCollection }

    struct Candidate: Equatable {
        let id: String
        let name: String
        let location: Location
        let ready: Bool
        var favorite = false
        var defaultChoice = false
        var code = false
        var longContext = false
        var acceptsImages = false
    }

    struct Selection: Equatable {
        let candidate: Candidate
        let reason: String
    }

    static func intent(for text: String, hasImage: Bool = false) -> Intent {
        if hasImage { return .image }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if message.hasPrefix("kortsamling:") { return .cardCollection }
        let words = message.split { !$0.isLetter && !$0.isNumber }
        let codeTerms = ["kode", "script", "funktion", "bug", "python", "swift"]
        if words.contains(where: { word in codeTerms.contains(where: { word.hasPrefix($0) }) }) { return .code }
        return message.unicodeScalars.count > 1_000 ? .long : .text
    }

    static func choose(text: String, hasImage: Bool = false, candidates: [Candidate]) -> Selection? {
        let task = intent(for: text, hasImage: hasImage)
        let ready = candidates.filter(\.ready)
        let suitable = ready.filter { preference(for: $0, task: task) != nil }
        if let match = suitable.min(by: { rank($0, task: task) < rank($1, task: task) }) {
            return Selection(candidate: match, reason: reason(for: task, specialized: true))
        }
        guard task == .code || task == .long,
              let fallback = ready.min(by: { rank($0, task: .text) < rank($1, task: .text) }) else { return nil }
        return Selection(candidate: fallback, reason: reason(for: task, specialized: false))
    }

    private static func rank(_ model: Candidate, task: Intent) -> (Int, Int, Int) {
        (model.favorite ? 0 : 1, preference(for: model, task: task) ?? 9, model.defaultChoice ? 0 : 1)
    }

    private static func preference(for model: Candidate, task: Intent) -> Int? {
        let keys = [model.id, model.name].map { value in value.lowercased().filter { $0.isLetter || $0.isNumber } }
        func matches(_ names: [String]) -> Bool { keys.contains { key in names.contains { key.hasPrefix($0) } } }
        switch task {
        case .text:
            if model.location == .phone && matches(["minicpm51b"]) { return 0 }
            if model.location == .pc && matches(["ornith109b"]) { return 1 }
            return model.location == .phone ? 2 : 3
        case .code:
            if model.location == .pc && matches(["qwen257b", "qwen25coder7b", "qwen38b"]) { return 0 }
            if model.location == .pc && model.code { return 1 }
            if model.location == .phone && matches(["minicpm51b"]) { return 2 }
            return model.code ? 3 : nil
        case .long:
            if model.location == .pc && matches(["gemma49b"]) { return 0 }
            if model.location == .phone && matches(["gemma4e2b"]) { return 1 }
            return model.longContext ? 2 : nil
        case .image:
            guard model.acceptsImages else { return nil }
            if model.location == .phone && matches(["qwen3vl2b"]) { return 0 }
            return model.location == .pc ? 1 : 2
        case .cardCollection:
            return model.location == .pc ? 0 : nil
        }
    }

    private static func reason(for task: Intent, specialized: Bool) -> String {
        switch task {
        case .text: "Klar til almindelig chat."
        case .code: specialized ? "Beskeden handler om kode." : "Ingen særskilt kodemodel er klar. Denne model kan svare på tekst."
        case .long: specialized ? "Beskeden er over 1.000 tegn." : "Ingen model til lange beskeder er klar. Denne model kan svare på tekst."
        case .image: "Modellen kan modtage billeder."
        case .cardCollection: "Kortsamlingen ligger på PC’en."
        }
    }
}
