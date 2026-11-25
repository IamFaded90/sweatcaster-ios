import Foundation

enum SongFileIntegrity {
    /// Hash in bounded blocks so large model weights never occupy RAM twice.
    static func matches(_ file: URL, sha256 expected: String) throws -> Bool {
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let hash = try StreamingSHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            try hash.update(bytes)
        }
        try Task.checkCancellation()
        return try hash.finish() == expected
    }
}
