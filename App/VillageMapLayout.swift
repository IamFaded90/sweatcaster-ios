import SwiftUI

/// Coordinates belong to the clean portrait artwork. Rendering and touch targets use the same transform.
enum VillageMapLayout {
    static let aspect: CGFloat = 1150.0 / 1367.0
    static let plaza = CGPoint(x: 0.50, y: 0.455)
    static let cemetery = CGPoint(x: 0.79, y: 0.77)
    static let creator = CGPoint(x: 0.50, y: 0.425)

    static func building(_ zone: VillageZoneID) -> CGPoint {
        switch zone {
        case .research: CGPoint(x: 0.50, y: 0.265)
        case .video: CGPoint(x: 0.835, y: 0.415)
        case .cafe: CGPoint(x: 0.18, y: 0.415)
        case .sleep: CGPoint(x: 0.505, y: 0.585)
        }
    }

    static func entrance(_ zone: VillageZoneID) -> CGPoint {
        switch zone {
        case .research: CGPoint(x: 0.50, y: 0.385)
        case .video: CGPoint(x: 0.68, y: 0.475)
        case .cafe: CGPoint(x: 0.32, y: 0.475)
        case .sleep: CGPoint(x: 0.35, y: 0.58)
        }
    }

    static func imageRect(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func point(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        let rect = imageRect(in: size)
        return CGPoint(x: rect.minX + normalized.x * rect.width, y: rect.minY + normalized.y * rect.height)
    }

    static func foot(for bot: VillageLifeBot, in size: CGSize) -> CGPoint {
        let from = entrance(bot.zoneID)
        guard let destination = bot.destinationZoneID else { return point(from, in: size) }
        let t = bot.pathProgress.isFinite ? min(1, max(0, bot.pathProgress)) : 0
        let start = t < 0.5 ? from : plaza
        let end = t < 0.5 ? plaza : entrance(destination)
        let progress = t < 0.5 ? t * 2 : (t - 0.5) * 2
        return point(CGPoint(x: start.x + (end.x - start.x) * progress,
                             y: start.y + (end.y - start.y) * progress), in: size)
    }
}

/// Reuse the original painted building pixels as a foreground, without another bitmap copy.
/// Footpaths stay outside these polygons; a sprite's head cannot paint over a roof behind it.
struct VillageMapForeground: View {
    let night: Bool
    private let outlines: [[CGPoint]] = [
        [.init(x: 0.362, y: 0.197), .init(x: 0.493, y: 0.145), .init(x: 0.640, y: 0.214),
         .init(x: 0.650, y: 0.316), .init(x: 0.499, y: 0.359), .init(x: 0.354, y: 0.298)],
        [.init(x: 0.045, y: 0.352), .init(x: 0.163, y: 0.304), .init(x: 0.315, y: 0.367),
         .init(x: 0.323, y: 0.465), .init(x: 0.175, y: 0.508), .init(x: 0.035, y: 0.452)],
        [.init(x: 0.713, y: 0.354), .init(x: 0.831, y: 0.306), .init(x: 0.969, y: 0.370),
         .init(x: 0.970, y: 0.462), .init(x: 0.830, y: 0.506), .init(x: 0.700, y: 0.445)],
        [.init(x: 0.379, y: 0.574), .init(x: 0.482, y: 0.480), .init(x: 0.540, y: 0.500),
         .init(x: 0.555, y: 0.490), .init(x: 0.646, y: 0.563), .init(x: 0.643, y: 0.658),
         .init(x: 0.510, y: 0.685), .init(x: 0.375, y: 0.623)]
    ]

    var body: some View {
        Canvas { context, size in
            guard let image = VillageProductionArt.image(night ? "map-night" : "map-day") else { return }
            var path = Path()
            for outline in outlines {
                guard let first = outline.first else { continue }
                path.move(to: VillageMapLayout.point(first, in: size))
                for point in outline.dropFirst() { path.addLine(to: VillageMapLayout.point(point, in: size)) }
                path.closeSubpath()
            }
            context.clip(to: path)
            context.draw(Image(uiImage: image), in: VillageMapLayout.imageRect(in: size))
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct VillageWindowLights: View {
    let night: Bool
    var body: some View {
        Canvas { context, size in
            guard night else { return }
            for zone in VillageZoneID.allCases {
                let center = VillageMapLayout.point(VillageMapLayout.building(zone), in: size)
                let rect = CGRect(x: center.x - 12, y: center.y, width: 24, height: 16)
                context.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [.yellow.opacity(0.14), .clear]), center: CGPoint(x: center.x, y: center.y + 8),
                    startRadius: 0, endRadius: 16))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
