import CoreImage
import ImageIO
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var busy = false
    private var lastFrame = 0.0
    private var configuration: PhoneBroadcastConfiguration?
    private var upload: URLSessionDataTask?
    private var failures = 0
    private lazy var session = URLSession(configuration: .ephemeral, delegate: RedirectBlock(), delegateQueue: nil)

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        configuration = PhoneBroadcastConfiguration.read()
        guard configuration != nil else {
            finishBroadcastWithError(NSError(domain: "FadedAI", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "Åbn skærmdeling hos din agent i FadedAI først."]))
            return
        }
    }

    override func broadcastFinished() {
        upload?.cancel()
        if let configuration {
            var request = URLRequest(url: configuration.endpoint.deletingLastPathComponent().appendingPathComponent("finish"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpMethod = "PUT"
            request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
            session.dataTask(with: request).resume()
        }
        session.finishTasksAndInvalidate()
        if PhoneBroadcastConfiguration.read()?.id == configuration?.id { PhoneBroadcastConfiguration.clear() }
        configuration = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !busy, now - lastFrame >= 2 else { lock.unlock(); return }
        busy = true
        lastFrame = now
        lock.unlock()
        guard let configuration, let active = PhoneBroadcastConfiguration.read(), active.id == configuration.id else {
            releaseFrame()
            finishBroadcastWithError(NSError(domain: "FadedAI", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "Skærmdelingen er afsluttet."]))
            return
        }
        guard !active.paused else { releaseFrame(); return }
        autoreleasepool {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { releaseFrame(); return }
            var image = CIImage(cvPixelBuffer: buffer)
            if let orientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                image = image.oriented(forExifOrientation: orientation.int32Value)
            }
            let factor = min(1, 1280 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                         options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.65]),
                  jpeg.count < 600_000 else { releaseFrame(); return }
            var request = URLRequest(url: configuration.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "PUT"
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
            request.httpBody = jpeg
            upload = session.dataTask(with: request) { [weak self] _, response, error in
                guard let self else { return }
                self.releaseFrame()
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 401 || status == 409 {
                    self.finishBroadcastWithError(NSError(domain: "FadedAI", code: 3,
                                                         userInfo: [NSLocalizedDescriptionKey: "Åbn en ny skærmdeling i FadedAI."]))
                } else if error != nil || status != 200 {
                    self.failures += 1
                    if self.failures >= 8 {
                        self.finishBroadcastWithError(NSError(domain: "FadedAI", code: 4,
                                                             userInfo: [NSLocalizedDescriptionKey: "Forbindelsen til PC’en blev afbrudt."]))
                    }
                } else { self.failures = 0 }
            }
            upload?.resume()
        }
    }

    private func releaseFrame() { lock.lock(); busy = false; lock.unlock() }
}

private final class RedirectBlock: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
