/// Preserve saved theme choices while following FadedAI's appearance by default.
public enum FilmAppearance: String, CaseIterable, Sendable {
    case followApp = "System", light = "Lyst", dark = "Mørk"

    public static let storageKey = "castbrowser.appearance"

    public init(storedValue: String) {
        self = storedValue == "Lys" ? .light : Self(rawValue: storedValue) ?? .followApp
    }

    public var title: String {
        switch self {
        case .followApp: "Følg appen"
        case .light: "Lyst"
        case .dark: "Mørkt"
        }
    }

    public func usesDarkAppearance(appIsDark: Bool) -> Bool {
        switch self {
        case .followApp: appIsDark
        case .light: false
        case .dark: true
        }
    }
}
