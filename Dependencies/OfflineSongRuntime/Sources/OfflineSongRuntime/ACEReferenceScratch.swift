import Foundation

/// Clean only the uniquely named temporary WAVs written by our reference
/// loader. Called while PhoneSongEngine owns its serial generation slot.
enum ACEReferenceScratch {
    static func isOwnedName(_ name: String) -> Bool {
        let prefix = "ace-reference-"
        guard name.hasPrefix(prefix), name.hasSuffix(".wav") else { return false }
        let id = name.dropFirst(prefix.count).dropLast(".wav".count)
        return UUID(uuidString: String(id)) != nil
    }

    static func clean(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where isOwnedName(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
