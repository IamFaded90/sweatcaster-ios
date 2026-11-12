// Viser FadedAI-universet før parring og leder videre til lokal brug eller QR-login.

import SwiftUI

struct FadedLandingView: View {
    let openQRLogin: () -> Void
    let enterLocally: () -> Void
    let openChatLocally: (() -> Void)?
    let openCodeLocally: (() -> Void)?

    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 40.0

    init(
        openQRLogin: @escaping () -> Void,
        enterLocally: @escaping () -> Void,
        openChatLocally: (() -> Void)? = nil,
        openCodeLocally: (() -> Void)? = nil
    ) {
        self.openQRLogin = openQRLogin
        self.enterLocally = enterLocally
        self.openChatLocally = openChatLocally
        self.openCodeLocally = openCodeLocally
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                landingHeader
                    .padding(.horizontal, FadedSpacing.l)
                FadedWorldArtwork()
                landingCopy
                    .padding(.horizontal, FadedSpacing.l)
                if let openChatLocally, let openCodeLocally {
                    quickLinks(openChat: openChatLocally, openCode: openCodeLocally)
                        .padding(.horizontal, FadedSpacing.l)
                        .padding(.top, FadedSpacing.xl)
                }
            }
            .padding(.bottom, FadedSpacing.xxl)
            .frame(maxWidth: 448)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(FadedBackground())
    }

    private var landingHeader: some View {
        HStack(spacing: FadedSpacing.m) {
            HStack(spacing: 10) {
                Text("f.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                    .frame(width: 36, height: 36)
                    .background(palette.raised, in: .rect(cornerRadius: FadedRadius.medium))
                    .overlay { RoundedRectangle(cornerRadius: FadedRadius.medium).strokeBorder(palette.border) }
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Text("faded").fontWeight(.semibold).foregroundStyle(palette.text)
                    Text("ai").foregroundStyle(palette.secondary)
                }
                .font(.headline)
                .accessibilityLabel("FadedAI")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: FadedSpacing.s)

            Button(action: openQRLogin) {
                HStack(spacing: FadedSpacing.s) {
                    Image(systemName: "qrcode")
                        .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                        .accessibilityHidden(true)
                    Text("QR-login")
                        .foregroundStyle(palette.text)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, FadedSpacing.edge)
                .frame(minHeight: 44)
                .fadedGlassSurface()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Åbner sikker forbindelse til din PC")
        }
        .padding(.vertical, FadedSpacing.l)
    }

    private var landingCopy: some View {
        VStack(spacing: FadedSpacing.edge) {
            VStack(spacing: 0) {
                Text("Store idéer.")
                    .foregroundStyle(palette.text)
                Text("Dit lille univers.")
                    .foregroundStyle(LinearGradient(colors: palette.isDark ? [FadedBrand.mint, FadedBrand.blue] :
                                                        [palette.text, FadedBrand.actionText],
                                                    startPoint: .leading, endPoint: .trailing))
            }
            .font(.system(size: headlineSize, weight: .medium))
            .tracking(-2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text("Et sted at tænke, skabe og bygge.\nMed et AI-hold, der er helt dit eget.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: FadedSpacing.m) {
                Button(action: enterLocally) {
                    HStack(spacing: FadedSpacing.s) {
                        Text("Træd ind i din verden")
                        Spacer(minLength: FadedSpacing.s)
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FadedBrand.actionText)
                    .padding(.horizontal, FadedSpacing.l)
                    .padding(.vertical, FadedSpacing.s)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(FadedBrand.gradient,
                                in: RoundedRectangle(cornerRadius: FadedRadius.card))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Åbner FadedAI på telefonen. Du kan forbinde PC’en senere")

                Text("Du giver retningen. Vi giver idéerne plads.")
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, FadedSpacing.s)
        }
        .padding(.top, FadedSpacing.m)
    }

    private func quickLinks(openChat: @escaping () -> Void, openCode: @escaping () -> Void) -> some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: FadedSpacing.m)) :
            AnyLayout(HStackLayout(alignment: .top, spacing: FadedSpacing.m))
        return layout {
            quickLink("Bare en tanke?", detail: "Start en samtale", icon: "bubble.left", action: openChat)
            quickLink("Noget at bygge?", detail: "Mød din Code Bot", icon: "chevron.left.forwardslash.chevron.right",
                      action: openCode)
        }
    }

    private func quickLink(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: FadedSpacing.s) {
                Image(systemName: icon)
                    .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(palette.text)
                    Text(detail).font(.caption).foregroundStyle(palette.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(FadedSpacing.m)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(palette.card, in: .rect(cornerRadius: FadedRadius.card))
            .overlay { RoundedRectangle(cornerRadius: FadedRadius.card).strokeBorder(palette.border) }
        }
        .buttonStyle(.plain)
    }
}

struct FadedWorldArtwork: View {
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        Color.clear
            .aspectRatio(1.65, contentMode: .fit)
            .frame(maxHeight: 256)
            .overlay {
                GeometryReader { frame in
                    Image("V0AIWorld")
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.size.width, height: frame.size.height)
                        .clipped()
                        .mask { feather(.leading, .trailing, from: 0.18, through: 0.82) }
                        .mask { feather(.top, .bottom, from: 0.16, through: 0.77) }
                        .blendMode(palette.isDark ? .screen : .normal)
                }
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                Label("En verden af muligheder", systemImage: "sparkles")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                    .padding(.horizontal, FadedSpacing.m)
                    .padding(.vertical, 6)
                    .background(palette.card.opacity(0.92), in: Capsule())
                    .overlay { Capsule().strokeBorder(palette.border).allowsHitTesting(false) }
                    .padding(.horizontal, FadedSpacing.s)
                    .padding(.bottom, FadedSpacing.m)
            }
    }

    private func feather(_ start: UnitPoint, _ end: UnitPoint, from startOfArt: CGFloat, through endOfArt: CGFloat) -> some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: startOfArt),
            .init(color: .black, location: endOfArt),
            .init(color: .clear, location: 1)
        ], startPoint: start, endPoint: end)
    }
}
