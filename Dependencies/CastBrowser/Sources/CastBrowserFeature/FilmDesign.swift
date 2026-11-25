import SwiftUI

/// The host dock and the film screens share this exact canvas and theme choice.
public struct FilmBackground: View {
    @AppStorage(FilmAppearance.storageKey) private var appearance = FilmAppearance.followApp.rawValue
    @Environment(\.colorScheme) private var appScheme

    public init() { }

    public var body: some View {
        Style.canvas
            .environment(\.colorScheme, FilmAppearance(storedValue: appearance).colorScheme(following: appScheme))
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension FilmAppearance {
    func colorScheme(following appScheme: ColorScheme) -> ColorScheme {
        usesDarkAppearance(appIsDark: appScheme == .dark) ? .dark : .light
    }
}
