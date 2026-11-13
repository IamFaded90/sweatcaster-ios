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

    static func candidate(id: String, name: String, location: Location, ready: Bool,
                          capabilities: [String], imageReady: Bool? = nil,
                          favorite: Bool = false, defaultChoice: Bool = false) -> Candidate {
        let flags = Set(capabilities.map { $0.lowercased() })
        let modelKey = normalized(id)
        let knownVision = ["qwen3vl2b", "gemma4e2b", "moondream"].contains { modelKey.hasPrefix($0) }
        return Candidate(id: id, name: name, location: location, ready: ready,
                         favorite: favorite, defaultChoice: defaultChoice,
                         code: flags.contains("code") || flags.contains("coding"),
                         longContext: flags.contains("long_context"),
                         acceptsImages: (imageReady ?? true) && (flags.contains("vision") || knownVision))
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func validReportedID(_ value: String?) -> String? {
        guard let value, (1...160).contains(value.utf8.count), value.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [43, 45, 46, 47, 58, 64, 95].contains(byte)
        }) else { return nil }
        return value
    }

    static func intent(for text: String, hasImage: Bool = false) -> Intent {
        if hasImage { return .image }
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = original.lowercased()
        if message.hasPrefix("kortsamling:") { return .cardCollection }
        let words = message.split { !$0.isLetter && !$0.isNumber }
        let codeTerms = ["kode", "script", "funktion", "bug", "python", "swift"]
        if words.contains(where: { word in codeTerms.contains(where: { word.hasPrefix($0) }) }) { return .code }
        return original.unicodeScalars.count > 1_000 ? .long : .text
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

    private static func rank(_ model: Candidate, task: Intent) -> (Int, Int, Int, Int) {
        let declaredCapability = (task == .code && model.code) || (task == .long && model.longContext)
        return (declaredCapability ? 0 : 1, model.favorite ? 0 : 1, preference(for: model, task: task) ?? 9, model.defaultChoice ? 0 : 1)
    }

    private static func preference(for model: Candidate, task: Intent) -> Int? {
        let keys = [model.id, model.name].map(normalized)
        func matches(_ names: [String]) -> Bool { keys.contains { key in names.contains { key.hasPrefix($0) } } }
        switch task {
        case .text:
            if model.defaultChoice { return 0 }
            if model.location == .phone && matches(["qwen3508b"]) { return 1 }
            if model.location == .phone && matches(["minicpm51b"]) { return 2 }
            if model.location == .pc && matches(["ornith109b"]) { return 3 }
            return 4
        case .code:
            if model.code { return model.location == .pc ? 0 : 1 }
            if model.location == .pc && matches(["qwen257b", "qwen25coder7b", "qwen38b"]) { return 0 }
            if model.location == .phone && matches(["minicpm51b"]) { return 2 }
            if model.location == .phone && matches(["qwen3508b"]) { return 3 }
            return nil
        case .long:
            if model.longContext { return model.location == .pc ? 0 : 1 }
            if model.location == .pc && matches(["gemma49b"]) { return 0 }
            if model.location == .phone && matches(["gemma4e2b"]) { return 1 }
            return nil
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
