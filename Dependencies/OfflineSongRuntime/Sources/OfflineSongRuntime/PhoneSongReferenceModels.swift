import Foundation

/// Availability of the optional reference-audio weights. This is independent
/// of the existing text-to-song model and does not enable reference generation.
public enum PhoneSongReferenceModelStatus: Sendable {
    case notInstalled, preparing, ready
}

public enum PhoneSongReferenceModelFailure: LocalizedError {
    case busy, invalidLocation, insufficientSpace, invalidModel, unavailable
    public var errorDescription: String? {
        switch self {
        case .busy: "Sangreferencens model er allerede i gang med at blive klargjort."
        case .invalidLocation: "Sangreferencens modelmappe kunne ikke bruges."
        case .insufficientSpace: "Der mangler ledig plads til at klargøre sangreferencen."
        case .invalidModel: "Sangreferencens modelfiler kunne ikke kontrolleres. Prøv igen."
        case .unavailable: "Sangreferencens model er ikke tilgængelig. Prøv igen senere."
        }
    }
}

/// An optional model preparer. Nothing calls this from the existing song path;
/// callers must opt in explicitly, and a successful preparation alone does not
/// mean audio-reference generation is implemented or tested on a device.
public actor PhoneSongReferenceModels {
    public static let shared = PhoneSongReferenceModels()
    private var worker: Task<Void, Error>?
    #if FADEDAI_RANGE_TESTS
    private var fixtureProtocolClasses: [AnyClass]?
    /// Available only in the explicitly compiled PC fixture test.
    func setFixtureProtocolClasses(_ classes: [AnyClass]) { fixtureProtocolClasses = classes }
    #endif
    private init() { }

    public func status(at base: URL) async -> PhoneSongReferenceModelStatus {
        if worker != nil { return .preparing }
        return (try? Self.isReady(base: base)) == true ? .ready : .notInstalled
    }

    /// The optional weights live separately from the existing text-song root.
    /// This checks integrity before returning the version directory; it does
    /// not imply that reference-audio generation is available or verified.
    public func preparedDirectory(at base: URL) throws -> URL {
        guard worker == nil, try Self.isReady(base: base),
              let receipt = try Self.currentReceipt(base: base) else {
            throw PhoneSongReferenceModelFailure.invalidModel
        }
        return try Self.referenceRoot(base: base).appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(receipt.version, isDirectory: true)
    }

    public func prepare(at base: URL, progress: @Sendable @escaping (String) -> Void) async throws {
        guard worker == nil else { throw PhoneSongReferenceModelFailure.busy }
        #if FADEDAI_RANGE_TESTS
        let fixtureClasses = fixtureProtocolClasses
        let task = Task.detached(priority: .utility) {
            let downloader: SongReferenceRangeDownload
            if let fixtureClasses {
                downloader = SongReferenceRangeDownload(allowedHosts: ["huggingface.co", "us.aws.cdn.hf.co"],
                                                        chunkBytes: 4 * 1024 * 1024, protocolClasses: fixtureClasses)
            } else {
                downloader = SongReferenceRangeDownload(allowedHosts: ["huggingface.co", "us.aws.cdn.hf.co"])
            }
            try await Self.prepareFiles(base: base, downloader: downloader, progress: progress)
        }
        #else
        let task = Task.detached(priority: .utility) {
            try await Self.prepareFiles(base: base,
                downloader: SongReferenceRangeDownload(allowedHosts: ["huggingface.co", "us.aws.cdn.hf.co"]), progress: progress)
        }
        #endif
        worker = task
        defer { worker = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError { throw CancellationError() }
        catch let error as PhoneSongReferenceModelFailure { throw error }
        catch SongReferenceRangeFailure.verificationFailed { throw PhoneSongReferenceModelFailure.invalidModel }
        catch is RebuildFailure { throw PhoneSongReferenceModelFailure.invalidModel }
        catch is SongReferenceEncoderError { throw PhoneSongReferenceModelFailure.invalidModel }
        catch { throw PhoneSongReferenceModelFailure.unavailable }
    }

    public func cancel() { worker?.cancel() }

    /// Remove only this preparer's dedicated, app-owned reference directory.
    /// The existing song model, installed songs and other user files are not touched.
    public func remove(at base: URL) throws {
        guard worker == nil else { throw PhoneSongReferenceModelFailure.busy }
        let root = try Self.referenceRoot(base: base)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try Self.checkDirectory(root)
            try fm.removeItem(at: root)
        }
    }

    private struct Receipt: Codable {
        let revision: String
        let version: String
        let encoderSHA256: String
        let tokenizerSHA256: String
    }
    private struct Pinned {
        let label: String
        let url: URL
        let etag: String
        let totalBytes: Int64
        let headerBytes: Int64
        let headerSHA: String
        let start: Int64
        let rangeBytes: Int64
        let rangeSHA: String
        let prefix: String
        let tensors: Int
        var component: SourceComponent {
            get throws {
                try SourceComponent(["safetensors_header_bytes": Int(headerBytes - 8), "tensor_prefix": prefix,
                    "tensor_count": tensors, "tensor_dtype": "BF16", "range_start_inclusive": start,
                    "range_end_inclusive": start + rangeBytes - 1, "range_bytes": rangeBytes,
                    "range_sha256": rangeSHA])
            }
        }
    }
    private static let revision = "571cee88618ae5ef3d3fcdf79c46068ce4e2d727"
    // Whole-file hashes were checked against the official LFS metadata. Header
    // and range hashes below were derived locally from those verified files;
    // they are not separately published official hashes.
    private static let encoder = Pinned(label: "Lydencoder",
        url: URL(string: "https://huggingface.co/ACE-Step/Ace-Step1.5/resolve/571cee88618ae5ef3d3fcdf79c46068ce4e2d727/vae/diffusion_pytorch_model.safetensors")!,
        etag: "\"e8d754cd5cb69cf864a2d44a61b39bf61354ebac7fc70680bbfdb8ed49b1bc8b\"",
        totalBytes: 337_431_388, headerBytes: 40_536,
        headerSHA: "ee65a4b1609150f6be18b8b164c77f340a326c3a5912acc686ea5227f60c9528",
        start: 168_868_700, rangeBytes: 168_562_688,
        rangeSHA: "567ab143316b1af548536b0390e9cb83f67675498614f429bec4c8d4c6ec4a96",
        prefix: "encoder.", tensors: 183)
    private static let tokenizer = Pinned(label: "Lydtokenizer",
        url: URL(string: "https://huggingface.co/ACE-Step/Ace-Step1.5/resolve/571cee88618ae5ef3d3fcdf79c46068ce4e2d727/acestep-v15-turbo/model.safetensors")!,
        etag: "\"077d06c5a16c9f9ff327389b66b0dd355fe3b8f7ad2777ef6767cbd9022d2a7c\"",
        totalBytes: 4_787_825_604, headerBytes: 80_568,
        headerSHA: "1b5ffdcb5660c9ca5bf91ad3867afc266b2697ba962e6580fd5675f82ca344f1",
        start: 4_577_761_208, rangeBytes: 210_064_396,
        rangeSHA: "ec42754b457748cd41a1b04f6ebcbc1f9e31e67c8677b28cff0b7193113f9c1d",
        prefix: "tokenizer.", tensors: 32)

    private static func referenceRoot(base: URL) throws -> URL {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PhoneSongReferenceModelFailure.invalidLocation
        }
        let expected = applicationSupport.appendingPathComponent("FadedAI/OfflineSongs", isDirectory: true)
        guard base.isFileURL, base.standardizedFileURL == expected.standardizedFileURL else {
            throw PhoneSongReferenceModelFailure.invalidLocation
        }
        return expected.appendingPathComponent("ACEReferenceModels", isDirectory: true)
    }

    private static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw PhoneSongReferenceModelFailure.invalidLocation }
    }

    private static func digest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PhoneSongReferenceModelFailure.invalidModel }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let hash = try StreamingSHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try hash.update(data)
        }
        return try hash.finish()
    }

    private static func currentReceipt(base: URL) throws -> Receipt? {
        let root = try referenceRoot(base: base)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try checkDirectory(root)
        let current = root.appendingPathComponent("current.json")
        guard let values = try? current.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 4096,
              let data = try? Data(contentsOf: current),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.revision == revision,
              UUID(uuidString: receipt.version) != nil else { return nil }
        return receipt
    }

    private static func isReady(base: URL) throws -> Bool {
        let root = try referenceRoot(base: base)
        guard let receipt = try currentReceipt(base: base) else { return false }
        let version = root.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(receipt.version, isDirectory: true)
        try checkDirectory(root.appendingPathComponent("versions", isDirectory: true)); try checkDirectory(version)
        let encoder = version.appendingPathComponent("ace_vae_encoder_f16.safetensors")
        let tokenizer = version.appendingPathComponent("ace_audio_tokenizer_bf16.safetensors")
        guard try encoder.resourceValues(forKeys: [.fileSizeKey]).fileSize == 168_544_912,
              let tokenSize = try tokenizer.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              tokenSize > Int(Self.tokenizer.rangeBytes) else { return false }
        return try digest(encoder) == receipt.encoderSHA256 && digest(tokenizer) == receipt.tokenizerSHA256
    }

    private static func prepareFiles(base: URL, downloader: SongReferenceRangeDownload,
                                     progress: @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        let root = try referenceRoot(base: base)
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try checkDirectory(base)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try checkDirectory(root)
        let currentURL = root.appendingPathComponent("current.json")
        let pointerIsLink = (try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let pointerExists = fm.fileExists(atPath: currentURL.path) || pointerIsLink
        let current = try currentReceipt(base: base)
        try SongReferenceStorageRecovery.recover(root: root, revision: revision, currentVersion: current?.version,
                                                 mayCleanVersions: !pointerExists || current != nil)
        if (try? isReady(base: base)) == true { return }
        #if os(iOS)
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= 1_500_000_000 else { throw PhoneSongReferenceModelFailure.insufficientSpace }
        #endif
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true); try checkDirectory(downloads)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true); try checkDirectory(versions)
        let version = UUID().uuidString
        let staging = root.appendingPathComponent(".staging-" + version, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try SongReferenceStorageRecovery.mark(staging: staging, version: version, revision: revision)
        func fetch(_ asset: Pinned, header: Bool) async throws -> URL {
            try Task.checkCancellation()
            let kind = header ? "header" : "range"
            let path = downloads.appendingPathComponent(asset.prefix == "encoder." ? "encoder-" + kind : "tokenizer-" + kind)
            progress("Henter \(asset.label.lowercased()) · \(header ? "header" : "modeldata")…")
            return try await downloader.fetch(url: asset.url, partial: path,
                size: header ? asset.headerBytes : asset.rangeBytes, sourceOffset: header ? 0 : asset.start,
                sourceBytes: asset.totalBytes, strongETag: asset.etag) {
                    try digest($0) == (header ? asset.headerSHA : asset.rangeSHA)
                }
        }
        let encoderHeader = try await fetch(encoder, header: true)
        let encoderRange = try await fetch(encoder, header: false)
        let sourceEncoder = staging.appendingPathComponent("encoder-bf16.safetensors")
        progress("Kontrollerer og samler lydencoderen…")
        try RebuildSafeTensors.run(component: encoder.component, headerURL: encoderHeader, fragmentURL: encoderRange,
                                   outputURL: sourceEncoder, headerSHA: encoder.headerSHA)
        let converted = staging.appendingPathComponent("ace_vae_encoder_f16.safetensors")
        progress("Klargør lydencoderen…")
        try SongReferenceEncoderConversion.convert(input: sourceEncoder, staging: converted)
        try fm.removeItem(at: sourceEncoder)
        let tokenizerHeader = try await fetch(tokenizer, header: true)
        let tokenizerRange = try await fetch(tokenizer, header: false)
        let tokenFile = staging.appendingPathComponent("ace_audio_tokenizer_bf16.safetensors")
        progress("Kontrollerer og samler lydtokenizeren…")
        try RebuildSafeTensors.run(component: tokenizer.component, headerURL: tokenizerHeader, fragmentURL: tokenizerRange,
                                   outputURL: tokenFile, headerSHA: tokenizer.headerSHA)
        try Task.checkCancellation()
        progress("Kontrollerer de færdige modelfiler…")
        let receipt = Receipt(revision: revision, version: version, encoderSHA256: try digest(converted),
                              tokenizerSHA256: try digest(tokenFile))
        try Task.checkCancellation()
        let destination = versions.appendingPathComponent(version, isDirectory: true)
        var moved = false
        var committed = false
        defer { if moved && !committed { try? fm.removeItem(at: destination) } }
        try fm.moveItem(at: staging, to: destination)
        moved = true
        try Task.checkCancellation()
        // A failure before this final pointer update leaves the previous version intact.
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("current.json"), options: .atomic)
        committed = true
        // Keep verified download/identity pairs together. Deleting one before
        // the other could leave an unrecoverable orphan if the app is killed.
        // Explicit removal removes the whole dedicated reference directory.
        progress("Sangreferencens modelfiler er klargjort. Funktionen skal stadig testes på iPhone.")
    }
}
