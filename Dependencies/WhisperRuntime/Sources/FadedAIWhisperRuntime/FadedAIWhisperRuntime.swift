@_implementationOnly import whisper
import Foundation

public enum LocalWhisperEngine {
    /// One per transcription. whisper.cpp can poll from a different thread than the cancelling task.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        public init() {}

        public var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        public func checkCancellation() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    public struct Segment: Sendable {
        public let started: Double
        public let ended: Double
        public let text: String
    }

    public static func transcribe(modelPath: String, samples: UnsafePointer<Float>,
                                  count: Int32, language: String) -> String? {
        transcribeSegments(modelPath: modelPath, samples: samples, count: count, language: language)?
            .map(\.text).joined()
    }

    public static func transcribeSegments(modelPath: String, samples: UnsafePointer<Float>,
                                          count: Int32, language: String, timestamped: Bool = true) -> [Segment]? {
        transcribeSegments(modelPath: modelPath, samples: samples, count: count, language: language,
                           timestamped: timestamped, cancellation: nil)
    }

    public static func transcribeSegments(modelPath: String, samples: UnsafePointer<Float>, count: Int32,
                                          language: String, timestamped: Bool, cancellation: Cancellation?) -> [Segment]? {
        guard cancellation?.isCancelled != true else { return nil }
        guard count > 0 else { return [] }
        var contextParameters = whisper_context_default_params()
        #if targetEnvironment(simulator)
        contextParameters.use_gpu = false
        #endif
        guard let context = whisper_init_from_file_with_params(modelPath, contextParameters) else { return nil }
        defer { whisper_free(context) }
        guard cancellation?.isCancelled != true else { return nil }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = 4
        parameters.no_context = true
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        parameters.no_timestamps = !timestamped
        if let cancellation {
            parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            parameters.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<Cancellation>.fromOpaque(userData).takeUnretainedValue().isCancelled
            }
        }
        let status = withExtendedLifetime(cancellation) {
            language.withCString { languageCode in
                parameters.language = languageCode
                return whisper_full(context, parameters, samples, count)
            }
        }
        guard cancellation?.isCancelled != true, status == 0 else { return nil }
        let segments = whisper_full_n_segments(context)
        guard segments >= 0 else { return nil }
        let duration = Double(count) / 16_000
        return (0..<segments).compactMap { index in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            return Segment(started: min(duration, max(0, start)),
                           ended: min(duration, max(0, start, end)), text: String(cString: text))
        }
    }
}
