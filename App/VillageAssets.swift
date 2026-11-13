import SwiftUI
import UIKit

enum VillageAssets {
    private static let images = NSCache<NSString, UIImage>()
    private static let sheets = NSCache<NSString, SpriteSheet>()

    static func image(named name: String, subdirectory: String) -> UIImage? {
        let key = "\(subdirectory)/\(name)" as NSString
        if let image = images.object(forKey: key) { return image }
        let image = resource(named: name, fileExtension: "png", subdirectory: subdirectory)
            .flatMap { UIImage(contentsOfFile: $0.path) } ?? UIImage(named: name)
        if let image { images.setObject(image, forKey: key) }
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

struct VillageBotSprite: View {
    let bot: VillageLifeBot
    var size: CGFloat = 48
    var animateWalk = false

    var body: some View {
        Group {
            if let data = bot.customSprite, let image = UIImage(data: data) {
                pixelArt(image)
            } else if let sheet = VillageAssets.spriteSheet(named: bot.spriteID) {
                if bot.pose == .walk && animateWalk {
                    TimelineView(.animation(minimumInterval: 1 / sheet.fps)) { context in
                        poseImage(sheet.image(for: bot.pose, at: context.date))
                    }
                } else {
                    poseImage(sheet.image(for: bot.pose))
                }
            } else {
                poseImage(nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
