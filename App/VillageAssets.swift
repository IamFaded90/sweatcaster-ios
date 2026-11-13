import SwiftUI
import UIKit

enum VillageAssets {
    static func image(named name: String, subdirectory: String) -> UIImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Village/\(subdirectory)"),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        // Fallback when folder is copied flat / during previews
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdirectory),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return UIImage(named: name)
    }

    static func pixelImage(_ name: String, folder: String) -> Image {
        if let ui = image(named: name, subdirectory: folder) {
            return Image(uiImage: ui).interpolation(.none)
        }
        return Image(systemName: "photo")
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
