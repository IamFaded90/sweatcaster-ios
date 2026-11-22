import AVFoundation
import ARKit
import CoreImage
import RoomPlan
import SwiftUI
import UIKit

@MainActor struct ScannedOfficeCapture: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let onSaved: (ScannedOfficeRoom) -> Void
    @State private var finish = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    FadedEmptyState(icon: "viewfinder", title: "Rummet kunne ikke gemmes", detail: failure,
                                    actionTitle: "Luk") { dismiss() }
                        .padding(FadedSpacing.edge)
                } else {
                    CaptureSurface(finish: finish, saved: { result in
                        do {
                            let (capture, photos) = try result.get()
                            let room = try ScannedOfficeStore.capture(capture, photos: photos)
                            onSaved(room)
                            dismiss()
                        } catch {
                            failure = "Prøv at scanne langsomt langs alle væggene i rummet."
                        }
                    })
                    .safeAreaInset(edge: .bottom) {
                        Group {
                            if finish { ProgressView("Gør rummet klar…") }
                            else {
                                VStack(spacing: 6) {
                                    Text("Vil du have et vægfoto, så træd tilbage, til hele væggen er synlig.")
                                        .font(.caption)
                                    FadedPrimaryButton("Gem scanningen", icon: "checkmark") { finish = true }
                                }
                            }
                        }
                        .padding(FadedSpacing.edge)
                        .fadedGlassSurface(radius: FadedRadius.card, tint: FadedBrand.panel)
                    }
                }
            }
            .navigationTitle("Scan mit værelse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuller") { dismiss() } } }
            .onChange(of: phase) { if phase == .background { dismiss() } }
            .privacySensitive()
        }
    }

    private struct CaptureSurface: UIViewRepresentable {
        typealias Scan = (CapturedRoom, [UUID: OfficeWallPhoto])
        let finish: Bool
        let saved: (Result<Scan, any Error>) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(saved: saved) }

        func makeUIView(context: Context) -> RoomCaptureView {
            let view = RoomCaptureView(frame: .zero)
            view.delegate = context.coordinator
            view.captureSession.run(configuration: RoomCaptureSession.Configuration())
            context.coordinator.startFrames(view)
            return view
        }

        func updateUIView(_ view: RoomCaptureView, context: Context) {
            if finish, !context.coordinator.finishing {
                context.coordinator.finishing = true
                context.coordinator.stopFrames()
                view.captureSession.stop(pauseARSession: true)
            }
        }

        static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
            coordinator.cancelled = true
            coordinator.stopFrames()
            coordinator.frames.clear()
            view.delegate = nil
            if !coordinator.finishing { view.captureSession.stop(pauseARSession: true) }
        }

        @objc(FadedOfficeRoomCaptureCoordinator)
        final class Coordinator: NSObject, RoomCaptureViewDelegate {
            let saved: (Result<Scan, any Error>) -> Void
            var finishing = false
            var cancelled = false
            private var delivered = false
            let frames = OfficeWallFrames()
            private weak var captureView: RoomCaptureView?
            private var timer: Timer?

            init(saved: @escaping (Result<Scan, any Error>) -> Void) { self.saved = saved }

            func startFrames(_ view: RoomCaptureView) {
                captureView = view
                timer = Timer.scheduledTimer(timeInterval: 0.9, target: self, selector: #selector(sampleFrame),
                                             userInfo: nil, repeats: true)
            }

            func stopFrames() { timer?.invalidate(); timer = nil }

            @MainActor @objc private func sampleFrame() {
                guard !finishing, !cancelled, let frame = captureView?.captureSession.arSession.currentFrame else { return }
                frames.record(frame)
            }

            // RoomCaptureViewDelegate inherits NSCoding. This delegate belongs to one
            // live SwiftUI capture and its callback cannot be restored from an archive.
            // Completed rooms are persisted separately by ScannedOfficeStore.
            required init?(coder: NSCoder) { return nil }

            func encode(with coder: NSCoder) {
                // No capture session, callback or room contents are archived here.
            }

            func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
                guard !cancelled else { return false }
                if let error {
                    deliver(.failure(error))
                    return false
                }
                return finishing
            }

            func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
                guard finishing else { return }
                if let error { deliver(.failure(error)) }
                else { deliver(.success((processedResult, frames.photographs(of: processedResult)))) }
            }

            private func deliver(_ result: Result<Scan, any Error>) {
                guard !cancelled, !delivered else { return }
                stopFrames()
                frames.clear()
                delivered = true
                saved(result)
            }
        }
    }
}

/// Keeps small native-orientation camera samples only while RoomPlan owns the AR session.
private final class OfficeWallFrames {
    struct Sample {
        let camera: simd_float4x4
        let focal, principal: SIMD2<Float>
        let bgra: [UInt8]
        let width, height: Int
        let depth: [Float]
        let features: [SIMD3<Float>]
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var samples: [Sample] = []
    private static let depthWidth = 64, depthHeight = 48

    func clear() { samples.removeAll() }

    private func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let position = simd_distance(a.columns.3, b.columns.3)
        let facing = max(0, 1 - simd_dot(a.columns.2, b.columns.2))
        return min(position, 6) + 4 * facing
    }

