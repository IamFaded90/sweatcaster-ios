// Stores typed app data as protected files under the existing Models directory.

import Foundation

protocol ModelStore {
    func load<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T?
    func save<T: Encodable>(_ value: T, forKey key: String) throws
    func delete(forKey key: String) throws
}

struct LocalModelStore: ModelStore {
    let root: URL
    let maximumBytes: Int

    init(root: URL = .documentsDirectory.appending(path: "Models", directoryHint: .isDirectory),
         maximumBytes: Int = 8_388_608) {
        self.root = root
        self.maximumBytes = maximumBytes
    }

    func load<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let bytes = try loadBytes(forKey: key) else { return nil }
        return try JSONDecoder().decode(type, from: bytes)
    }

    func save<T: Encodable>(_ value: T, forKey key: String) throws {
        try saveBytes(JSONEncoder().encode(value), forKey: key)
    }

    func delete(forKey key: String) throws { try delete(forKey: key, text: false) }

    func loadBytes(forKey key: String, text: Bool = false) throws -> Data? {
        let file = try LocalFileStore.safeWriteURL(fileURL(key, text: text), within: root)
        do { return try LocalFileStore.readBytes(from: file, maximumBytes: maximumBytes) }
        catch let error where LocalFileStore.isMissing(error) { return nil }
    }

    func saveBytes(_ bytes: Data, forKey key: String, text: Bool = false) throws {
        guard bytes.count <= maximumBytes else { throw LocalFileStore.Failure.tooLarge }
        let file = try fileURL(key, text: text)
        try LocalFileStore.writeBytes(bytes, to: file, within: root)
        try protectBackup(forKey: key, text: text)
    }

    func delete(forKey key: String, text: Bool) throws {
        try LocalFileStore(root: root, maximumBytes: maximumBytes).delete(fileURL(key, text: text))
    }

    func protectBackup(forKey key: String, text: Bool) throws {
        var file = try LocalFileStore.safeWriteURL(fileURL(key, text: text), within: root)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    private func fileURL(_ key: String, text: Bool) throws -> URL {
        guard (1...80).contains(key.utf8.count),
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw LocalFileStore.Failure.invalidPath
        }
        return root.appending(path: key + (text ? ".txt" : ".json"), directoryHint: .notDirectory)
    }
}
