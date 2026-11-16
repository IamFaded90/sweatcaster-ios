@_implementationOnly import whisper

public enum LocalWhisperEngine {
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
                                          count: Int32, language: String) -> [Segment]? {
        var contextParameters = whisper_context_default_params()
        #if targetEnvironment(simulator)
        contextParameters.use_gpu = false
        #endif
        guard let context = whisper_init_from_file_with_params(modelPath, contextParameters) else { return nil }
        defer { whisper_free(context) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = 4
        parameters.no_context = true
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        let status = language.withCString { languageCode in
            parameters.language = languageCode
            return whisper_full(context, parameters, samples, count)
        }
        guard status == 0 else { return nil }
        let segments = whisper_full_n_segments(context)
        guard segments >= 0 else { return nil }
        return (0..<segments).compactMap { index in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            return Segment(started: max(0, start), ended: max(0, start, end), text: String(cString: text))
        }
    }
}
