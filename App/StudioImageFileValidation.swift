import CryptoKit
import Foundation
import MediaGenerationKit

/// A single serial installer checks model files. Keep its file offset and digest alive during app switches.
@MainActor
final class StudioImageValidationGate {
    private var active = false
    private var waiter: CheckedContinuation<Void, Never>?

    func setActive(_ value: Bool) {
        active = value
        if value { wake() }
    }

    func wake() {
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }

    func waitUntilActive() async throws {
        while !active {
            try Task.checkCancellation()
            await withCheckedContinuation { waiter = $0 }
        }
        try Task.checkCancellation()
    }
}

enum StudioImageFileValidation {
    /// URLSession may have delivered the whole file just before the previous process stopped.
    static func recoverStagedFile(at staged: URL, expectedBytes: Int64) throws {
        let manager = FileManager.default
        let incoming = staged.appendingPathExtension("incoming")
        // Both names are only for completed URLSession deliveries. Resume data lives separately.
        if manager.fileExists(atPath: staged.path) {
            let size = try LocalFileStore.checkedFileSize(staged, maximumBytes: Int.max)
            if Int64(size) != expectedBytes { try manager.removeItem(at: staged) }
        }
        guard manager.fileExists(atPath: incoming.path) else { return }
        let size = try LocalFileStore.checkedFileSize(incoming, maximumBytes: Int.max)
        guard Int64(size) == expectedBytes else {
            try manager.removeItem(at: incoming)
            return
        }
        if manager.fileExists(atPath: staged.path) {
            try manager.removeItem(at: incoming)
            return
        }
        try manager.moveItem(at: incoming, to: staged)
    }

    static func digest(at url: URL, expectedBytes: Int64,
                       checkpoint: (Int) async throws -> Void) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        var nextCheckpoint: Int64 = 0
        while true {
            try Task.checkCancellation()
            if count >= nextCheckpoint {
                try await checkpoint(Int(min(99, Double(count) / Double(max(1, expectedBytes)) * 100)))
                nextCheckpoint = count + 8 * 1_048_576
            }
            let bytesRead = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return 0 }
                hash.update(data: chunk)
                return chunk.count
            }
            if bytesRead == 0 { break }
            count += Int64(bytesRead)
        }
        guard count == expectedBytes else { throw CocoaError(.fileReadCorruptFile) }
        try await checkpoint(100)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct StudioImageTransfer: Equatable, Sendable {
    let id: UUID
    let model: StudioImageModel

    var identifier: String { "\(id.uuidString):\(model.id)" }

    init(model: StudioImageModel) {
        id = UUID()
        self.model = model
    }

    init?(_ identifier: String) {
        let parts = identifier.split(separator: ":")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let model = StudioImageModel(rawValue: String(parts[1])) else { return nil }
        self.id = id
        self.model = model
    }

    func adjust(_ tasks: [URLSessionTask], paused: Bool, ready: (StudioImageDownloadFile) -> Bool)
        -> (fractions: [String: Double], missing: [StudioImageDownloadFile]) {
        var fractions: [String: Double] = [:]
        for task in tasks {
            guard let item = StudioImageTransferFile(task), item.transfer == self,
                  task.state == .running || task.state == .suspended else { continue }
            let received = Double(max(0, task.countOfBytesReceived)) / Double(item.file.bytes)
            fractions[item.file.name] = max(fractions[item.file.name] ?? 0, min(1, received))
            if paused && task.state == .running { task.suspend() }
            if !paused && task.state == .suspended { task.resume() }
        }
        let missing = model.downloadFiles.filter { file in
            if ready(file) {
                fractions[file.name] = 1
                return false
            }
            return fractions[file.name] == nil
        }
        return (fractions, missing)
    }
}

struct StudioImageTransferFile: Sendable {
    let transfer: StudioImageTransfer
    let file: StudioImageDownloadFile
    let usedResumeData: Bool

    init(transfer: StudioImageTransfer, file: StudioImageDownloadFile) {
        self.transfer = transfer
        self.file = file
        usedResumeData = false
    }

    init?(_ task: URLSessionTask) {
        guard let description = task.taskDescription else { return nil }
        let fields = description.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3 || (fields.count == 4 && fields[3] == "resume"),
              let transfer = StudioImageTransfer("\(fields[0]):\(fields[1])"),
              let file = transfer.model.downloadFiles.first(where: { $0.name == fields[2] }) else { return nil }
        self.transfer = transfer
        self.file = file
        usedResumeData = fields.count == 4
    }
}

