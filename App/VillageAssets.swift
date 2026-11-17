import SwiftUI
import UIKit

enum VillageAssets {
    private static let images = NSCache<NSString, UIImage>()
    private static let sheets = NSCache<NSString, SpriteSheet>()
    private static let newFrames = NSCache<NSString, UIImage>()
    static func newArtName(name: String, id: String) -> String {
        VillageCharacterCatalog.resolved(name: name, id: id)
    }

    static func newBotFrame(_ bot: VillageLifeBot, at time: Date? = nil) -> UIImage? {
        let stable = newArtName(name: bot.displayName, id: bot.id)
        if let image = VillageProductionArt.frame(character: stable, direction: directionRow(for: bot),
                                                  step: bot.pose == .walk ? VillageProductionArt.step(at: time) : 0) {
            return image
        }
        let pose = bot.pose.rawValue
        let frame = time.map { Int($0.timeIntervalSinceReferenceDate * (pose == "walk" || pose == "work" || pose == "talk" ? 8 : 4)) % 8 } ?? 0
        let direction = directionRow(for: bot)
        let key = "\(stable)-\(pose)-\(direction)-\(frame)" as NSString
        if let cached = newFrames.object(forKey: key) { return cached }
        guard let sheet = image(named: "bot-\(stable)-\(pose)", subdirectory: "new")?.cgImage,
              let crop = sheet.cropping(to: CGRect(x: frame * 96, y: direction * 96, width: 96, height: 96)) else {
            return nil
        }
        let image = UIImage(cgImage: crop)
        newFrames.setObject(image, forKey: key, cost: 96 * 96 * 4)
        return image
    }

    static func directionRow(for bot: VillageLifeBot) -> Int {
        guard bot.pose == .walk, let destination = bot.destinationZoneID else { return 0 }
        let plaza = VillageMapLayout.plaza
        let from = bot.pathProgress < 0.5 ? VillageMapLayout.entrance(bot.zoneID) : plaza
        let to = bot.pathProgress < 0.5 ? plaza : VillageMapLayout.entrance(destination)
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard dx != 0 || dy != 0 else { return 0 }
        let clockwiseFromSouth = atan2(-Double(dx), Double(dy))
        let turns = clockwiseFromSouth / (2 * Double.pi)
        return (Int((turns * 16).rounded()) + 16) % 16
    }

    static func image(named name: String, subdirectory: String) -> UIImage? {
        let key = "\(subdirectory)/\(name)" as NSString
        if let image = images.object(forKey: key) { return image }
        if subdirectory == "new", name.hasPrefix("room-"),
           let image = VillageProductionArt.image(VillageProductionArt.room(for: String(name.dropFirst(5)))) {
            return image
        }
        let image = resource(named: name, fileExtension: "png", subdirectory: subdirectory)
            .flatMap { UIImage(contentsOfFile: $0.path) } ?? UIImage(named: name)
        if let image {
            images.totalCostLimit = 48 * 1024 * 1024
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            images.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    static func spriteSheet(named name: String) -> SpriteSheet? {
        let key = name as NSString
        if let sheet = sheets.object(forKey: key) { return sheet }
        let asset = "\(name)_spritesheet"
        guard
            let url = resource(named: asset, fileExtension: "json", subdirectory: "characters"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data),
            let image = image(named: asset, subdirectory: "characters")?.cgImage,
            manifest.fps > 0, manifest.fps <= 30,
            manifest.frameWidth > 0, manifest.frameHeight > 0
        else { return nil }

        var frames: [String: UIImage] = [:]
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        for frame in manifest.frames {
            let rect = CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y),
                              width: CGFloat(manifest.frameWidth), height: CGFloat(manifest.frameHeight))
            if bounds.contains(rect), let cropped = image.cropping(to: rect) {
                frames[frame.pose] = UIImage(cgImage: cropped)
            }
        }
        guard !frames.isEmpty else { return nil }
        let sheet = SpriteSheet(fps: Double(manifest.fps), frames: frames)
        sheets.setObject(sheet, forKey: key)
        return sheet
    }

