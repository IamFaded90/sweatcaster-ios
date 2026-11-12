import SwiftUI

enum FadedTheme: String, CaseIterable, Identifiable {
    case faded = "Faded"
    case oled = "OLED Sort"
    case day = "Dag"

    var id: Self { self }
    var colorScheme: ColorScheme { self == .day ? .light : .dark }

    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard let domain = Bundle.main.bundleIdentifier,
              let saved = defaults.persistentDomain(forName: domain), saved[AppStorageKeys.appearanceTheme] == nil else { return }
        if saved[AppStorageKeys.appFollowSystemAppearance] as? Bool == false,
           saved[AppStorageKeys.appManualDarkMode] as? Bool == false {
            defaults.set(day.rawValue, forKey: AppStorageKeys.appearanceTheme)
        } else if saved[AppStorageKeys.spacesTheme] as? String == oled.rawValue {
            defaults.set(oled.rawValue, forKey: AppStorageKeys.appearanceTheme)
        }
    }
}

enum FadedAppearance: String, CaseIterable {
    case system = "Følg system"
    case dark = "Altid mørk"
    case light = "Altid lys"

    func preferredScheme(for theme: FadedTheme) -> ColorScheme? {
        switch self {
        case .system: theme == .faded ? nil : theme.colorScheme
        case .dark: .dark
        case .light: .light
        }
    }

    func resolve(theme: FadedTheme, system: ColorScheme) -> FadedTheme {
        if (preferredScheme(for: theme) ?? system) == .light { return .day }
        return theme == .oled ? .oled : .faded
    }
}

enum FadedColors {
    static let deep = Color(red: 13 / 255, green: 14 / 255, blue: 18 / 255)
    static let gradientEnd = Color(red: 18 / 255, green: 19 / 255, blue: 26 / 255)
    static let card = Color(red: 23 / 255, green: 24 / 255, blue: 31 / 255)
    static let raised = Color(red: 30 / 255, green: 31 / 255, blue: 41 / 255)
    static let border = Color(red: 42 / 255, green: 44 / 255, blue: 58 / 255)
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 237 / 255)
    static let secondary = Color(red: 168 / 255, green: 171 / 255, blue: 184 / 255)
    static let muted = Color(red: 107 / 255, green: 110 / 255, blue: 125 / 255)
    static let babyBlue = Color(red: 168 / 255, green: 216 / 255, blue: 255 / 255)
    static let lime = Color(red: 144 / 255, green: 213 / 255, blue: 255 / 255)
    static let cyan = Color(red: 63 / 255, green: 232 / 255, blue: 255 / 255)
    static let purple = Color(red: 183 / 255, green: 140 / 255, blue: 255 / 255)
    static let green = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let coral = Color(red: 255 / 255, green: 107 / 255, blue: 74 / 255)
    static let dayCard = Color.white
    static let dayRaised = Color(red: 232 / 255, green: 233 / 255, blue: 226 / 255)
    static let dayBorder = Color(red: 217 / 255, green: 217 / 255, blue: 210 / 255)
    static let daySecondary = Color(red: 70 / 255, green: 72 / 255, blue: 84 / 255)
    static let dayCoralText = Color(red: 154 / 255, green: 44 / 255, blue: 23 / 255)
    static let privateGlow = Color(red: 23 / 255, green: 18 / 255, blue: 31 / 255)
    static let sunset = Color(red: 26 / 255, green: 20 / 255, blue: 16 / 255)
    static let terminal = Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255)
    static let daylightWindow = Color(red: 242 / 255, green: 195 / 255, blue: 95 / 255)
    static let officeInk = Color(red: 26 / 255, green: 26 / 255, blue: 46 / 255)
    static let officePaper = Color(red: 255 / 255, green: 248 / 255, blue: 231 / 255)
    static let officeWorkers = [
        Color(red: 124 / 255, green: 108 / 255, blue: 242 / 255),
        Color(red: 233 / 255, green: 169 / 255, blue: 46 / 255),
        Color(red: 47 / 255, green: 185 / 255, blue: 138 / 255),
        Color(red: 224 / 255, green: 96 / 255, blue: 126 / 255),
        Color(red: 138 / 255, green: 143 / 255, blue: 152 / 255),
        Color(red: 61 / 255, green: 143 / 255, blue: 232 / 255),
        Color(red: 232 / 255, green: 132 / 255, blue: 58 / 255),
        Color(red: 47 / 255, green: 175 / 255, blue: 194 / 255)
    ]
}