final class StudioImageDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(StudioImageTransferFile, Double)
        case staged(StudioImageTransferFile)
        case failed(StudioImageTransferFile, Error)
        case eventsFinished
    }

    private static let storage = URL.applicationSupportDirectory.appending(path: "FadedAI", directoryHint: .isDirectory)
        .appending(path: "StudioImageDownloads", directoryHint: .isDirectory)
    private static let maximumResumeDataBytes = 1_048_576
    var deliver: (@Sendable (Event) -> Void)?
    private let lock = NSLock()
    private var active: StudioImageTransfer?
    private var reportedPercent: [String: Int] = [:]

    func track(_ transfer: StudioImageTransfer) {
        lock.withLock { active = transfer; reportedPercent.removeAll() }
        recoverStagedFiles(for: transfer)
    }

    func recoverStagedFiles(for transfer: StudioImageTransfer) {
        lock.withLock {
            guard transfer == active else { return }
            for file in transfer.model.downloadFiles {
                let staged = stagedURL(for: StudioImageTransferFile(transfer: transfer, file: file))
                do { try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: file.bytes) }
                catch { AppDiagnostics.record(error) }
            }
        }
    }

    func clear(_ transfer: StudioImageTransfer) {
        lock.withLock {
            guard active == transfer else { return }
            active = nil
            try? FileManager.default.removeItem(at: directory(for: transfer))
        }
    }

    func isStaged(_ file: StudioImageTransferFile) -> Bool {
        let staged = stagedURL(for: file)
        return file.file.matchesSize(at: staged)
            || file.file.matchesSize(at: staged.appendingPathExtension("incoming"))
    }

    func discardStaged(_ file: StudioImageTransferFile) {
        lock.withLock {
            guard active == file.transfer else { return }
            try? FileManager.default.removeItem(at: stagedURL(for: file))
        }
    }

    func takeResumeData(for file: StudioImageTransferFile) -> Data? {
        lock.withLock {
            guard active == file.transfer else { return nil }
            let url = resumeURL(for: file)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let size = try? LocalFileStore.checkedFileSize(url, maximumBytes: Self.maximumResumeDataBytes),
                  size > 0, let data = try? Data(contentsOf: url),
                  let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let properties = decoded as? [String: Any], !properties.isEmpty else { return nil }
            return data
        }
    }

    func hasResumeData(for file: StudioImageTransferFile) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(for: file).path)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let file = StudioImageTransferFile(downloadTask) else { return }
        let percent = Int(min(100, max(0, Double(totalBytesWritten) / Double(file.file.bytes) * 100)))
        let changed = lock.withLock {
            guard active == file.transfer, reportedPercent[file.file.name] != percent else { return false }
            reportedPercent[file.file.name] = percent
            return true
        }
        if changed { deliver?(.progress(file, Double(percent) / 100)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let transferFile = StudioImageTransferFile(downloadTask) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  [200, 206].contains(response.statusCode) else { throw URLError(.badServerResponse) }
            try stage(transferFile, from: location, response: response)
            deliver?(.staged(transferFile))
        } catch is CancellationError {
            return
        } catch {
            deliver?(.failed(transferFile, error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let file = StudioImageTransferFile(task) else { return }
        if !file.usedResumeData || task.countOfBytesReceived > 0,
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !data.isEmpty, data.count <= Self.maximumResumeDataBytes {
            do {
                try lock.withLock {
                    guard active == file.transfer else { return }
                    try prepareDirectory(for: file.transfer)
                    try data.write(to: resumeURL(for: file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            } catch { AppDiagnostics.record(error) }
        }
        deliver?(.failed(file, error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        deliver?(.eventsFinished)
    }

    private func directory(for transfer: StudioImageTransfer) -> URL {
        Self.storage.appending(path: transfer.id.uuidString, directoryHint: .isDirectory)
    }

    private func stagedURL(for file: StudioImageTransferFile) -> URL {
        directory(for: file.transfer).appending(path: file.file.name + ".staged", directoryHint: .notDirectory)
    }

    private func resumeURL(for file: StudioImageTransferFile) -> URL {
        directory(for: file.transfer).appending(path: file.file.name + ".resume", directoryHint: .notDirectory)
    }

    private func prepareDirectory(for transfer: StudioImageTransfer) throws {
        var directory = directory(for: transfer)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func stage(_ file: StudioImageTransferFile, from source: URL, response: HTTPURLResponse) throws {
        let size = try LocalFileStore.checkedFileSize(source, maximumBytes: Int.max)
        guard Int64(size) == file.file.bytes else { throw URLError(.cannotDecodeContentData) }
        let contentType = response.mimeType?.lowercased() ?? ""
        let expectedSize = response.statusCode == 200 ? response.expectedContentLength :
            response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) } ?? -1
        guard !contentType.hasPrefix("text/"), contentType != "application/json", !contentType.hasSuffix("+json"),
              expectedSize <= 0 || Int64(size) == expectedSize else {
            throw URLError(.cannotDecodeContentData)
        }
        try lock.withLock {
            guard active == file.transfer else { throw CancellationError() }
            try prepareDirectory(for: file.transfer)
            let staged = stagedURL(for: file)
            try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: file.file.bytes)
            if !file.file.isPresent && !isStaged(file) {
                let manager = FileManager.default
                let incoming = staged.appendingPathExtension("incoming")
                try manager.moveItem(at: source, to: incoming)
                // The move can preserve the URLSession temporary file's protection class.
                try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                           ofItemAtPath: incoming.path)
                try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: file.file.bytes)
            }
            try? FileManager.default.removeItem(at: resumeURL(for: file))
        }
    }

    func validateAndInstall(_ transferFile: StudioImageTransferFile, checkpoint: (Int) async throws -> Void) async throws {
        let source = stagedURL(for: transferFile)
        let file = transferFile.file
        try Task.checkCancellation()
        try lock.withLock {
            guard active == transferFile.transfer else { throw CancellationError() }
            try StudioImageFileValidation.recoverStagedFile(at: source, expectedBytes: file.bytes)
        }
        let size = try LocalFileStore.checkedFileSize(source, maximumBytes: Int.max)
        guard size == Int(file.bytes) else {
            throw MediaGenerationKitError.hashMismatch(file.name)
        }
        if let expected = file.sha256 {
            let actual = try await StudioImageFileValidation.digest(at: source, expectedBytes: file.bytes, checkpoint: checkpoint)
            guard actual == expected else { throw MediaGenerationKitError.hashMismatch(file.name) }
        } else {
            try await checkpoint(100)
        }
        try lock.withLock {
            try Task.checkCancellation()
            guard active == transferFile.transfer else { throw CancellationError() }
            guard let root = MediaGenerationEnvironment.default.externalUrls.first, root.isFileURL else {
                throw MediaGenerationKitError.invalidModelsDirectory
            }
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(file.name)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: source)
            } else {
                try manager.moveItem(at: source, to: destination)
            }
        }
    }
}
