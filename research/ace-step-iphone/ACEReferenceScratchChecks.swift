import Foundation

@main struct ACEReferenceScratchChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ace-scratch-check-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let owned = root.appendingPathComponent("ace-reference-" + UUID().uuidString + ".wav")
        let unrelated = root.appendingPathComponent("my-recording.wav")
        let malformed = root.appendingPathComponent("ace-reference-not-a-uuid.wav")
        let folder = root.appendingPathComponent("ace-reference-" + UUID().uuidString + ".wav", isDirectory: true)
        let link = root.appendingPathComponent("ace-reference-" + UUID().uuidString + ".wav")
        for url in [owned, unrelated, malformed] { try Data([1, 2, 3]).write(to: url) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
        ACEReferenceScratch.clean(root)
        precondition(!fm.fileExists(atPath: owned.path))
        precondition(fm.fileExists(atPath: unrelated.path) && fm.fileExists(atPath: malformed.path))
        precondition(fm.fileExists(atPath: folder.path) && fm.fileExists(atPath: link.path))
        print("PASS: only the app's temporary reference WAV was removed")
    }
}
