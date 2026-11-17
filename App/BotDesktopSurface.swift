import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BotDesktopImage {
    let image: UIImage
    let width: Int
    let height: Int

    init?(_ source: BotComputerFrame) {
        guard let decoder = CGImageSourceCreateWithData(source.png as CFData, nil),
              let type = CGImageSourceGetType(decoder), type as String == UTType.png.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(decoder, 0, nil) as? [String: Any],
              let pixelWidth = (info[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let pixelHeight = (info[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else { return nil }
        guard (1...16_384).contains(pixelWidth), (1...16_384).contains(pixelHeight),
              pixelWidth * pixelHeight <= 16_777_216,
              let decoded = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { return nil }
        image = UIImage(cgImage: decoded)
        width = source.width ?? pixelWidth
        height = source.height ?? pixelHeight
    }
}

struct BotDesktopSurface: View {
    let frame: BotDesktopImage
    let takingControl: Bool
    let onInput: (BotComputerClient.Input) -> Void

    var body: some View {
        Image(uiImage: frame.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                if takingControl {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                                let x = Int(tap.location.x / geometry.size.width * CGFloat(frame.width))
                                let y = Int(tap.location.y / geometry.size.height * CGFloat(frame.height))
                                onInput(.click(x: min(frame.width - 1, max(0, x)), y: min(frame.height - 1, max(0, y))))
                            })
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FadedRadius.small))
            .privacySensitive()
            .accessibilityLabel("Seneste billede fra bottens skrivebord")
    }
}

@MainActor struct BotComputerFileView: View {
    let file: BotComputerFile
    let client: BotComputerClient
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let content {
                    Text(content).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(FadedSpacing.edge)
                } else if let failure {
                    Text(failure).padding(FadedSpacing.edge)
                } else {
                    ProgressView("Henter filen…").padding(FadedSpacing.edge)
                }
            }
            .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
        .task {
            do { content = try await client.file(file.id) }
            catch { if !Task.isCancelled { failure = BotComputerStore.message(for: error) } }
        }
    }
}
