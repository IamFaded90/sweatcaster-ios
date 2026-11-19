import Foundation

enum AgentTasteKind {
    case voice, figure, imageStyle

    var title: String {
        switch self {
        case .voice: "Find en stemme"
        case .figure: "Find en landsbyfigur"
        case .imageStyle: "Find en billedstil"
        }
    }
}

/// Keep the winner against one previously unseen challenger. A single candidate never wins by default.
struct AgentTasteRound {
    private(set) var pair: [String]
    private var remaining: ArraySlice<String>
    private(set) var favorite: String?
    private(set) var comparisons = 0

    init(_ candidates: [String] = []) {
        var seen = Set<String>()
        let distinct = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        pair = distinct.count >= 2 ? Array(distinct.prefix(2)) : []
        remaining = distinct.dropFirst(2)
    }

    mutating func choose(_ id: String) {
        guard pair.count == 2, pair.contains(id) else { return }
        favorite = id
        comparisons += 1
        guard let next = remaining.popFirst() else { pair = []; return }
        pair = comparisons.isMultiple(of: 2) ? [id, next] : [next, id]
    }
}

enum AgentImageTasteStyle: String, CaseIterable {
    case pixel, illustration, sculpture, puppet

    var title: String {
        switch self {
        case .pixel: "Pixelkunst"
        case .illustration: "Tegnet illustration"
        case .sculpture: "Malet lerfigur"
        case .puppet: "Filtdukke"
        }
    }

    var sampleAsset: String {
        switch self {
        case .pixel: "FadedChatPortraitPixel"
        case .illustration: "FadedChatPortraitIllustrated"
        case .sculpture: "FadedChatPortraitSculpture"
        case .puppet: "FadedChatPortraitPuppet"
        }
    }

    private var instruction: String {
        switch self {
        case .pixel: "Pixel art with crisp pixel edges and a limited palette."
        case .illustration: "Hand-drawn illustration with fine outlines and soft cel shading."
        case .sculpture: "Hand-painted clay sculpture with detailed surface texture."
        case .puppet: "Handmade felt puppet with soft fabric textures."
        }
    }

    static func key(for botID: UUID) -> String { "fadedai.agent.image-style.v1." + botID.uuidString.lowercased() }

    static func selected(for botID: UUID, defaults: UserDefaults = .standard) -> Self? {
        defaults.string(forKey: key(for: botID)).flatMap(Self.init(rawValue:))
    }

    func save(for botID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key(for: botID))
    }

    /// Preserve the entire user's description. The UI can offer to omit the style if it exceeds the API limit.
    func applying(to prompt: String) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : text + "\n" + instruction
    }
}