    private static func resource(named name: String, fileExtension: String, subdirectory: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Village/\(subdirectory)")
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    final class SpriteSheet {
        let fps: Double
        private let frames: [String: UIImage]

        init(fps: Double, frames: [String: UIImage]) {
            self.fps = fps
            self.frames = frames
        }

        func image(for pose: VillageActivity, at time: Date? = nil) -> UIImage? {
            if pose == .walk {
                let step = floor((time?.timeIntervalSinceReferenceDate ?? 0) * fps)
                let name = step.truncatingRemainder(dividingBy: 2) == 0 ? "walk_1" : "walk_2"
                return frames[name] ?? frames["walk_1"] ?? frames["idle"]
            }
            return frames[pose.rawValue] ?? frames["idle"]
        }
    }

    private struct SpriteManifest: Decodable {
        let frameWidth: Int
        let frameHeight: Int
        let fps: Int
        let frames: [Frame]

        enum CodingKeys: String, CodingKey {
            case frameWidth = "frame_width"
            case frameHeight = "frame_height"
            case fps, frames
        }

        struct Frame: Decodable {
            let pose: String
            let x: Int
            let y: Int
        }
    }
}

struct VillagePixelImage: View {
    let name: String
    let folder: String
    var width: CGFloat?
    var height: CGFloat?

    var body: some View {
        Group {
            if let ui = VillageAssets.image(named: name, subdirectory: folder) {
                Image(uiImage: ui)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: width, height: height)
    }
}

@MainActor struct VillageBotSprite: View {
    let bot: VillageLifeBot
    var size: CGFloat = 48
    var animateWalk = false
    @ObservedObject private var speechMotion = VillageSpeechMotion.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    var body: some View {
        let moving = animateWalk && !reduceMotion && !calmMotion && phase == .active
        TimelineView(.animation(minimumInterval: bot.pose == .walk ? 1.0 / 12 : 1.0 / 8,
                                paused: !moving)) { context in
            let displayed = displayedBot(moving: moving)
            let date: Date? = moving ? context.date : nil
            let frame = date.map {
                Int($0.timeIntervalSinceReferenceDate * ([VillageActivity.walk, .work, .talk].contains(displayed.pose) ? 8 : 4)) % 8
            } ?? 0
            let art = VillageAssets.newArtName(name: displayed.displayName, id: displayed.id)
            if VillageProductionArt.hasCharacter(art) {
                VillageCharacterMotion(character: art, pose: displayed.pose,
                                       direction: VillageAssets.directionRow(for: displayed), date: date,
                                       mouth: moving ? speechMotion.mouth(for: bot.id, at: context.date) : 0)
            } else {
                let image = VillageAssets.newBotFrame(displayed, at: date)
                poseImage(image)
                    .overlay {
                        if image != nil {
                            VillageSpriteFace(artName: art, pose: displayed.pose, frame: frame,
                                              direction: VillageAssets.directionRow(for: displayed),
                                              blink: moving && VillageBlink.closed(id: bot.id, at: context.date),
                                              mouth: moving ? speechMotion.mouth(for: bot.id, at: context.date) : 0)
                        }
                    }
            }
            }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func displayedBot(moving: Bool) -> VillageLifeBot {
        var displayed = bot
        if speechMotion.isSpeaking(bot.id), moving, bot.pose != .walk { displayed.pose = .talk }
        return displayed
    }

    @ViewBuilder
    private func poseImage(_ image: UIImage?) -> some View {
        if let image = image ?? VillageAssets.image(named: "\(bot.spriteID)_idle", subdirectory: "characters")
            ?? VillageAssets.image(named: "adam_idle", subdirectory: "characters") {
            pixelArt(image)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
        }
    }

    private func pixelArt(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
    }
}
