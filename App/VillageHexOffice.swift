import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct VillageMapExport: Codable, Transferable {
    struct Bot: Codable {
        let id, name, zone, activity: String
        let destination: String?
        let progress, mood: Double
    }

    let version: Int
    let bots: [Bot]

    init(_ source: [VillageLifeBot]) {
        version = 1
        bots = source.filter { UUID(uuidString: $0.id) != VillageBot.lumiID }.prefix(10).map {
            Bot(id: $0.id, name: String($0.displayName.prefix(60)), zone: $0.zoneID.rawValue,
                activity: $0.poseLabel, destination: $0.destinationZoneID?.rawValue,
                progress: min(1, max(0, $0.pathProgress)), mood: min(1, max(0, $0.needs.mood)))
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { snapshot in try JSONEncoder().encode(snapshot) }
            .suggestedFileName("FadedAI-landsby.json")
    }
}

@MainActor struct VillageHexOffice: View {
    let bots: [VillageLifeBot]
    let openProfile: (VillageLifeBot) -> Void
    let openComputer: (VillageLifeBot) -> Void
    let openCemetery: () -> Void
    @Environment(\.fadedPalette) private var palette
    @State private var selected: Zone = .research

    private enum Zone: String, CaseIterable, Identifiable {
        case research, video, cafe, sleep, cemetery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .research: "Værksted"
            case .video: "Video"
            case .cafe: "Café"
            case .sleep: "Sovekrog"
            case .cemetery: "Kirkegård"
            }
        }
        var cell: Cell {
            switch self {
            case .research: Cell(q: 0, r: -2)
            case .video: Cell(q: 3, r: -1)
            case .cafe: Cell(q: -3, r: 0)
            case .sleep: Cell(q: -1, r: 2)
            case .cemetery: Cell(q: 2, r: 2)
            }
        }
    }

    private struct Cell {
        let q, r: Int
        func center(_ radius: CGFloat, in size: CGSize) -> CGPoint {
            CGPoint(x: size.width / 2 + radius * 1.732 * (CGFloat(q) + CGFloat(r) / 2),
                    y: size.height / 2 + radius * 1.5 * CGFloat(r))
        }
    }

    private static let botColors: [Color] = [.mint, .purple, .cyan, .yellow, .pink, .green, .orange, .blue]
    private var workers: [VillageLifeBot] { bots.filter { $0.zoneID.rawValue == selected.rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                map.aspectRatio(16 / 9, contentMode: .fit)
                FadedCard {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        FadedSectionLabel(selected.title)
                        if selected == .cemetery {
                            FadedSecondaryButton("Åbn Kirkegården", icon: "leaf", action: openCemetery)
                        } else {
                            if workers.isEmpty { FadedDetailText("Ingen bots i dette område lige nu.") }
                            ForEach(workers) { bot in
                                HStack {
                                    VillageBotSprite(bot: bot, size: 48, animateWalk: true)
                                    Text(bot.displayName).font(FadedTypography.action)
                                    Spacer()
                                    Menu(bot.poseLabel, systemImage: "ellipsis.circle") {
                                        Button("Åbn profil") { openProfile(bot) }
                                        Button("Åbn computer") { openComputer(bot) }
                                    }.frame(minHeight: 44)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ShareLink(item: VillageMapExport(bots), preview: SharePreview("FadedAI-landsby")) {
                    Label("Del landsbykort", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Kontorkort")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var map: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let radius = size.height / 10.5
            ZStack {
                Canvas { context, size in
                    let paper = Color(red: 0.89, green: 0.84, blue: 0.70)
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paper))
                    for r in -3...3 {
                        let offset = r / 2
                        for q in (-5 - offset)...(5 - offset) {
                            let cell = Cell(q: q, r: r)
                            let center = cell.center(radius, in: size)
                            let tile = hex(at: center, radius: radius - 1)
                            let shade = (q + r).isMultiple(of: 3) ? 0.08 : 0.16
                            context.fill(tile, with: .color(.brown.opacity(shade)))
                        }
                    }
                }
                .accessibilityHidden(true)
                ForEach(Zone.allCases) { zone in
                    let center = zone.cell.center(radius, in: size)
                    Button { selected = zone } label: {
                        VStack {
                            Text(zone.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            dots(for: zone)
                        }
                        .frame(width: 82, height: 52)
                        .foregroundStyle(.black)
                        .background {
                            RoundedRectangle(cornerRadius: FadedRadius.small)
                                .fill(selected == zone ? FadedBrand.mint : Color(white: 0.97))
                                .shadow(color: .black.opacity(0.65), radius: 0, x: 2, y: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(zone.title)
                    .accessibilityAddTraits(selected == zone ? .isSelected : [])
                    .position(center)
                }
            }
        }
        .clipShape(.rect(cornerRadius: FadedRadius.medium))
    }

    private func dots(for zone: Zone) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(bots.enumerated().filter { $0.element.zoneID.rawValue == zone.rawValue }.prefix(8)),
                    id: \.element.id) { index, _ in
                Circle().fill(Self.botColors[index % Self.botColors.count]).frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func hex(at center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            for side in 0..<6 {
                let angle = .pi / 6 + Double(side) * .pi / 3
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if side == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}
