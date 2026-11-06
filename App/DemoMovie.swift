import AVFoundation
import CoreVideo
import UIKit

enum DemoMovie {
    // A silent title card, visibly marked even when shared outside the app.
    static func make() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Demo-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = 360, height = 640
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        var success = false
        defer {
            if !success {
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard writer.canAdd(input) else { throw APIError.storage }
        writer.add(input)
        guard writer.startWriting() else { throw APIError.storage }
        writer.startSession(atSourceTime: .zero)
        var frame: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &frame) == kCVReturnSuccess,
              let frame else { throw APIError.storage }
        try await draw(frame, width: width, height: height)
        for index in 0..<48 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waits < 200 else { throw APIError.storage }
                try await Task.sleep(for: .milliseconds(10))
                waits += 1
            }
            try Task.checkCancellation()
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24))
            else { throw APIError.storage }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw APIError.storage }
        success = true
        return url
    }

    @MainActor private static func draw(_ frame: CVPixelBuffer, width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(frame), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                        CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw APIError.storage }
        context.setFillColor(UIColor(red: 0.04, green: 0.10, blue: 0.20, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        for (label, size, y) in [("DEMO", 58.0, 252.0), ("Kun en testvideo", 23.0, 330.0)] {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: CGFloat(size)), .foregroundColor: UIColor.white
            ]
            let string = label as NSString
            let textWidth = string.size(withAttributes: attributes).width
            string.draw(at: CGPoint(x: (CGFloat(width) - textWidth) / 2, y: CGFloat(y)), withAttributes: attributes)
        }
    }
}
