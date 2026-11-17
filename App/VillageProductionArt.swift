import SwiftUI
import UIKit

/// Actual measured atlas rectangles, not an assumed grid copied from the trial manifest.
enum VillageProductionArt {
    struct Frame: Decodable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    struct Atlas: Decodable {
        let rows: [[Frame]]
        let maxHeight: Int
    }
    private static let atlas: [String: Atlas] = {
        guard let url = url("characters", fileExtension: "json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Atlas].self, from: data)) ?? [:]
    }()
    private static let sourceCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static let frameCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func url(_ name: String, fileExtension ext: String = "png") -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Village/final")
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "final")
    }

    static func image(_ name: String) -> UIImage? {
        if let cached = sourceCache.object(forKey: name as NSString) { return cached }
        guard let url = url(name), let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        sourceCache.setObject(image, forKey: name as NSString, cost: cost)
        return image
    }

    static func hasCharacter(_ name: String) -> Bool { atlas[name] != nil }

    static func step(at date: Date?) -> Int {
        guard let date else { return 0 }
        return Int(max(0, date.timeIntervalSinceReferenceDate) * 8) % 8
    }

    static func frame(character: String, direction: Int, step: Int) -> UIImage? {
        guard let sheet = atlas[character], !sheet.rows.isEmpty, sheet.maxHeight > 0 else { return nil }
        let row = Int((Double((direction % 16 + 16) % 16) / 16 * Double(sheet.rows.count)).rounded()) % sheet.rows.count
        let frames = sheet.rows[row]
        guard !frames.isEmpty else { return nil }
        let column = min(frames.count - 1, max(0, step % 8) * frames.count / 8)
        let key = "\(character):\(row):\(column)" as NSString
        if let cached = frameCache.object(forKey: key) { return cached }
        let rect = frames[column]
        guard let source = image("walk-" + character)?.cgImage,
              let crop = source.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let result = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { _ in
            let scale = 104.0 / CGFloat(sheet.maxHeight)
            let width = CGFloat(rect.width) * scale
            let height = CGFloat(rect.height) * scale
            UIImage(cgImage: crop).draw(in: CGRect(x: (128 - width) / 2, y: 114 - height, width: width, height: height))
        }
        frameCache.setObject(result, forKey: key, cost: 128 * 128 * 4)
        return result
    }

    static func room(for character: String) -> String {
        switch character {
        case "eva", "nova", "theo": "room-media-studio"
        case "luna", "saga": "room-sleeping-corner"
        case "milo", "noah": "room-cafe"
        case "adam", "iris": "room-research-lab"
        default: "personal-office"
        }
    }

    static func portrait(_ name: String, expression: Int = 0) -> UIImage? {
        let index = min(3, max(0, expression))
        let key = "portrait:\(name):\(index)" as NSString
        if let cached = frameCache.object(forKey: key) { return cached }
        guard let source = image("expressions-" + name)?.cgImage else { return image("portrait-" + name) }
        let width = source.width / 2
        let height = source.height / 2
        guard let cropped = source.cropping(to: CGRect(x: (index % 2) * width, y: (index / 2) * height,
                                                      width: width, height: height)) else { return nil }
        let result = UIImage(cgImage: cropped)
        frameCache.setObject(result, forKey: key, cost: cropped.bytesPerRow * cropped.height)
        return result
    }
}

struct VillageCharacterMotion: View {
    let character: String
    let pose: VillageActivity
    let direction: Int
    let date: Date?
    let mouth: Double

