import Darwin
import FadedAILlamaRuntime
import Foundation

struct GGUFPhoneModel: Identifiable, Sendable {
    static let prefix = "gguf:"
    static let maximumBytes: Int64 = 20 * 1_073_741_824
    static let root = URL.applicationSupportDirectory.appending(path: "GGUFModels", directoryHint: .isDirectory)

    let uuid: UUID
    let url: URL
    let bytes: Int64
    var id: String { Self.prefix + uuid.uuidString.lowercased() }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var memoryEstimateMiB: UInt64 { UInt64((Double(bytes) * 1.25 / 1_048_576).rounded(.up)) + 420 }

    static var installed: [Self] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            UUID(uuidString: folder.lastPathComponent).flatMap { installed($0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func installed(id: String) -> Self? {
        guard id.hasPrefix(prefix), let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return nil }
        return installed(uuid)
    }

    static func installed(_ uuid: UUID) -> Self? {
        let folder = path(for: uuid)
        let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        )
        guard let real = files?.first(where: { $0.pathExtension.lowercased() == "gguf" }),
              real.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path,
              folder.resolvingSymlinksInPath().deletingLastPathComponent().path == root.resolvingSymlinksInPath().path,
              let bytes = try? fileSize(real) else { return nil }
        return Self(uuid: uuid, url: real, bytes: bytes)
    }

    static func path(for uuid: UUID) -> URL {
        root.appending(path: uuid.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    static func fileSize(_ source: URL) throws -> Int64 {
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, (24...maximumBytes).contains(Int64(size)) else { throw PhoneModelError.invalidBundle }
        return Int64(size)
    }

    static func validateHeader(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 24), data.count == 24, data.prefix(4) == Data("GGUF".utf8) else {
            throw PhoneModelError.invalidBundle
        }
        let version = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let tensors = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        guard [2, 3].contains(version), (1...100_000).contains(tensors) else { throw PhoneModelError.invalidBundle }
    }

    static func validFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.utf8.count <= 180 && !name.hasPrefix(".") && lower.hasSuffix(".gguf") &&
            !lower.contains("mmproj") && lower.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) == nil &&
            !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func put(_ source: URL, uuid: UUID, filename: String, moving: Bool) throws {
        guard validFileName(filename) else { throw PhoneModelError.invalidBundle }
        let bytes = try fileSize(source)
        try validateHeader(source)
        if !moving && !PhoneModels.hasDownloadSpace(bytes: bytes + 100_000_000) { throw APIError.storage }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appending(path: ".install-" + UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let payload = stage.appending(path: filename)
        if moving { try fm.moveItem(at: source, to: payload) }
        else { try fm.copyItem(at: source, to: payload) }
        guard try fileSize(payload) == bytes else { throw PhoneModelError.invalidBundle }
        var staging = stage
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try staging.setResourceValues(properties)
        try fm.moveItem(at: stage, to: path(for: uuid))
    }

    static func importFile(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try put(source, uuid: UUID(), filename: source.lastPathComponent, moving: false)
    }
}

enum GGUFPhoneRuntime {
    struct Report: Sendable {
        let firstToken: Double
        let tokensPerSecond: Double
        let footprint: UInt64?
        let reply: String
    }

    enum Failure: Error { case unsupportedModel, inference }

    private static let initialized: Void = llama_backend_init()

