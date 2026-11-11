// Viser FadedAI-universet før parring og leder videre til lokal brug eller QR-login.

import SwiftUI

struct FadedLandingView: View {
    let openQRLogin: () -> Void
    let enterLocally: () -> Void

    @Environment(\.fadedPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                landingHeader
                worldArtwork
                landingCopy
            }
            .padding(.horizontal, FadedSpacing.edge)
            .padding(.top, FadedSpacing.s)
            .padding(.bottom, FadedSpacing.xxl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(FadedBackground().ignoresSafeArea())
    }

    private var landingHeader: some View {
        HStack(spacing: FadedSpacing.m) {
            HStack(spacing: FadedSpacing.m) {
                Text("f.")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(FadedColors.deep)
                    .frame(width: 44, height: 44)
                    .background(FadedBrand.gradient, in: Circle())
                    .accessibilityHidden(true)
                Text("FadedAI")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(palette.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: FadedSpacing.s)

            Button(action: openQRLogin) {
                Label("QR-login", systemImage: "qrcode.viewfinder")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, FadedSpacing.edge)
                    .frame(minHeight: 44)
                    .background(palette.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(palette.border, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Åbner sikker forbindelse til din PC")
        }
    }

    private var worldArtwork: some View {
        Image("V0AIWorld")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 500, minHeight: 250, maxHeight: 360)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, palette.background.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 78)
                    .accessibilityHidden(true)
            }
            .padding(.top, FadedSpacing.s)
            .accessibilityLabel("FadedAI-univers med bots og deres arbejdssteder")
    }

    private var landingCopy: some View {
        VStack(spacing: FadedSpacing.l) {
            Label("DIT HELT EGET AI-UNIVERS", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(FadedBrand.mint)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: FadedSpacing.xs) {
                Text("En lille verden.")
                    .foregroundStyle(palette.text)
                Text("Du er skaberen.")
                    .foregroundStyle(FadedBrand.gradient)
            }
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text("Dine AI’er har hver deres rolle.\nDu giver dem retning. Og plads til at vokse.")
                .font(.body)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: enterLocally) {
                HStack {
                    Text("Træd ind i din verden")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(FadedTypography.action)
                .foregroundStyle(FadedColors.deep)
                .padding(.horizontal, FadedSpacing.l)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(FadedBrand.gradient,
                            in: RoundedRectangle(cornerRadius: FadedRadius.medium))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Åbner FadedAI på telefonen. Du kan forbinde PC’en senere")

            Text("Udforsk på telefonen · Forbind PC’en, når du er klar")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, FadedSpacing.s)
        .padding(.top, -FadedSpacing.s)
    }
}
