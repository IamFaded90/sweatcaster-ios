// Bounded local reads and protected writes within an explicitly owned directory.

import Darwin
import Foundation

protocol FileStore {
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T
    func write<T: Encodable>(_ value: T, to url: URL) throws
    func exists(_ url: URL) -> Bool
    func delete(_ url: URL) throws
}

struct LocalFileStore: FileStore {
    enum Failure: Error { case invalidPath, invalidFile, tooLarge }

    static let maximumVideoBytes = 500_000_000

    let root: URL
    let maximumBytes: Int

    init(root: URL, maximumBytes: Int = 8_388_608) {
        self.root = root
        self.maximumBytes = maximumBytes
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let file = try Self.safeWriteURL(url, within: root)
        return try JSONDecoder().decode(type, from: Self.readBytes(from: file, maximumBytes: maximumBytes))
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        try Self.writeBytes(data, to: url, within: root)
    }

    func exists(_ url: URL) -> Bool {
        guard let file = try? Self.safeWriteURL(url, within: root),
              let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return info.isRegularFile == true && info.isSymbolicLink != true
    }

    func delete(_ url: URL) throws {
        let file = try Self.safeWriteURL(url, within: root)
        do { try FileManager.default.removeItem(at: file) }
        catch let error where Self.isMissing(error) { return }
    }

    static func isMissing(_ error: Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    static func readBytes(from url: URL, maximumBytes: Int) throws -> Data {
        guard (0..<Int.max).contains(maximumBytes) else { throw Failure.invalidPath }
        let handle = try openRegularFile(url, maximumBytes: maximumBytes)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - result.count else { throw Failure.tooLarge }
            result.append(chunk)
        }
        return result
    }

    static func readPrefix(from url: URL, count: Int, maximumBytes: Int) throws -> Data {
        guard count > 0, count <= 65_536 else { throw Failure.invalidPath }
        let handle = try openRegularFile(url, maximumBytes: maximumBytes)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    @discardableResult
    static func checkedFileSize(_ url: URL, maximumBytes: Int) throws -> Int {
        guard url.isFileURL else { throw Failure.invalidPath }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size >= 0 else { throw Failure.invalidFile }
        guard size <= maximumBytes else { throw Failure.tooLarge }
        return size
    }

    private static func openRegularFile(_ url: URL, maximumBytes: Int) throws -> FileHandle {
        try checkedFileSize(url, maximumBytes: maximumBytes)
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        do {
            var statBuffer = stat()
            guard fstat(descriptor, &statBuffer) == 0,
                  (statBuffer.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  statBuffer.st_size >= 0 else { throw Failure.invalidFile }
            guard statBuffer.st_size <= Int64(maximumBytes) else { throw Failure.tooLarge }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func safeWriteURL(_ url: URL, within root: URL) throws -> URL {
        guard url.isFileURL, root.isFileURL else { throw Failure.invalidPath }
        let original = url.standardizedFileURL
        let scope = root.standardizedFileURL
        if let info = try metadata(scope), (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFDIR) {
            throw Failure.invalidPath
        }
        let base = try canonicalDirectory(scope)
        let parent = try canonicalDirectory(original.deletingLastPathComponent())
        guard parent.path == base.path || parent.path.hasPrefix(base.path + "/") else { throw Failure.invalidPath }
        let file = parent.appendingPathComponent(original.lastPathComponent, isDirectory: false)
        if let info = try metadata(file), (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) { throw Failure.invalidFile }
        return file
    }

    static func writeBytes(_ data: Data, to url: URL, within root: URL) throws {
        try data.write(to: preparedDestination(url, within: root), options: [.atomic, .completeFileProtection])
    }

    static func copyProtectedFile(from source: URL, to url: URL, within root: URL, maximumBytes: Int) throws {
        try checkedFileSize(source, maximumBytes: maximumBytes)
        let file = try preparedDestination(url, within: root)
        let folder = file.deletingLastPathComponent()
        let staging = try safeWriteURL(folder.appendingPathComponent(".fadedai-\(UUID().uuidString).tmp"), within: root)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        try checkedFileSize(staging, maximumBytes: maximumBytes)
        try protectFile(staging)
        try manager.moveItem(at: staging, to: file)
    }

    static func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private static func preparedDestination(_ url: URL, within root: URL) throws -> URL {
        let file = try safeWriteURL(url, within: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let checked = try safeWriteURL(url, within: root)
        guard checked.path == file.path else { throw Failure.invalidPath }
        return checked
    }

    private static func canonicalDirectory(_ url: URL) throws -> URL {
        if try metadata(url) != nil { return url.resolvingSymlinksInPath().standardizedFileURL }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw Failure.invalidPath }
        return try canonicalDirectory(parent).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func metadata(_ url: URL) throws -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        if result == 0 { return info }
        let code = errno
        if code == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
