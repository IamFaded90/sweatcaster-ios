import AVFoundation
import ImageIO
import SwiftUI
import UIKit
import Vision

enum CameraGuideImage {
    static func normalize(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = info[kCGImagePropertyPixelWidth as String] as? Int,
              let h = info[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0, w <= 16_000, h <= 16_000, Int64(w) * Int64(h) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_280
              ] as CFDictionary),
              let bytes = UIImage(cgImage: image).jpegData(compressionQuality: 0.85), bytes.count <= 2_000_000 else { throw CameraGuide.Failure.response }
        return bytes
    }
    static func anchors(_ data: Data) async throws -> [CameraGuide.Anchor] {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(data: data, options: [:]).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).prefix(80).compactMap { observation -> CameraGuide.Anchor? in
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
                      candidate.string.count <= 150 else { return nil }
                let b = observation.boundingBox
                guard let box = try? CameraGuide.Box.vision(x: b.minX, y: b.minY, width: b.width, height: b.height) else { return nil }
                return .init(text: candidate.string, box: box)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    @MainActor static func render(_ image: UIImage, marks: [CameraGuide.Mark]) -> UIImage {
        let size = image.size
        return UIGraphicsImageRenderer(size: size).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            for (i, mark) in marks.enumerated() {
                let b = mark.box
                let rect = CGRect(x: b.x * size.width, y: b.y * size.height, width: b.width * size.width, height: b.height * size.height)
                UIColor.systemCyan.setStroke()
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 8); path.lineWidth = max(3, size.width / 180); path.stroke()
                let badge = CGRect(x: max(0, min(rect.minX, size.width - 40)), y: max(0, rect.minY - 36), width: 36, height: 32)
                UIColor.black.withAlphaComponent(0.8).setFill(); UIBezierPath(roundedRect: badge, cornerRadius: 8).fill()
                ("\(i + 1)" as NSString).draw(in: badge.insetBy(dx: 10, dy: 3), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.white])
            }
        }
    }
}

struct CameraGuideCapture: UIViewControllerRepresentable {
    let captured: (Data) -> Void
    let failed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera
        picker.cameraCaptureMode = .photo; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraGuideCapture
        init(parent: CameraGuideCapture) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let photo = info[.originalImage] as? UIImage, let bytes = photo.jpegData(compressionQuality: 0.9) { parent.captured(bytes) }
            else { parent.failed("Fotoet kunne ikke åbnes.") }
            parent.dismiss()
        }
    }
}

struct CameraGuideOverlay: View {
    let image: UIImage
    let marks: [CameraGuide.Mark]
    var correcting: Int?
    var moved: (Int, Double, Double) -> Void = { _, _, _ in }
    var body: some View {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ForEach(Array(marks.enumerated()), id: \.element.id) { i, mark in
                        let b = mark.box
                        RoundedRectangle(cornerRadius: 8).stroke(.cyan, lineWidth: 3)
                            .frame(width: b.width * proxy.size.width, height: b.height * proxy.size.height)
                            .overlay(alignment: .topLeading) {
                                Text("\(i + 1)").font(.caption.bold()).padding(5).background(.black.opacity(0.8), in: Circle()).foregroundStyle(.white)
                            }
                            .position(x: (b.x + b.width / 2) * proxy.size.width, y: (b.y + b.height / 2) * proxy.size.height)
                            .accessibilityLabel("Markering \(i + 1): \(mark.label). \(mark.originTitle)")
                    }
                    if let correcting {
                        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                            moved(correcting, value.location.x / proxy.size.width, value.location.y / proxy.size.height)
                        })
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 18))
    }
}
