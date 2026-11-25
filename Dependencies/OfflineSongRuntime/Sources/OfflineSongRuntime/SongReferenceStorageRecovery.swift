import Foundation

/// Cleans only explicitly marked reference-model work owned by this feature.
/// Call from the single preparer actor, never while another preparer is active.
enum SongReferenceStorageRecovery {
    private struct Marker: Codable {
        let owner: String
        let revision: String
        let version: String
    }
    private static let owner = "FadedAI.ACEReferenceModels"
    private static let markerName = ".faded-reference-version.json"

    static func mark(staging: URL, version: String, revision: String) throws {
        guard UUID(uuidString: version) != nil else { throw PhoneSongReferenceModelFailure.invalidLocation }
        let marker = Marker(owner: owner, revision: revision, version: version)
        try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent(markerName), options: .withoutOverwriting)
    }

    /// Preserve the active version, downloads, unknown names, unmarked folders,
    /// and symlinks. If a current pointer exists but is invalid, callers must
    /// pass `mayCleanVersions: false` because the active version is unknown.
    static func recover(root: URL, revision: String, currentVersion: String?, mayCleanVersions: Bool) throws {
        let fm = FileManager.default
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".staging-"), UUID(uuidString: String(name.dropFirst(".staging-".count))) != nil,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try fm.removeItem(at: entry)
        }
        guard mayCleanVersions else { return }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        guard fm.fileExists(atPath: versions.path) else { return }
        let values = try versions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw PhoneSongReferenceModelFailure.invalidLocation }
        for entry in try fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let version = entry.lastPathComponent
            guard UUID(uuidString: version) != nil, version != currentVersion,
                  let folder = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  folder.isDirectory == true, folder.isSymbolicLink != true else { continue }
            let markerURL = entry.appendingPathComponent(markerName)
            guard let meta = try? markerURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  meta.isRegularFile == true, meta.isSymbolicLink != true, let size = meta.fileSize, size <= 1024,
                  let data = try? Data(contentsOf: markerURL), let marker = try? JSONDecoder().decode(Marker.self, from: data),
                  marker.owner == owner, marker.revision == revision, marker.version == version else { continue }
            try fm.removeItem(at: entry)
        }
    }
}
