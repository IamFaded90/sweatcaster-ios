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

enum ModelDiskStorage {
    struct Item: Identifiable, Sendable {
        let url: URL
        let name: String
        let kind: String
        let bytes: Int64
        var id: URL { url }
    }

    struct Snapshot: Sendable {
        var text: [String: Int64] = [:]
        var files: [Item] = []
        var total = Int64(0)
        var used: Int64?
        var capacity: Int64?
    }

    static let textRoot = PhoneModels.downloadedRoot

    static func allowedImageRoots(_ configured: [URL]) -> [URL] {
        let allowed = [URL.documentsDirectory, URL.applicationSupportDirectory].map { $0.resolvingSymlinksInPath().path + "/" }
        var seen = Set<URL>()
        return (configured + [textRoot]).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { root in allowed.contains(where: { root.path.hasPrefix($0) }) && seen.insert(root).inserted }
    }

    static func scan(textFolders: [String: URL], imageRoots: [URL]) -> Snapshot {
        var snapshot = Snapshot()
        var seen = Set<NSObject>()
        for (id, folder) in textFolders.sorted(by: { $0.key < $1.key }) {
            snapshot.text[id] = folderSize(folder, seen: &seen)
        }
        for folder in imageRoots {
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles])) ?? []
            for url in contents where ["ckpt", "safetensors"].contains(url.pathExtension.lowercased()) {
                guard let size = fileSize(url, seen: &seen) else { continue }
                let kind = url.lastPathComponent.lowercased().contains("lora") ? "LoRA" : "Billedmodelfil"
                snapshot.files.append(Item(url: url, name: url.lastPathComponent, kind: kind, bytes: size))
            }
        }
        snapshot.files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        snapshot.total = snapshot.text.values.reduce(0, +) + snapshot.files.reduce(0) { $0 + $1.bytes }
        if let volume = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = volume.volumeTotalCapacity, let free = volume.volumeAvailableCapacity {
            snapshot.capacity = Int64(total)
            snapshot.used = Int64(max(0, total - free))
        }
        return snapshot
    }

    static func delete(_ file: Item, within roots: [URL]) throws {
        let target = file.url.standardizedFileURL
        guard roots.contains(target.deletingLastPathComponent()), target == target.resolvingSymlinksInPath(),
              ["ckpt", "safetensors"].contains(target.pathExtension.lowercased()),
              try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PhoneModelError.invalidBundle
        }
        try FileManager.default.removeItem(at: target)
    }

    static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(3))) + " GB"
    }

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                     .fileAllocatedSizeKey, .fileSizeKey, .fileResourceIdentifierKey]

    private static func folderSize(_ folder: URL, seen: inout Set<NSObject>) -> Int64 {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return 0 }
        guard let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total = Int64(0)
        for case let file as URL in contents {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                contents.skipDescendants()
                continue
            }
            total += fileSize(file, seen: &seen) ?? 0
        }
        return total
    }

    private static func fileSize(_ file: URL, seen: inout Set<NSObject>) -> Int64? {
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        if let id = values.fileResourceIdentifier as? NSObject, !seen.insert(id).inserted { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}