struct FadedPalette {
    var theme: FadedTheme = .faded
    var isDark: Bool { theme != .day }
    var background: Color {
        switch theme {
        case .faded: FadedBrand.canvas
        case .oled: .black
        case .day: FadedColors.text
        }
    }
    var card: Color { theme == .faded ? FadedBrand.panel : isDark ? FadedColors.card : FadedColors.dayCard }
    var raised: Color { theme == .faded ? FadedBrand.raised : isDark ? FadedColors.raised : FadedColors.dayRaised }
    var border: Color { theme == .faded ? FadedBrand.border : isDark ? FadedColors.border : FadedColors.dayBorder }
    var text: Color { theme == .faded ? FadedBrand.text : isDark ? FadedColors.text : FadedColors.deep }
    var secondary: Color { theme == .faded ? FadedBrand.secondary : isDark ? FadedColors.secondary : FadedColors.daySecondary }
    var muted: Color { FadedColors.muted }
    var lime: Color { theme == .faded ? FadedBrand.mint : FadedColors.lime }
    var cyan: Color { theme == .faded ? FadedBrand.pc : FadedColors.cyan }
    var purple: Color { FadedColors.purple }
    var green: Color { theme == .faded ? FadedBrand.phone : FadedColors.green }
    var coral: Color { theme == .faded ? FadedBrand.destructive : FadedColors.coral }
    var coralText: Color { isDark ? coral : FadedColors.dayCoralText }
}

enum FadedBrand {
    static let canvas = Color(red: 8 / 255, green: 9 / 255, blue: 9 / 255)
    static let panel = Color(red: 21 / 255, green: 23 / 255, blue: 23 / 255)
    static let raised = Color(red: 34 / 255, green: 37 / 255, blue: 38 / 255)
    static let border = Color(red: 212 / 255, green: 240 / 255, blue: 236 / 255, opacity: 0.1)
    static let text = Color(red: 245 / 255, green: 247 / 255, blue: 247 / 255)
    static let secondary = Color(red: 160 / 255, green: 172 / 255, blue: 173 / 255)
    static let actionText = Color(red: 6 / 255, green: 28 / 255, blue: 36 / 255)
    static let mint = Color(red: 87 / 255, green: 242 / 255, blue: 204 / 255)
    static let blue = Color(red: 69 / 255, green: 150 / 255, blue: 251 / 255)
    static let phone = Color(red: 94 / 255, green: 231 / 255, blue: 139 / 255)
    static let pc = Color(red: 64 / 255, green: 224 / 255, blue: 255 / 255)
    static let destructive = Color(red: 255 / 255, green: 114 / 255, blue: 98 / 255)

    static let gradient = LinearGradient(colors: [mint, blue], startPoint: .leading, endPoint: .trailing)
}

private struct FadedPaletteKey: EnvironmentKey {
    static let defaultValue = FadedPalette()
}

extension EnvironmentValues {
    var fadedPalette: FadedPalette {
        get { self[FadedPaletteKey.self] }
        set { self[FadedPaletteKey.self] = newValue }
    }

    var fadedLookPreset: V0LookPreset? {
        get { self[FadedLookPresetKey.self] }
        set { self[FadedLookPresetKey.self] = newValue }
    }
}

private struct FadedLookPresetKey: EnvironmentKey {
    static let defaultValue: V0LookPreset? = nil
}

enum FadedSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let edge: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40
    static let huge: CGFloat = 48

    static let section = m
    static let action = l
}

enum FadedRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let card: CGFloat = 18
    static let hero: CGFloat = 22
    static let media = hero
    static let primary: CGFloat = 14
}

enum FadedTypography {
    static let title = Font.system(.title2).bold()
    static let section = Font.system(.headline).weight(.semibold)
    static let action = Font.system(.headline).weight(.semibold)
    static let body = Font.system(.body, design: .default)
    static let code = Font.system(.footnote, design: .monospaced)
    static let number = Font.system(.body, design: .monospaced).monospacedDigit()
}

struct FadedBackground: View {
    enum Variant: Equatable { case standard, privateChat, village, terminal }

    var variant: Variant = .standard
    @Environment(\.fadedPalette) private var palette
    @Environment(\.fadedLookPreset) private var lookPreset

    private var colors: [Color] {
        if !palette.isDark {
            return [palette.background, variant == .privateChat ? palette.purple.opacity(0.12) : palette.raised]
        }
        if palette.theme == .oled { return [palette.background, palette.background] }
        switch variant {
        case .standard: return [FadedBrand.canvas, FadedBrand.panel]
        case .privateChat: return [FadedColors.deep, FadedColors.privateGlow]
        case .village: return [FadedColors.sunset, FadedColors.deep]
        case .terminal: return [FadedColors.deep, FadedColors.terminal]
        }
    }

    var body: some View {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                if palette.theme == .faded && variant == .standard {
                    LinearGradient(colors: [FadedBrand.mint.opacity(0.05), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 240)
                }
            }
            .overlay { if palette.theme != .oled && variant != .standard { texture } }
            .overlay {
                if let lookPreset, palette.theme == .faded && variant == .standard {
                    lookPreset.background(in: palette)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var texture: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = variant == .terminal ? 24 : 12
            let columns = Int(size.width / step)
            let rows = Int(size.height / step)
            for row in 0...rows {
                for column in 0...columns {
                    let offset = CGFloat((row * 7 + column * 13) % 9)
                    let x = CGFloat(column) * step
                    let y = CGFloat(row) * step
                    if variant == .terminal {
                        path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
                    } else {
                        path.addRect(CGRect(x: x + offset, y: y + offset, width: 1, height: 1))
                    }
                }
            }
            context.fill(path, with: .color(palette.text.opacity(variant == .terminal ? 0.12 : 0.07)))
        }
    }
}
