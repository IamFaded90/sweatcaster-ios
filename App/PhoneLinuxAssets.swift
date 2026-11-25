import CryptoKit
import Foundation

/// The executable files are downloaded once. The exact bytes are verified again before execution.
actor PhoneLinuxAssets {
    static let shared = PhoneLinuxAssets()
    private static let npm = "https://cdn.jsdelivr.net/npm/v86@0.5.476/build/"
    private static let bios = "https://raw.githubusercontent.com/copy/v86/9457e7a2f6890f3133bb6ac0f749e588f63c4c36/bios/"
    struct Asset: Sendable {
        let name: String, source: String, size: Int, hash: String
    }
    static let manifest = [
        Asset(name: "library", source: npm + "libv86.js", size: 360014, hash: "3a5d3cbde1d5bf386b94250c92eaa82c0e730d2b8b166081a67698da97a285f8"),
        Asset(name: "wasm", source: npm + "v86-fallback.wasm", size: 2032957, hash: "930b6475adc94b6445df98c88eaa83bbbcbb449c1e59a74a365de09221e497a8"),
        Asset(name: "kernel", source: "https://i.copy.sh/buildroot-bzimage68.bin", size: 10068480, hash: "507a759c70ab7a490a233be454d0b5b88bc667956a410b531cb4edc091e2eb1c"),
        Asset(name: "bios", source: bios + "seabios.bin", size: 131072, hash: "73e3f359102e3a9982c35fce98eb7cd08f18303ac7f1ba6ebfbe6cdc1c244d98"),
        Asset(name: "vga", source: bios + "vgabios.bin", size: 36352, hash: "a4bc0d80cc3ca028c73dafa8fee396b8d054ce87ebd8abfbd31b06b437607880")
    ]
    private var installing = false
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentLinux/v86-0.5.476", isDirectory: true)
    }
    private func clearInterruptedDownloads(in parent: URL) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent.hasPrefix("install-") {
            if UUID(uuidString: String(child.lastPathComponent.dropFirst("install-".count))) != nil {
                try fm.removeItem(at: child)
            }
        }
    }
    private func verified(_ asset: Asset, at url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else { throw Failure.integrity }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == asset.hash else { throw Failure.integrity }
        return data
    }
    func payload() throws -> [String: String] {
        var values = [String: String]()
        for asset in Self.manifest {
            try Task.checkCancellation()
            let data = try verified(asset, at: directory.appendingPathComponent(asset.name))
            if asset.name == "library" {
                guard let library = String(data: data, encoding: .utf8) else { throw Failure.integrity }
                values[asset.name] = library
            } else { values[asset.name] = data.base64EncodedString() }
        }
        return values
    }
    func available() -> Bool {
        Self.manifest.allSatisfy { (try? verified($0, at: directory.appendingPathComponent($0.name))) != nil }
    }
    func install() async throws {
        guard !installing else { throw Failure.busy }
        if available() { return }
        installing = true
        defer { installing = false }
        let fm = FileManager.default
        var parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try clearInterruptedDownloads(in: parent)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try parent.setResourceValues(flags)
        let stage = parent.appendingPathComponent("install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for asset in Self.manifest {
            try Task.checkCancellation()
            guard let url = URL(string: asset.source) else { throw Failure.integrity }
            let (temp, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temp) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            _ = try verified(asset, at: temp)
            try fm.moveItem(at: temp, to: stage.appendingPathComponent(asset.name))
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: directory.path) { _ = try fm.replaceItemAt(directory, withItemAt: stage) }
        else { try fm.moveItem(at: stage, to: directory) }
    }
    func remove() throws {
        guard !installing else { throw Failure.busy }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    enum Failure: LocalizedError {
        case integrity, download, busy
        var errorDescription: String? {
            switch self {
            case .integrity: "Linux-pakken er ufuldstændig eller ændret. Hent den igen."
            case .download: "Linux-pakken kunne ikke hentes. Prøv igen med internet."
            case .busy: "En anden hentning af Linux-pakken er i gang."
            }
        }
    }
}