    func record(_ frame: ARFrame) {
        let camera = frame.camera
        guard case .normal = camera.trackingState else {
            if case .limited(.relocalizing) = camera.trackingState { clear() }
            return
        }
        let pose = camera.transform
        guard samples.allSatisfy({ distance($0.camera, pose) > 0.22 }) else { return }
        let source = CIImage(cvPixelBuffer: frame.capturedImage)
        let w = source.extent.width, h = source.extent.height
        guard w > 0, h > 0, camera.imageResolution == source.extent.size else { return }
        let scale = 512 / max(w, h)
        let size = SIMD2<Float>(Float(w), Float(h))
        let k = camera.intrinsics
        let focal = SIMD2(k.columns.0.x, k.columns.1.y) / size
        let principal = SIMD2(k.columns.2.x, k.columns.2.y) / size
        let depth = (frame.sceneDepth ?? frame.smoothedSceneDepth).flatMap(sampledDepth) ?? []
        var features: [SIMD3<Float>] = []
        if depth.isEmpty {
            guard let cloud = frame.rawFeaturePoints else { return }
            let inverse = simd_inverse(pose)
            let points = cloud.points
            for i in Swift.stride(from: 0, to: points.count, by: max(1, (points.count + 1023) / 1024)) {
                let p = inverse * SIMD4(points[i], 1)
                guard (0.15...5.5).contains(-p.z) else { continue }
                let uv = principal + SIMD2(p.x, -p.y) * focal / -p.z
                if (0..<1).contains(uv.x), (0..<1).contains(uv.y) { features.append(.init(uv.x, uv.y, -p.z)) }
            }
            guard features.count >= 24 else { return }
        }
        let width = max(1, Int((w * scale).rounded())), height = max(1, Int((h * scale).rounded()))
        var destination: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &destination) == kCVReturnSuccess,
              let pixels = destination else { return }
        context.render(source.transformed(by: .init(scaleX: CGFloat(width) / w, y: CGFloat(height) / h)), to: pixels)
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let memory = CVPixelBufferGetBaseAddress(pixels) else { return }
        var bgra = [UInt8]()
        bgra.reserveCapacity(width * height * 4)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            bgra.append(contentsOf: UnsafeBufferPointer(start: memory.advanced(by: y * stride)
                .assumingMemoryBound(to: UInt8.self), count: width * 4))
        }
        let sample = Sample(camera: pose, focal: focal, principal: principal,
                            bgra: bgra, width: width, height: height, depth: depth, features: features)
        if samples.count == 16 {
            // Replace the most redundant viewpoint only when the incoming view improves coverage.
            let nearest = samples.indices.map { i in
                samples.indices.filter { $0 != i }.map { distance(samples[i].camera, samples[$0].camera) }.min() ?? 0
            }
            guard let replace = nearest.indices.min(by: { nearest[$0] < nearest[$1] }),
                  samples.allSatisfy({ distance($0.camera, pose) > nearest[replace] }) else { return }
            samples.remove(at: replace)
        }
        samples.append(sample)
    }

    private func sampledDepth(_ data: ARDepthData) -> [Float]? {
        let map = data.depthMap, confidence = data.confidenceMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard width >= Self.depthWidth, height >= Self.depthHeight, let bytes = CVPixelBufferGetBaseAddress(map) else { return nil }
        if let confidence {
            guard CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height,
                  CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        var depth = [Float]()
        depth.reserveCapacity(Self.depthWidth * Self.depthHeight)
        for y in 0..<Self.depthHeight {
            let row = (2 * y + 1) * height / (2 * Self.depthHeight)
            let meters = bytes.advanced(by: row * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float32.self)
            let scores = confidence.flatMap { buffer in CVPixelBufferGetBaseAddress(buffer)?
                .advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self) }
            for x in 0..<Self.depthWidth {
                let col = (2 * x + 1) * width / (2 * Self.depthWidth)
                depth.append((scores?[col] ?? 1) > 0 ? meters[col] : 0)
            }
        }
        return depth
    }

    func photographs(of room: CapturedRoom) -> [UUID: OfficeWallPhoto] {
        var photos: [UUID: OfficeWallPhoto] = [:]
        for wall in room.walls.prefix(48) where photos.count < 16 {
            let width = wall.dimensions.x, height = wall.dimensions.y
            guard width.isFinite, height.isFinite, (0.04...60).contains(width), (0.04...12).contains(height),
                  wall.transform.columns.1.y > 0.97, abs(wall.transform.columns.0.y) < 0.05 else { continue }
            var best: (Float, Sample, OfficeWallProjection)?
            for sample in samples {
                let m = simd_inverse(sample.camera) * wall.transform
                func xyz(_ p: SIMD4<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, p.z) }
                let projection = OfficeWallProjection(center: xyz(m.columns.3), across: xyz(m.columns.0) * width,
                                        up: xyz(m.columns.1) * height, focal: sample.focal, principal: sample.principal)
                if let score = projection.quality(depth: sample.depth, columns: Self.depthWidth, rows: Self.depthHeight,
                                                  featurePoints: sample.features),
                   score > (best?.0 ?? 0) { best = (score, sample, projection) }
            }
            guard let (score, sample, projection) = best else { continue }
            let texels = score * Float(sample.width * sample.height)
            let ratio = width / height
            let targetWidth = max(1, min(512, Int(min((texels * ratio).squareRoot(), 512 * ratio))))
            let targetHeight = max(1, min(512, Int(Float(targetWidth) / ratio)))
            guard let bitmap = projection.rectifiedBGRA(source: sample.bgra, width: sample.width, height: sample.height,
                        targetWidth: targetWidth, targetHeight: targetHeight),
                  let provider = CGDataProvider(data: bitmap as CFData),
                  let image = CGImage(width: targetWidth, height: targetHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: targetWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.78), jpeg.count <= 120_000 else { continue }
            photos[wall.identifier] = OfficeWallPhoto(front: projection.front, jpeg: jpeg)
        }
        return photos
    }
}
