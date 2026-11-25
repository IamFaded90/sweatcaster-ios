import SwiftUI

struct FadedDashboardHero: View {
    let openAssistant: () -> Void
    let openVillage: () -> Void
    let openEvening: () -> Void
    let openContinue: () -> Void
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "Godmorgen"
        case 11..<17: "Hej igen"
        case 17..<23: "God aften"
        default: "Din stille stund"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(Date.now.formatted(.dateTime.weekday(.wide).day().month()), systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                Spacer()
                Text("FADED").font(.caption2.monospaced().bold()).tracking(3).foregroundStyle(FadedBrand.mint)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(greeting).font(.largeTitle.bold())
                    Text("Dit sted.\nDine muligheder.").font(.title2.weight(.semibold)).foregroundStyle(FadedBrand.gradient)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize { FadedWorldArtwork().frame(width: 132, height: 150).accessibilityHidden(true) }
            }
            Text("En god film, din næste idé eller hjælp til det praktiske. Hvad har du lyst til?")
                .font(.subheadline).foregroundStyle(palette.secondary)
            FadedPrimaryButton("Gør min aften god", icon: "moon.stars", action: openEvening)
            FadedSecondaryButton("Spørg eller få noget gjort", icon: "sparkle.magnifyingglass", action: openAssistant)
            ViewThatFits(in: .horizontal) {
                HStack { small("Fortsæt", icon: "play.circle", action: openContinue); small("Besøg landsbyen", icon: "house.lodge", action: openVillage) }
                VStack { small("Fortsæt", icon: "play.circle", action: openContinue); small("Besøg landsbyen", icon: "house.lodge", action: openVillage) }
            }
        }.padding(22).foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: FadedRadius.hero)
                    .fill(LinearGradient(colors: [FadedBrand.mint.opacity(palette.isDark ? 0.16 : 0.08), FadedBrand.blue.opacity(0.10), FadedColors.purple.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .fadedGlassSurface(radius: FadedRadius.hero)
            .shadow(color: FadedBrand.mint.opacity(0.07), radius: 22, y: 7)
    }
    private func small(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }
            .buttonStyle(.bordered)
    }
}