    @MainActor static func generate(
        _ model: GGUFPhoneModel, prompt: String, instructions: String, history: [PhoneModels.ChatExchange],
        maximumTokens: Int32, update: @escaping @MainActor (String) -> Void
    ) async throws -> Report {
        guard PhoneMemoryBudget.assess(model).fit != .unavailable else { throw LocalComputeError.lowMemory }
        LocalCompute.beginModelLoad()
        let messages = (instructions.isEmpty ? [] : [Message("system", instructions)]) +
            history.flatMap { [Message("user", $0.prompt), Message("assistant", $0.reply)] } + [Message("user", prompt)]
        let worker = Task.detached(priority: .userInitiated) {
            try await run(model, messages: messages, maximumTokens: maximumTokens,
                          ready: { await LocalCompute.didLoadModel() }, update: update)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct Message: Sendable {
        let role: String
        let text: String
        init(_ role: String, _ text: String) { self.role = role; self.text = text }
    }

    private static func run(
        _ file: GGUFPhoneModel, messages: [Message], maximumTokens: Int32,
        ready: @Sendable () async -> Void, update: @escaping @MainActor (String) -> Void
    ) async throws -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        _ = initialized
        try Task.checkCancellation()
        var weightsParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        weightsParameters.n_gpu_layers = 0
        #else
        weightsParameters.n_gpu_layers = llama_supports_gpu_offload() ? 99 : 0
        #endif
        guard let model = llama_model_load_from_file(file.url.path, weightsParameters) else { throw Failure.unsupportedModel }
        defer { llama_model_free(model) }
        try Task.checkCancellation()
        guard let vocabulary = llama_model_get_vocab(model) else { throw Failure.unsupportedModel }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = 2_048
        contextParameters.n_batch = 256
        contextParameters.n_ubatch = 256
        contextParameters.n_threads = 4
        contextParameters.n_threads_batch = 4
        guard let context = llama_init_from_model(model, contextParameters) else { throw Failure.inference }
        defer { llama_free(context) }
        await ready()
        try Task.checkCancellation()

        let formatted = try format(messages, model: model)
        var tokens = [llama_token](repeating: 0, count: Int(contextParameters.n_ctx))
        let tokenCount = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_tokenize(vocabulary, formatted, Int32(formatted.utf8.count), buffer.baseAddress,
                           Int32(buffer.count), true, true)
        }
        guard tokenCount > 0, tokenCount + maximumTokens <= Int32(contextParameters.n_ctx) else { throw PhoneModelError.contextLimit }
        for startIndex in stride(from: 0, to: Int(tokenCount), by: Int(contextParameters.n_batch)) {
            try Task.checkCancellation()
            let count = min(Int(contextParameters.n_batch), Int(tokenCount) - startIndex)
            let code = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress?.advanced(by: startIndex), Int32(count)))
            }
            guard code == 0 else { throw Failure.inference }
        }

        guard let sampler = llama_sampler_init_greedy() else { throw Failure.inference }
        defer { llama_sampler_free(sampler) }
        var reply = ""
        var pendingUTF8: [UInt8] = []
        var first: ContinuousClock.Instant?
        var footprint: UInt64?
        var generated = 0
        var piece = [CChar](repeating: 0, count: 4_096)
        for _ in 0..<maximumTokens {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            let count = piece.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocabulary, token, $0.baseAddress, Int32($0.count), 0, false)
            }
            guard count >= 0, Int(count) <= piece.count else { throw Failure.inference }
            generated += 1
            pendingUTF8.append(contentsOf: piece.prefix(Int(count)).map { UInt8(bitPattern: $0) })
            if let text = String(bytes: pendingUTF8, encoding: .utf8), !text.isEmpty {
                pendingUTF8.removeAll(keepingCapacity: true)
                reply += text
                if first == nil {
                    first = clock.now
                    footprint = await LocalCompute.footprint()
                }
                if generated % 8 == 0 || generated == 1 { await update(reply) }
            } else if pendingUTF8.count > 16 {
                reply += String(decoding: pendingUTF8, as: UTF8.self)
                pendingUTF8.removeAll(keepingCapacity: true)
            }
            let code = withUnsafeMutablePointer(to: &token) {
                llama_decode(context, llama_batch_get_one($0, 1))
            }
            guard code == 0 else { throw Failure.inference }
        }
        if !pendingUTF8.isEmpty { reply += String(decoding: pendingUTF8, as: UTF8.self) }
        try Task.checkCancellation()
        guard let first, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PhoneModelError.emptyResponse }
        await update(reply)
        if let final = await LocalCompute.footprint() { footprint = max(footprint ?? 0, final) }
        let seconds = max(0.001, interval(first.duration(to: clock.now)))
        return Report(firstToken: interval(start.duration(to: first)), tokensPerSecond: Double(max(0, generated - 1)) / seconds,
                      footprint: footprint, reply: reply)
    }

    private static func interval(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func format(_ input: [Message], model: OpaquePointer) throws -> String {
        guard let template = llama_model_chat_template(model, nil) else { throw Failure.unsupportedModel }
        var pointers: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in pointers { free(pointer) } }
        func pointer(_ text: String) throws -> UnsafePointer<CChar> {
            guard let address = text.withCString({ strdup($0) }) else { throw Failure.inference }
            pointers.append(address)
            return UnsafePointer(address)
        }
        let messages = try input.map {
            try llama_chat_message(role: pointer($0.role), content: pointer($0.text.replacingOccurrences(of: "\0", with: "")))
        }
        var buffer = [CChar](repeating: 0, count: 32_768)
        let written = messages.withUnsafeBufferPointer { messageBuffer in
            buffer.withUnsafeMutableBufferPointer { output in
                llama_chat_apply_template(template, messageBuffer.baseAddress, messageBuffer.count, true,
                                          output.baseAddress, Int32(output.count))
            }
        }
        guard written >= 0 else { throw Failure.unsupportedModel }
        guard Int(written) < buffer.count else { throw PhoneModelError.contextLimit }
        return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
