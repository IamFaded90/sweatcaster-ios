import SwiftUI

struct PixelOfficeWorker: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case working, thinking, ready, offline

        var title: String {
            switch self {
            case .working: "Arbejder"
            case .thinking: "Tænker"
            case .ready: "Klar"
            case .offline: "Offline"
            }
        }

        var symbol: String {
            switch self {
            case .working: "bolt.fill"
            case .thinking: "ellipsis"
            case .ready: "checkmark"
            case .offline: "moon.fill"
            }
        }
    }

    let id: String
    let name: String
    let specialty: String
    let colorIndex: Int
    let status: Status
}

struct PixelOfficeView: View {
    let workers: [PixelOfficeWorker]
    let isVisible: Bool
    let onSelect: (PixelOfficeWorker) -> Void

    @Environment(\.fadedPalette) private var palette
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    private let canvasSize = CGSize(width: 320, height: 180)
    private let stationCount = 8
    private let stationSize = CGSize(width: 70, height: 61)

    private var animates: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !calmMotion && workers.prefix(stationCount).contains {
            $0.status == .working || $0.status == .thinking
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            officeScene
            if workers.isEmpty {
                FadedEmptyState(icon: "desktopcomputer", title: "Kontoret er tomt",
                                detail: "Opret en bot under Mine bots nedenfor, eller forbind til PC’en for at se dens agenter.")
            } else {
                FadedSectionHeader("På kontoret")
                if workers.count > stationCount {
                    Text("Kortet viser de første \(stationCount) bots. Hele holdet står herunder.")
                        .font(.footnote).foregroundStyle(palette.secondary)
                }
                ForEach(workers, content: workerRow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var officeScene: some View {
        if animates {
            TimelineView(.periodic(from: .now, by: 0.65)) { context in
                officeBoard(blink: Int(context.date.timeIntervalSinceReferenceDate / 0.65).isMultiple(of: 2))
            }
        } else {
            officeBoard(blink: false)
        }
    }

    private func officeBoard(blink: Bool) -> some View {
        GeometryReader { geometry in
            let deviceScale = max(1, displayScale)
            let availableWidth = geometry.size.width * deviceScale
            let availableHeight = geometry.size.height * deviceScale
            let pixelsPerPoint = max(1, floor(min(availableWidth / canvasSize.width, availableHeight / canvasSize.height)))
            let scale = pixelsPerPoint / deviceScale
            let width = canvasSize.width * scale
            let height = canvasSize.height * scale
            let x = floor(max(0, (availableWidth - width * deviceScale) / 2)) / deviceScale
            let y = floor(max(0, (availableHeight - height * deviceScale) / 2)) / deviceScale

            ZStack(alignment: .topLeading) {
                boardCanvas(scale: scale, blink: blink)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if stationSize.width * scale >= 44 && stationSize.height * scale >= 44 {
                    stationTargets(scale: scale)
                }
            }
            .frame(width: width, height: height)
            .offset(x: x, y: y)
        }
        .aspectRatio(canvasSize.width / canvasSize.height, contentMode: .fit)
        .background(palette.card, in: .rect(cornerRadius: FadedRadius.card))
    }

    private func boardCanvas(scale: CGFloat, blink: Bool) -> some View {
        Canvas { context, _ in
            let board = PixelOfficeDrawing(context: context, scale: scale)
            board.shell()
            for index in 0..<stationCount {
                let worker = index < workers.count ? workers[index] : nil
                board.station(at: stationOrigin(index), worker: worker, blink: blink)
            }
        }
    }

    private func stationOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: CGFloat(10 + (index % 4) * 76), y: CGFloat(34 + (index / 4) * 65))
    }

    private func stationTargets(scale: CGFloat) -> some View {
        ForEach(Array(workers.prefix(stationCount).enumerated()), id: \.offset) { index, worker in
            let point = stationOrigin(index)
            Button { onSelect(worker) } label: {
                Rectangle().fill(.clear)
                    .frame(width: stationSize.width * scale, height: stationSize.height * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: (point.x + stationSize.width / 2) * scale, y: (point.y + stationSize.height / 2) * scale)
            .accessibilityHidden(true)
        }
    }

    private func workerRow(_ worker: PixelOfficeWorker) -> some View {
        let accent = PixelOfficeDrawing.workerColor(worker.colorIndex)
        return Button { onSelect(worker) } label: {
            FadedCard(accent: accent) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: worker.status.symbol)
                        .font(.headline).foregroundStyle(FadedColors.officeInk)
                        .frame(width: 36, height: 36).background(accent, in: .rect(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(worker.name).font(FadedTypography.action).foregroundStyle(palette.text)
                        if !worker.specialty.isEmpty {
                            FadedDetailText(worker.specialty)
                        }
                        Text(worker.status.title).font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(palette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(palette.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }.buttonStyle(.plain)
    }
}

private struct PixelOfficeDrawing {
    let context: GraphicsContext
    let scale: CGFloat

    private let ink = FadedColors.officeInk
    private let paper = FadedColors.officePaper

    static func workerColor(_ index: Int) -> Color {
        let colors = FadedColors.officeWorkers
        guard !colors.isEmpty else { return FadedColors.cyan }
        let offset = (index % colors.count + colors.count) % colors.count
        return colors[offset]
    }

    func shell() {
        fill(0, 0, 320, 180, ink)
        fill(2, 2, 316, 176, paper)
        fill(5, 5, 310, 26, ink.opacity(0.09))
        fill(5, 31, 310, 2, ink)
        fill(5, 174, 310, 2, ink)
        for row in 0..<8 {
            for column in 0..<19 where (row + column).isMultiple(of: 2) {
                fill(8 + column * 16, 35 + row * 17, 16, 16, ink.opacity(0.035))
            }
        }
        window()
        fill(110, 9, 100, 18, ink.opacity(0.25))
        fill(107, 7, 100, 18, ink)
        label("KONTORET", x: 157, y: 16, color: paper, size: 8, anchor: .center)
        plant(x: 232, y: 12)
        cabinet(x: 259, y: 7)
    }

    private func window() {
        let sky = Self.workerColor(2)
        fill(13, 10, 72, 18, ink.opacity(0.22))
        fill(10, 7, 72, 18, ink)
        fill(12, 9, 68, 14, sky.opacity(0.6))
        fill(44, 9, 2, 14, ink)
        fill(12, 16, 68, 1, ink)
        fill(17, 12, 19, 1, paper)
        fill(50, 19, 12, 1, paper)
    }

    private func plant(x: Int, y: Int) {
        fill(x + 5, y + 8, 12, 9, ink.opacity(0.24))
        fill(x + 1, y + 8, 13, 8, ink)
        fill(x + 3, y + 10, 9, 4, Self.workerColor(0))
        fill(x + 6, y + 2, 3, 7, ink)
        fill(x + 2, y + 1, 5, 4, Self.workerColor(1))
        fill(x + 8, y, 6, 4, Self.workerColor(1))
    }

    private func cabinet(x: Int, y: Int) {
        fill(x + 3, y + 3, 43, 21, ink.opacity(0.22))
        fill(x, y, 43, 21, ink)
        fill(x + 2, y + 2, 39, 17, paper)
        fill(x + 3, y + 10, 37, 2, ink)
        for offset in [5, 10, 16, 23, 29, 34] {
            fill(x + offset, y + 4, 3, 6, Self.workerColor(offset))
        }
        fill(x + 10, y + 14, 23, 2, ink.opacity(0.32))
    }

    func station(at point: CGPoint, worker: PixelOfficeWorker?, blink: Bool) {
        let x = Int(point.x)
        let y = Int(point.y)
        let color = worker.map { Self.workerColor($0.colorIndex) } ?? paper
        fill(x + 6, y + 32, 60, 18, ink.opacity(0.23))
        fill(x + 2, y + 28, 60, 19, ink)
        fill(x + 4, y + 30, 56, 6, color)
        fill(x + 4, y + 38, 56, 5, paper)
        fill(x + 5, y + 43, 4, 9, ink)
        fill(x + 55, y + 43, 4, 9, ink)
        monitor(x: x + 7, y: y + 10, color: color, status: worker?.status, blink: blink)
        fill(x + 44, y + 24, 11, 6, ink)
        fill(x + 46, y + 25, 7, 4, paper)
        fill(x + 49, y + 23, 3, 3, ink)
        fill(x + 8, y + 32, 20, 2, ink.opacity(0.55))
        guard let worker else { return }
        let role = worker.specialty.isEmpty ? worker.name : worker.specialty
        label(String(role.prefix(11)).uppercased(), x: x + 2, y: y + 5, color: ink, size: 6, anchor: .leading)
        avatar(x: x + 39, y: y + 34, color: color, status: worker.status, blink: blink)
    }

    private func monitor(x: Int, y: Int, color: Color, status: PixelOfficeWorker.Status?, blink: Bool) {
        fill(x + 2, y + 3, 29, 17, ink.opacity(0.18))
        fill(x, y, 29, 17, ink)
        fill(x + 2, y + 2, 25, 13, color.opacity(status == .offline || status == nil ? 0.16 : 0.42))
        fill(x + 12, y + 17, 5, 3, ink)
        fill(x + 8, y + 20, 13, 2, ink)
        if status == .working || status == .thinking {
            fill(x + 5, y + 5, 12, 1, paper)
            fill(x + 5, y + 8, blink ? 17 : 9, 1, color)
            fill(x + 5, y + 11, 8, 1, paper)
        } else if status == .ready {
            fill(x + 5, y + 6, 7, 2, color)
        }
    }

    private func avatar(x: Int, y: Int, color: Color, status: PixelOfficeWorker.Status, blink: Bool) {
        fill(x + 3, y + 22, 20, 4, ink.opacity(0.28))
        fill(x + 4, y + 12, 14, 11, ink)
        fill(x + 6, y + 14, 10, 7, color)
        fill(x + 5, y + 22, 5, 3, ink)
        fill(x + 13, y + 22, 5, 3, ink)
        fill(x + 1, y + 1, 20, 14, ink)
        fill(x + 3, y + 3, 16, 10, color)
        fill(x + 5, y + 5, 12, 5, ink)
        let closed = status == .offline || (status == .thinking && blink)
        fill(x + 7, y + 6, 2, closed ? 1 : 3, paper)
        fill(x + 13, y + 6, 2, closed ? 1 : 3, paper)
        if status == .thinking {
            fill(x + 19, y - 5, 9, 5, ink)
            for offset in [1, 4, 7] { fill(x + 19 + offset, y - 3, 1, 1, paper) }
        }
    }

    private func fill(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale,
                          width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        context.fill(Path(rect), with: .color(color))
    }

    private func label(_ title: String, x: Int, y: Int, color: Color, size: CGFloat, anchor: UnitPoint) {
        let text = Text(verbatim: title).font(.system(size: size * scale, weight: .bold, design: .monospaced))
            .foregroundColor(color)
        context.draw(context.resolve(text), at: CGPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale), anchor: anchor)
    }
}
