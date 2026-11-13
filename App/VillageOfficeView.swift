import SwiftUI

struct VillageOfficeView: View {
    let bots: [VillageLifeBot]
    var onSelect: (VillageLifeBot) -> Void

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
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                VillagePixelImage(name: "office_background", folder: "office")
                    .frame(maxWidth: .infinity)
                    .clipped()

                // Scale office art into view; draw furniture in 320×180 logical space
                GeometryReader { geo in
                    let scale = min(geo.size.width / 320, geo.size.height / 180)
                    let offsetX = (geo.size.width - 320 * scale) / 2
                    let offsetY = (geo.size.height - 180 * scale) / 2
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(deskPositions.enumerated()), id: \.offset) { index, desk in
                            station(at: desk, bot: bots.indices.contains(index) ? bots[index] : nil)
                                .position(x: offsetX + desk.x * scale, y: offsetY + desk.y * scale)
                                .scaleEffect(scale, anchor: .center)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))

            Text("Arbejdsstationer")
                .font(.headline)
            Text("Op til otte pladser. Tryk på en bot for at åbne dens computer.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(bots) { bot in
                    Button { onSelect(bot) } label: {
                        HStack(spacing: 10) {
                            VillagePixelImage(name: "\(bot.spriteID)_idle", folder: "characters", width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.displayName).font(.subheadline.bold()).lineLimit(1)
                                Text(bot.poseLabel + " · " + bot.zoneID.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bot.displayName), \(bot.poseLabel)")
                }
            }
        }
    }

    @ViewBuilder
    private func station(at desk: CGPoint, bot: VillageLifeBot?) -> some View {
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
                Button { onSelect(bot) } label: {
                    VillagePixelImage(name: "\(bot.spriteID)_idle", folder: "characters", width: 28, height: 28)
                        .offset(y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bot.displayName)
            }
        }
        .frame(width: 56, height: 56)
    }
}
