@_implementationOnly import whisper

public enum LocalWhisperEngine {
    public static func transcribe(modelPath: String, samples: UnsafePointer<Float>,
                                  count: Int32, language: String) -> String? {
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
        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) { text += String(cString: segment) }
        }
        return text
    }
}
