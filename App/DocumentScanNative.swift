import CoreText
import Foundation
import PDFKit
import SwiftUI
import UIKit
import Vision
import VisionKit

enum DocumentScanNative {
    struct Line: Sendable { let text: String; let box: CGRect }
    struct Page: Sendable { let photo: Data; let lines: [Line] }
    struct Result: Sendable { let pdf: Data; let text: String; let pages: [Page]; let codes: [String] }
    static func prepare(_ photos: [Data]) async throws -> Result {
        guard (1...10).contains(photos.count) else { throw ScanDocument.Failure.full }
        let work = Task.detached(priority: .userInitiated) {
            var pages: [Page] = [], text = "", codes: [String] = []
            for (index, data) in photos.enumerated() {
                try Task.checkCancellation()
                let page = try autoreleasepool { () throws -> Page in
                    let bytes = try CameraGuideImage.normalize(data)
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
                    let qr = VNDetectBarcodesRequest(); qr.symbologies = [.qr]
                    try VNImageRequestHandler(data: bytes, options: [:]).perform([request, qr])
                    let lines = (request.results ?? []).prefix(240).compactMap { observation -> Line? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }; return .init(text: candidate.string, box: observation.boundingBox)
                    }
                    for code in (qr.results ?? []).compactMap(\.payloadStringValue) where code.utf8.count <= 4_096 && !codes.contains(code) && codes.count < 20 { codes.append(code) }
                    return .init(photo: bytes, lines: lines)
                }
                text += (text.isEmpty ? "" : "\n\n") + "Side \(index + 1)\n" + page.lines.map(\.text).joined(separator: "\n")
                guard text.unicodeScalars.count <= 24_000 else { throw ScanDocument.Failure.full }; pages.append(page)
            }
            try Task.checkCancellation()
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let pdf = renderer.pdfData { output in
                for page in pages {
                    guard let image = UIImage(data: page.photo), image.size.width > 0 else { continue }
                    let width: CGFloat = 612, height = min(1_200, max(100, 612 * image.size.height / image.size.width))
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    output.beginPage(withBounds: bounds, pageInfo: [:]); image.draw(in: bounds)
                    let context = output.cgContext
                    context.saveGState(); context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1); context.setTextDrawingMode(.invisible)
                    for line in page.lines {
                        let size = max(4, min(40, line.box.height * height * 0.85))
                        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                        let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                        let row = CTLineCreateWithAttributedString(attributed as CFAttributedString), length = CTLineGetTypographicBounds(row, nil, nil, nil)
                        context.saveGState(); context.translateBy(x: line.box.minX * width, y: line.box.minY * height)
                        context.scaleBy(x: min(1, line.box.width * width / CGFloat(max(1, length))), y: 1); context.textPosition = .zero
                        CTLineDraw(row, context); context.restoreGState()
                    }
                    context.restoreGState()
                }
            }
            guard pdf.count <= 24_000_000, let check = PDFDocument(data: pdf), check.pageCount == pages.count else { throw ScanDocument.Failure.format }
            // Check that OCR text really reached the PDF's searchable text layer.
            for (index, page) in pages.enumerated() where !page.lines.isEmpty {
                guard let expected = page.lines.first?.text, let extracted = check.page(at: index)?.string,
                      extracted.contains(expected) else { throw ScanDocument.Failure.format }
            }
            try Task.checkCancellation(); return Result(pdf: pdf, text: text, pages: pages, codes: codes)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

struct DocumentScanCamera: UIViewControllerRepresentable {
    let finished: (Result<[Data], Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { .init(self) }
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let owner: DocumentScanCamera
        init(_ owner: DocumentScanCamera) { self.owner = owner }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { owner.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { owner.finished(.failure(error)); owner.dismiss() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            do {
                guard (1...10).contains(scan.pageCount) else { throw ScanDocument.Failure.full }
                var photos: [Data] = []
                for index in 0..<scan.pageCount {
                    let data = try autoreleasepool { () throws -> Data in
                        guard let bytes = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.9) else { throw ScanDocument.Failure.format }
                        return try CameraGuideImage.normalize(bytes)
                    }; photos.append(data)
                }
                owner.finished(.success(photos))
            } catch { owner.finished(.failure(error)) }
            owner.dismiss()
        }
    }
}