    var body: some View {
        let time = date?.timeIntervalSinceReferenceDate ?? 0
        let moving = date != nil
        let breathing = moving ? sin(time * (pose == .sleep ? 1.8 : 2.8)) : 0
        let tapping = moving && pose == .work ? sin(time * 13) : 0
        let sipping = moving && pose == .rest ? pow(max(0, sin(time * 1.2)), 8) : 0
        let nod = pose == .talk && moving ? mouth : 0
        let step = pose == .walk ? VillageProductionArt.step(at: date) : 0
        GeometryReader { geometry in
            ZStack {
                if pose == .sleep { bed(size: geometry.size) }
                if let image = VillageProductionArt.frame(character: character, direction: direction, step: step) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                        .scaleEffect(x: pose == .sleep ? 0.72 : 1,
                                     y: bodyHeight(breathing: breathing, sipping: sipping),
                                     anchor: pose == .sleep ? .center : UnitPoint(x: 0.5, y: 114.0 / 128))
                        .rotationEffect(.degrees(pose == .sleep ? -90 : tapping * 1.3 + nod * 3))
                        .offset(y: pose == .sleep ? geometry.size.height * 0.12 : 0)
                }
                activityDetail(size: geometry.size, tapping: tapping, sipping: sipping, breathing: breathing)
            }
        }
        .accessibilityHidden(true)
    }

    private func bed(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: 0.17, green: 0.30, blue: 0.33))
            .frame(width: size.width * 0.86, height: size.height * 0.34)
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.7)).frame(width: size.width * 0.18) }
            .offset(y: size.height * 0.15)
    }

    private func bodyHeight(breathing: Double, sipping: Double) -> CGFloat {
        switch pose {
        case .walk: return 1
        case .sleep: return 0.72 + CGFloat(breathing) * 0.018
        case .rest: return 0.9 + CGFloat(breathing) * 0.012 - CGFloat(sipping) * 0.025
        default: return 1 + CGFloat(breathing) * 0.014
        }
    }

    @ViewBuilder private func activityDetail(size: CGSize, tapping: Double, sipping: Double, breathing: Double) -> some View {
        if pose == .work {
            Image(systemName: "laptopcomputer")
                .font(.system(size: size.width * 0.29, weight: .bold))
                .foregroundStyle(.cyan).shadow(color: .black, radius: 1, y: 1)
                .offset(y: size.height * (0.12 + CGFloat(tapping) * 0.02))
        } else if pose == .talk || mouth > 0.2 {
            Image(systemName: mouth > 0.2 ? "waveform" : "bubble.left.fill")
                .font(.system(size: size.width * 0.18)).foregroundStyle(FadedBrand.mint)
                .scaleEffect(1 + CGFloat(mouth) * 0.25)
                .offset(x: size.width * 0.27, y: -size.height * 0.28)
        } else if pose == .sleep {
            Text("z").font(.system(size: size.width * 0.19, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .opacity(0.8 + breathing * 0.2)
                .offset(x: size.width * 0.24, y: size.height * (-0.16 - CGFloat(breathing) * 0.05))
        } else if pose == .rest {
            Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)
                .font(.system(size: size.width * 0.16))
                .rotationEffect(.degrees(-sipping * 25))
                .offset(x: size.width * (0.2 - CGFloat(sipping) * 0.13),
                        y: size.height * (0.2 - CGFloat(sipping) * 0.43))
        }
    }
}

@MainActor struct VillageInteriorArtwork: View {
    let name: String
    let label: String
    var residents: [VillageLifeBot] = []
    var animateResidents = false

    var body: some View {
        Group {
            if let image = VillageProductionArt.image(name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { roomFigures }
            } else {
                Image(systemName: "house")
                    .font(.largeTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { roomFigures }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fadedGlassSurface(radius: 18)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel(label)
    }

    @ViewBuilder private var roomFigures: some View {
        if !residents.isEmpty {
            GeometryReader { canvas in
                let size = min(54, canvas.size.width * 0.15, canvas.size.height * 0.24)
                ForEach(Array(residents.prefix(Self.spots.count).enumerated()), id: \.element.id) { index, bot in
                    let spot = Self.spots[index]
                    VillageBotSprite(bot: bot, size: size, animateWalk: animateResidents)
                        .shadow(color: .black.opacity(0.75), radius: 2, x: 1, y: 3)
                        .position(x: canvas.size.width * spot.x, y: canvas.size.height * spot.y)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // Positions are relative to the room illustration, independent of screen size.
    private static let spots: [CGPoint] = [
        .init(x: 0.45, y: 0.79), .init(x: 0.64, y: 0.79), .init(x: 0.25, y: 0.80),
        .init(x: 0.81, y: 0.80), .init(x: 0.10, y: 0.80), .init(x: 0.53, y: 0.53),
        .init(x: 0.72, y: 0.54), .init(x: 0.34, y: 0.55), .init(x: 0.88, y: 0.54),
        .init(x: 0.16, y: 0.55)
    ]
}
