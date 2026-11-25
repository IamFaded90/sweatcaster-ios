// Standalone PC-only checks; does not download a model or build the iOS app.
import Foundation

@main
struct PhoneSongReferenceModelsAPIChecks {
    static func main() async throws {
        let pinned = try SourceComponent(["safetensors_header_bytes": 40_528, "tensor_prefix": "encoder.",
                                          "tensor_count": 183, "tensor_dtype": "BF16",
                                          "range_start_inclusive": Int64(168_868_700),
                                          "range_end_inclusive": Int64(337_431_387),
                                          "range_bytes": Int64(168_562_688),
                                          "range_sha256": "567ab143316b1af548536b0390e9cb83f67675498614f429bec4c8d4c6ec4a96"])
        guard pinned.start == 168_868_700 && pinned.bytes == 168_562_688 else { fatalError("Pinned manifest failed") }
        let models = PhoneSongReferenceModels.shared
        let bad = URL(fileURLWithPath: "/tmp/not-the-song-model")
        switch await models.status(at: bad) {
        case .notInstalled: break
        default: fatalError("Invalid model path was presented as ready")
        }
        do { _ = try await models.preparedDirectory(at: bad); fatalError("Invalid path was accepted") }
        catch PhoneSongReferenceModelFailure.invalidModel { }
        catch PhoneSongReferenceModelFailure.invalidLocation { }
        do { try await models.remove(at: bad); fatalError("Invalid deletion path was accepted") }
        catch PhoneSongReferenceModelFailure.invalidLocation { }
        do { try await models.prepare(at: bad) { _ in }; fatalError("Invalid preparation path was accepted") }
        catch PhoneSongReferenceModelFailure.invalidLocation { }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("reference-recovery-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: false)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: false)
        let activeID = UUID().uuidString, orphanID = UUID().uuidString, unmarkedID = UUID().uuidString, otherRevisionID = UUID().uuidString
        for id in [activeID, orphanID, unmarkedID, otherRevisionID] {
            try fm.createDirectory(at: versions.appendingPathComponent(id, isDirectory: true), withIntermediateDirectories: false)
        }
        let revision = "test-revision"
        try SongReferenceStorageRecovery.mark(staging: versions.appendingPathComponent(activeID), version: activeID, revision: revision)
        try SongReferenceStorageRecovery.mark(staging: versions.appendingPathComponent(orphanID), version: orphanID, revision: revision)
        try SongReferenceStorageRecovery.mark(staging: versions.appendingPathComponent(otherRevisionID), version: otherRevisionID, revision: "other")
        let stage = root.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        let unknown = root.appendingPathComponent(".staging-not-a-uuid", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
        let outside = fm.temporaryDirectory.appendingPathComponent("reference-outside-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: outsideFile)
        let stageLink = root.appendingPathComponent(".staging-" + UUID().uuidString)
        let versionLink = versions.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: stageLink, withDestinationURL: outside)
        try fm.createSymbolicLink(at: versionLink, withDestinationURL: outside)
        let preservedDownload = downloads.appendingPathComponent("in-progress")
        try Data("keep".utf8).write(to: preservedDownload)
        try SongReferenceStorageRecovery.recover(root: root, revision: revision, currentVersion: nil, mayCleanVersions: false)
        guard !fm.fileExists(atPath: stage.path), fm.fileExists(atPath: versions.appendingPathComponent(orphanID).path) else {
            fatalError("Uncertain-current recovery removed a version or missed staging")
        }
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try SongReferenceStorageRecovery.recover(root: root, revision: revision, currentVersion: activeID, mayCleanVersions: true)
        guard !fm.fileExists(atPath: stage.path), !fm.fileExists(atPath: versions.appendingPathComponent(orphanID).path),
              fm.fileExists(atPath: versions.appendingPathComponent(activeID).path),
              fm.fileExists(atPath: versions.appendingPathComponent(unmarkedID).path),
              fm.fileExists(atPath: versions.appendingPathComponent(otherRevisionID).path),
              fm.fileExists(atPath: unknown.path), fm.fileExists(atPath: preservedDownload.path),
              fm.fileExists(atPath: outsideFile.path), fm.fileExists(atPath: stageLink.path), fm.fileExists(atPath: versionLink.path) else {
            fatalError("Recovery did not preserve the active/unknown files")
        }
        print("PASS: unavailable status and invalid preparation/removal paths are rejected")
        print("PASS: orphan recovery preserves active version, downloads and unowned folders")
    }
}
