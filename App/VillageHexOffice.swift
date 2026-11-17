import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A bounded Conway board. One bit represents each tile on the 8 × 8 map.
struct VillageLifeBoard: Equatable, RawRepresentable {
    static let side = 8
    static let empty = Self(bits: 0)
    static let glider = Self(bits: [1, 10, 16, 17, 18].reduce(0) { $0 | mask($1) })

    private(set) var bits: UInt64
    private(set) var generation: Int

    init(bits: UInt64, generation: Int = 0) {
        self.bits = bits
        self.generation = generation
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let bits = UInt64(parts[0], radix: 16),
              let generation = Int(parts[1]), generation >= 0 else { return nil }
        self.init(bits: bits, generation: generation)
    }

    var rawValue: String { String(bits, radix: 16) + ":" + String(generation) }
    var population: Int { bits.nonzeroBitCount }

    func contains(_ index: Int) -> Bool {
        (0..<64).contains(index) && (bits & Self.mask(index)) != 0
    }

    mutating func toggle(_ index: Int) {
        guard (0..<64).contains(index) else { return }
        bits ^= Self.mask(index)
    }

    mutating func advance() {
        var next: UInt64 = 0
        for index in 0..<64 {
            let x = index % Self.side
            let y = index / Self.side
            var neighbors = 0
            for row in max(0, y - 1)...min(Self.side - 1, y + 1) {
                for column in max(0, x - 1)...min(Self.side - 1, x + 1) {
                    let neighbor = row * Self.side + column
                    if neighbor != index && contains(neighbor) { neighbors += 1 }
                }
            }
            if neighbors == 3 || (neighbors == 2 && contains(index)) { next |= Self.mask(index) }
        }
        bits = next
        if generation < Int.max { generation += 1 }
    }

    private static func mask(_ index: Int) -> UInt64 { UInt64(1) << index }
}

@MainActor struct VillageLifeGarden: View {
    @AppStorage("village.lifeGarden.board") private var board = VillageLifeBoard.glider
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.fadedPalette) private var palette
    @State private var running = false

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 1), spacing: 2), count: VillageLifeBoard.side)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedDetailText("Tryk på felterne for at plante liv. Se, hvordan mønstret vokser eller forsvinder efter hvert trin.")
                Text("Trin \(board.generation) · \(board.population) levende felter")
                    .font(.subheadline.monospacedDigit())
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<64, id: \.self) { index in
                        Button {
                            board.toggle(index)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(board.contains(index) ? palette.lime : palette.raised)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Række \(index / 8 + 1), felt \(index % 8 + 1)")
                        .accessibilityValue(board.contains(index) ? "Levende" : "Tomt")
                    }
                }
                .padding(6)
                .fadedGlassSurface(radius: FadedRadius.medium)
                FadedPrimaryButton(running ? "Pause" : "Start", icon: running ? "pause.fill" : "play.fill") {
                    running.toggle()
                }
                .disabled(board.population == 0 && !running)
                Button("Næste trin", systemImage: "forward.end") { board.advance() }
                    .frame(minHeight: 44)
                    .disabled(running || board.population == 0)
                Menu("Nyt mønster", systemImage: "square.grid.3x3") {
                    Button("Sæt et vandrende mønster") { reset(.glider) }
                    Button("Ryd felterne", role: .destructive) { reset(.empty) }
                }
                .frame(minHeight: 44)
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Livshaven")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: running && scenePhase == .active) {
            while running && scenePhase == .active && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(650)) }
                catch { return }
                guard !Task.isCancelled, running, scenePhase == .active else { return }
                board.advance()
                if board.population == 0 { running = false }
            }
        }
        .onDisappear { running = false }
    }

    private func reset(_ pattern: VillageLifeBoard) {
        running = false
        board = pattern
    }
}

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
                    Button { selected = zone } label: {
                        VStack(spacing: 1) {
                            Text(zone.title).font(.caption2.bold()).lineLimit(1)
                            dots(for: zone)
                        }
                        .padding(.horizontal, 3).frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(.black)
                        .background(selected == zone ? FadedBrand.mint : Color(white: 0.97),
                                    in: RoundedRectangle(cornerRadius: FadedRadius.small))
                        .shadow(color: .black.opacity(0.65), radius: 0, x: 2, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(zone.title)
                    .accessibilityAddTraits(selected == zone ? .isSelected : [])
                    .position(zone.cell.center(radius, in: size))
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
