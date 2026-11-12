// Viser FadedAI-universet før parring og leder videre til lokal brug eller QR-login.

import SwiftUI

struct FadedLandingView: View {
    let openQRLogin: () -> Void
    let enterLocally: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 36.0

    private static let lightMint = Color(red: 0.83, green: 1, blue: 0.93)
    private static let charcoal = Color(red: 0.17, green: 0.17, blue: 0.18)

    private var landingGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: Self.lightMint, location: 0),
            .init(color: FadedBrand.mint, location: 0.46),
            .init(color: FadedBrand.blue, location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                landingHeader
                    .padding(.horizontal, FadedSpacing.l)
                worldArtwork
                    .padding(.top, FadedSpacing.xl)
                landingCopy
                    .padding(.horizontal, FadedSpacing.l)
            }
            .padding(.top, FadedSpacing.s)
            .padding(.bottom, FadedSpacing.xxl)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background {
            LinearGradient(colors: [Self.charcoal, FadedBrand.panel, FadedBrand.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
    }

    private var landingHeader: some View {
        HStack(spacing: FadedSpacing.m) {
            HStack(spacing: FadedSpacing.m) {
                Text("f.")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(FadedBrand.actionText)
                    .frame(width: 32, height: 32)
                    .background(landingGradient, in: Circle())
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Text("Faded").foregroundStyle(.white)
                    Text("AI").foregroundStyle(FadedBrand.mint)
                }
                .font(.title3.weight(.semibold))
                .accessibilityLabel("FadedAI")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: FadedSpacing.s)

            Button(action: openQRLogin) {
                HStack(spacing: FadedSpacing.s) {
                    Image(systemName: "qrcode")
                        .foregroundStyle(FadedBrand.mint)
                        .accessibilityHidden(true)
                    Text("QR-login")
                        .foregroundStyle(.white)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, FadedSpacing.m)
                .padding(.vertical, FadedSpacing.s)
                .background(FadedBrand.canvas.opacity(0.72), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Åbner sikker forbindelse til din PC")
        }
    }

    private var worldArtwork: some View {
        GeometryReader { geometry in
            Image("V0AIWorld")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.79),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.07),
                        .init(color: .black, location: 0.93),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
                .accessibilityLabel("FadedAI-univers med bots og deres arbejdssteder")
        }
        .aspectRatio(1.72, contentMode: .fit)
    }

    private var landingCopy: some View {
        VStack(spacing: FadedSpacing.edge) {
            Label("DIT HELT EGET AI-UNIVERS", systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(FadedBrand.mint)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                Text("En lille verden.")
                    .foregroundStyle(.white)
                Text("Du er skaberen.")
                    .foregroundStyle(landingGradient)
            }
            .font(.system(size: headlineSize, weight: .semibold))
            .tracking(-1.4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text("Dine AI’er har hver deres rolle.\nDu giver dem retning. Og plads til at vokse.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.63))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: FadedSpacing.edge) {
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
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(landingGradient,
                                in: RoundedRectangle(cornerRadius: FadedRadius.medium))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Åbner FadedAI på telefonen. Du kan forbinde PC’en senere")

                Text("Udforsk designet · Ingen tilsluttet PC endnu")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, FadedSpacing.s)
        }
        .padding(.top, FadedSpacing.m)
    }
}
