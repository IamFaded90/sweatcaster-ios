import SwiftUI

/// The host dock and the film screens share this exact canvas and theme choice.
public struct FilmBackground: View {
    @AppStorage(FilmAppearance.storageKey) private var appearance = FilmAppearance.followApp.rawValue
    @Environment(\.colorScheme) private var appScheme

    public init() { }

    public var body: some View {
        ZStack {
            Style.canvas
            BlueGlassSmoke()
        }
            .environment(\.colorScheme, FilmAppearance(storedValue: appearance).colorScheme(following: appScheme))
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Shared static artwork for Film and the host app. No animation or image download.
public struct BlueGlassSmoke: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() { }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let light = scheme == .light
            ZStack {
                RadialGradient(colors: [Color(red: 0.22, green: 0.46, blue: 0.75).opacity(light ? 0.10 : 0.28), .clear],
                               center: .topTrailing, startRadius: 0,
                               endRadius: max(size.width, size.height) * 0.8)
                if !reduceTransparency {
                    Canvas { context, canvas in
                        let frost = Color(red: 0.60, green: 0.78, blue: 0.96)
                        for index in 0..<3 {
                            let y = canvas.height * (0.22 + CGFloat(index) * 0.30)
                            var smoke = Path()
                            smoke.move(to: CGPoint(x: -canvas.width * 0.15, y: y + 110))
                            smoke.addCurve(to: CGPoint(x: canvas.width * 1.15, y: y - 100),
                                           control1: CGPoint(x: canvas.width * 0.34, y: y - 170),
                                           control2: CGPoint(x: canvas.width * 0.65, y: y + 140))
                            context.drawLayer { layer in
                                layer.addFilter(.blur(radius: 30))
                                layer.stroke(smoke, with: .color(frost.opacity(light ? 0.12 : 0.14)),
                                             lineWidth: 65)
                            }
                            context.drawLayer { layer in
                                layer.addFilter(.blur(radius: 12))
                                layer.stroke(smoke, with: .color(frost.opacity(light ? 0.08 : 0.10)),
                                             lineWidth: 18)
                            }
                        }
                    }
                    LinearGradient(colors: [.white.opacity(light ? 0.10 : 0.025), .clear, .blue.opacity(0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }.clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension FilmAppearance {
    func colorScheme(following appScheme: ColorScheme) -> ColorScheme {
        usesDarkAppearance(appIsDark: appScheme == .dark) ? .dark : .light
    }
}
