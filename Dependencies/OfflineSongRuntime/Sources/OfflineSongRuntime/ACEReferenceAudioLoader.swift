// iPhone audio loader for the song-reference pipeline. The existing 24 kHz
// PC-reference path remains independent; this still needs real-device testing.
#if canImport(AVFAudio)
import Foundation
import AVFAudio

enum ACEReferenceAudioLoader {
    struct Prepared {
        /// Caller owns this unique scratch file and must remove it after use.
        let url: URL
        let info: ACEReferencePCMResult
    }

    enum Failure: LocalizedError {
        case unsupportedInput, conversion, outputBuffer
        var errorDescription: String? {
            switch self {
            case .unsupportedInput: return "Vælg en læsbar lydfil med én eller to kanaler."
            case .conversion: return "Lydfilen kunne ikke omdannes til 48 kHz stereo."
            case .outputBuffer: return "Der var ikke plads til lydudsnittet."
            }
        }
    }

    /// Create a temporary 48 kHz stereo float WAV, padded to a whole ACE hop.
    /// Conversion is block-based; no complete recording is held in memory.
    /// This path requires Apple-platform compilation and real-device testing.
    static func prepare(_ sourceURL: URL, in scratchDirectory: URL,
                        maxSeconds: Double = 30) async throws -> Prepared {
        let worker = Task.detached(priority: .userInitiated) {
            try convert(sourceURL, in: scratchDirectory, maxSeconds: maxSeconds)
        }
        return try await withTaskCancellationHandler {
            let prepared = try await worker.value
            do {
                try Task.checkCancellation()
                return prepared
            } catch {
                try? FileManager.default.removeItem(at: prepared.url)
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }

    private static func convert(_ sourceURL: URL, in scratchDirectory: URL,
                                maxSeconds: Double) throws -> Prepared {
        try Task.checkCancellation()
        var frames = try ACEReferencePCM(maxSeconds: maxSeconds)
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let source = try AVAudioFile(forReading: sourceURL)
        let input = source.processingFormat
        guard source.length > 0, input.sampleRate.isFinite, input.sampleRate > 0,
              (1...2).contains(input.channelCount),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target) else { throw Failure.unsupportedInput }

        let manager = FileManager.default
        try manager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let output = scratchDirectory.appendingPathComponent("ace-reference-" + UUID().uuidString + ".wav")
        guard !manager.fileExists(atPath: output.path) else { throw Failure.outputBuffer }
        var keep = false
        defer { if !keep { try? manager.removeItem(at: output) } }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: output, settings: target.settings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { writer = nil }
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
        #endif

        func write(_ left: [Float], _ right: [Float]) throws {
            try Task.checkCancellation()
            guard left.count == right.count, let buffer = AVAudioPCMBuffer(pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(left.count)),
                  let channels = buffer.floatChannelData else { throw Failure.outputBuffer }
            buffer.frameLength = AVAudioFrameCount(left.count)
            left.withUnsafeBufferPointer { if let base = $0.baseAddress { channels[0].update(from: base, count: left.count) } }
            right.withUnsafeBufferPointer { if let base = $0.baseAddress { channels[1].update(from: base, count: right.count) } }
            guard let writer else { throw Failure.outputBuffer }
            try writer.write(from: buffer)
        }

        var endOfInput = false
        var inputError: Error?
        var emptyOutputs = 0
        while frames.hasCapacity {
            try Task.checkCancellation()
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8_192) else {
                throw Failure.outputBuffer
            }
            var conversionError: NSError?
            let state = converter.convert(to: converted, error: &conversionError) { requested, status in
                if endOfInput || inputError != nil || Task.isCancelled {
                    status.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input,
                        frameCapacity: min(max(1, requested), 8_192)) else {
                    inputError = Failure.outputBuffer
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try source.read(into: buffer, frameCount: buffer.frameCapacity)
                    guard buffer.frameLength > 0 else {
                        endOfInput = true
                        status.pointee = .endOfStream
                        return nil
                    }
                    status.pointee = .haveData
                    return buffer
                } catch {
                    inputError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            try Task.checkCancellation()
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            if state == .error { throw Failure.conversion }
            let count = Int(converted.frameLength)
            if count > 0 {
                guard let channels = converted.floatChannelData else { throw Failure.outputBuffer }
                let left = Array(UnsafeBufferPointer(start: channels[0], count: count))
                let right = Array(UnsafeBufferPointer(start: channels[1], count: count))
                try frames.append(left: left, right: right, emit: write)
                emptyOutputs = 0
            } else {
                emptyOutputs += 1
            }
            if state == .endOfStream { break }
            // Avoid an infinite loop if a decoder repeatedly produces no output.
            if emptyOutputs > 2 { throw Failure.conversion }
        }
        let info = try frames.finish(emit: write)
        writer = nil // Close the WAV and finalize its header before returning it.
        try Task.checkCancellation()
        keep = true
        return Prepared(url: output, info: info)
    }
}
#endif
