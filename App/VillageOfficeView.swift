import SwiftUI

struct VillageOfficeView: View {
    let bots: [VillageLifeBot]
    var onOpenProfile: (VillageLifeBot) -> Void
    var onOpenComputer: (VillageLifeBot) -> Void

    @Environment(\.fadedPalette) private var palette
    @State private var chosenBot: VillageLifeBot?
    /// Run after the chooser sheet dismisses so parent sheets can present cleanly.
    @State private var pendingOpen: PendingOpen?

    private enum PendingOpen {
        case profile(VillageLifeBot)
        case computer(VillageLifeBot)
    }

    private let deskPositions: [CGPoint] = {
        var points: [CGPoint] = []
        for row in 0..<2 {
            for col in 0..<4 {
                points.append(CGPoint(x: 42 + CGFloat(col) * 76, y: 96 + CGFloat(row) * 46))
            }
        }
        return points
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    VillagePixelImage(name: "office_background", folder: "office")
                        .frame(maxWidth: .infinity)
                        .clipped()

                    GeometryReader { geo in
                        let scale = min(geo.size.width / 320, geo.size.height / 180)
                        let offsetX = (geo.size.width - 320 * scale) / 2
                        let offsetY = (geo.size.height - 180 * scale) / 2
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(deskPositions.enumerated()), id: \.offset) { index, desk in
                                station(bot: bots.indices.contains(index) ? bots[index] : nil)
                                    .position(x: offsetX + desk.x * scale, y: offsetY + desk.y * scale)
                                    .scaleEffect(scale, anchor: .center)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
                .accessibilityLabel("Kontoret")

                Text("Personlige computere")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Hver bot har sin egen plads. Tryk for at vælge profil eller computer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVStack(spacing: 10) {
                    ForEach(bots) { bot in
                        officeBotRow(bot)
                    }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Kontoret")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $chosenBot, onDismiss: runPendingOpen) { bot in
            botActionSheet(bot)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
        }
    }

    private func runPendingOpen() {
        guard let pending = pendingOpen else { return }
        pendingOpen = nil
        switch pending {
        case .profile(let bot): onOpenProfile(bot)
        case .computer(let bot): onOpenComputer(bot)
        }
    }

    private func officeBotRow(_ bot: VillageLifeBot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VillageBotSprite(bot: bot, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName).font(FadedTypography.section).lineLimit(1)
                    Text(bot.poseLabel + " · " + bot.zoneID.title)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                    if bot.pcJobRunning, let live = bot.pcLiveLabel {
                        Text(live).font(.caption2).foregroundStyle(FadedBrand.mint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    onOpenProfile(bot)
                } label: {
                    Label("Profil", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium)
                .accessibilityLabel("Åbn profil for \(bot.displayName)")

                Button {
                    onOpenComputer(bot)
                } label: {
                    Label("Computer", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium, tint: FadedBrand.mint.opacity(0.16),
                                   border: FadedBrand.mint.opacity(0.45))
                .accessibilityLabel("Åbn computer for \(bot.displayName)")
            }
        }
        .padding(12)
        .fadedGlassSurface(radius: FadedRadius.card)
        .accessibilityElement(children: .contain)
    }

    private func botActionSheet(_ bot: VillageLifeBot) -> some View {
        VStack(spacing: FadedSpacing.m) {
            VillageBotSprite(bot: bot, size: 56)
            Text(bot.displayName).font(FadedTypography.title)
            Text(bot.poseLabel)
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
            HStack(spacing: 10) {
                Button {
                    pendingOpen = .profile(bot)
                    chosenBot = nil
                } label: {
                    Label("Profil", systemImage: "person.crop.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium)

                Button {
                    pendingOpen = .computer(bot)
                    chosenBot = nil
                } label: {
                    Label("Computer", systemImage: "desktopcomputer")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium, tint: FadedBrand.mint.opacity(0.18),
                                   border: FadedBrand.mint.opacity(0.5))
            }
            Button("Annuller") { chosenBot = nil }
                .frame(minHeight: 44)
        }
        .padding(FadedSpacing.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { FadedBackground(variant: .village) }
    }

    @ViewBuilder
    private func station(bot: VillageLifeBot?) -> some View {
        ZStack {
            VillagePixelImage(name: "office_desk", folder: "office", width: 48, height: 32)
            VillagePixelImage(name: "office_chair", folder: "office", width: 24, height: 28)
                .offset(x: 2, y: 14)
            VillagePixelImage(name: "office_monitor", folder: "office", width: 28, height: 24)
                .offset(y: -12)
            if bot != nil {
                VillagePixelImage(name: "office_decor_mug", folder: "office", width: 10, height: 10)
                    .offset(x: 18, y: -2)
            }
            if let bot {
                Button { chosenBot = bot } label: {
                    VillageBotSprite(bot: bot, size: 28)
                        .offset(y: 4)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bot.displayName), vælg profil eller computer")
            }
        }
        .frame(width: 56, height: 56)
    }
}
