import AVFAudio
import Foundation

enum SongReferenceAudio {
    /// A bounded PCM reference, never a complete copied listening library.
    static func prepare(_ url: URL, seconds: Double = 30) async throws -> Data {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let source = try AVAudioFile(forReading: url)
            let input = source.processingFormat
            let maximum = AVAudioFramePosition(input.sampleRate * min(180, max(1, seconds)))
            let count = AVAudioFrameCount(min(source.length, maximum))
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: count),
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: input, to: target),
                  let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) / input.sampleRate * 24_000) + 64)
            else { throw CocoaError(.fileReadCorruptFile) }
            try source.read(into: buffer, frameCount: count)
            try Task.checkCancellation()
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            if let error { throw error }
            guard result != .error, converted.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: file) }
            var output: AVAudioFile? = try AVAudioFile(forWriting: file, settings: target.settings,
                commonFormat: .pcmFormatInt16, interleaved: true)
            try output?.write(from: converted)
            output = nil
            try Task.checkCancellation()
            return try Data(contentsOf: file)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
