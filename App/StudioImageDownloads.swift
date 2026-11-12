import CryptoKit
import Foundation
import MediaGenerationKit
import Observation

struct StudioImageDownloadFile: Sendable {
    let name: String
    let sha256: String?

    var isPresent: Bool {
        MediaGenerationEnvironment.default.externalUrls.contains { root in
            let file = root.appendingPathComponent(name)
            return ((try? LocalFileStore.checkedFileSize(file, maximumBytes: Int.max)) ?? 0) > 0
        }
    }
}

private struct StudioImageTransfer: Equatable, Sendable {
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
}

private struct StudioImageTransferFile: Sendable {
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

@MainActor @Observable final class StudioImageDownloads {
    static let shared = StudioImageDownloads()
    static let backgroundIdentifier = "dk.fadedai.image-model-download"
    private static let pendingKey = "offline.studio.pendingImageDownload"

    private(set) var activeModel: StudioImageModel?
    private(set) var progress: Double?
    private(set) var notice: String?
    private(set) var isInterrupted = false
    private var transfer: StudioImageTransfer?
    private var fractions: [String: Double] = [:]
    private var verifiedFiles = Set<String>()
    private var blockedFiles = Set<String>()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var validation: Task<Void, Never>?
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    private var backgroundCompletion: (() -> Void)?
    private let delegate = StudioImageDownloadDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        delegate.deliver = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    private init() {
        if let identifier = UserDefaults.standard.string(forKey: Self.pendingKey),
           let transfer = StudioImageTransfer(identifier) {
            track(transfer)
        }
    }

    func activate() {
        if transfer != nil { _ = session }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if active {
            reconcile()
        } else {
            validation?.cancel()
        }
    }

    func start(_ model: StudioImageModel) {
        guard transfer == nil, !model.isInstalled else { return }
        guard PhoneModels.hasDownloadSpace(bytes: model.minimumFreeBytes) else {
            notice = "Der er for lidt ledig plads. Frigør plads, og prøv igen."
            return
        }
        let missing = model.downloadFiles.filter { !$0.isPresent }
        guard !missing.isEmpty else {
            notice = "Telefonen kunne ikke åbne billedmodellen. Genåbn FadedAI, og prøv igen."
            return
        }
        let transfer = StudioImageTransfer(model: model)
        track(transfer)
        UserDefaults.standard.set(transfer.identifier, forKey: Self.pendingKey)
        enqueue(missing, for: transfer)
    }

    func resume() {
        guard let transfer, isInterrupted else { return }
        isInterrupted = false
        notice = nil
        blockedFiles.removeAll()
        let missing = transfer.model.downloadFiles.filter { file in
            !file.isPresent && !delegate.isStaged(.init(transfer: transfer, file: file))
        }
        for file in missing { fractions[file.name] = nil }
        updateProgress(for: transfer)
        enqueue(missing, for: transfer)
        reconcile()
    }

    private func enqueue(_ files: [StudioImageDownloadFile], for transfer: StudioImageTransfer) {
        let host = URL(string: "https://static.libnnc.org")!
        for file in files {
            let transferFile = StudioImageTransferFile(transfer: transfer, file: file)
            let resumeData = delegate.takeResumeData(for: transferFile)
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: host.appendingPathComponent(file.name))
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session.downloadTask(with: request)
            }
            let suffix = resumeData == nil ? "" : ":resume"
            task.taskDescription = "\(transfer.identifier):\(file.name)\(suffix)"
            task.resume()
        }
    }

    func cancel() {
        guard let transfer else { return }
        clear(transfer, notice: "Download stoppet.")
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }

    private func track(_ transfer: StudioImageTransfer) {
        self.transfer = transfer
        delegate.track(transfer)
        activeModel = transfer.model
        verifiedFiles = Set(transfer.model.downloadFiles.filter(\.isPresent).map(\.name))
        fractions = Dictionary(uniqueKeysWithValues: verifiedFiles.map { ($0, 1) })
        blockedFiles.removeAll()
        progress = nil
        notice = nil
        isInterrupted = false
    }

    private func receive(_ event: StudioImageDownloadDelegate.Event) {
        switch event {
        case let .progress(file, fraction):
            guard file.transfer == transfer else { return }
            let previous = fractions[file.file.name] ?? 0
            guard fraction > previous else { return }
            fractions[file.file.name] = fraction
            updateProgress(for: file.transfer)
        case let .staged(file):
            guard file.transfer == transfer else { return }
            isInterrupted = false
            notice = nil
            receive(.progress(file, 1))
            reconcile()
        case let .failed(file, error):
            guard file.transfer == transfer else { return }
            AppDiagnostics.record(error)
            if isForeground, file.usedResumeData, !delegate.hasResumeData(for: file),
               !file.file.isPresent, !delegate.isStaged(file) {
                fractions[file.file.name] = nil
                enqueue([file.file], for: file.transfer)
            }
            reconcile()
        case .eventsFinished:
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
            reconcile()
        }
    }

    private func updateProgress(for transfer: StudioImageTransfer) {
        progress = fractions.isEmpty ? nil : fractions.values.reduce(0, +) / Double(transfer.model.downloadFiles.count)
    }

    private func reconcile() {
        guard isForeground, let transfer, validation == nil else { return }
        let files = transfer.model.downloadFiles
        for file in files where file.isPresent {
            verifiedFiles.insert(file.name)
            fractions[file.name] = 1
        }
        updateProgress(for: transfer)
        if verifiedFiles.count == files.count {
            if transfer.model.isInstalled {
                finish(transfer)
            } else {
                clear(transfer, notice: "Telefonen kunne ikke åbne billedmodellen. Genåbn FadedAI, og prøv igen.")
            }
            return
        }
        let staged = files.filter { file in
            !verifiedFiles.contains(file.name) && !blockedFiles.contains(file.name)
                && delegate.isStaged(.init(transfer: transfer, file: file))
        }
        if !staged.isEmpty {
            for file in staged { fractions[file.name] = 1 }
            updateProgress(for: transfer)
            validation = Task.detached(priority: .utility) { [weak self, delegate] in
                for file in staged {
                    let candidate = StudioImageTransferFile(transfer: transfer, file: file)
                    do {
                        try delegate.validateAndInstall(candidate)
                    } catch is CancellationError {
                        break
                    } catch let error as MediaGenerationKitError {
                        if case .hashMismatch = error {
                            delegate.discardStaged(candidate)
                        } else {
                            await self?.blockValidation(for: candidate)
                        }
                        AppDiagnostics.record(error)
                    } catch {
                        guard !Task.isCancelled else { break }
                        await self?.blockValidation(for: candidate)
                        AppDiagnostics.record(error)
                    }
                }
                await self?.validationEnded()
            }
        } else {
            inspectRemainingTasks(for: transfer)
        }
    }

    private func validationEnded() {
        validation = nil
        reconcile()
    }

    private func blockValidation(for file: StudioImageTransferFile) {
        if transfer == file.transfer { blockedFiles.insert(file.file.name) }
    }

    private func inspectRemainingTasks(for transfer: StudioImageTransfer) {
        guard reconciliation == nil else { return }
        reconciliation = Task {
            // Let the restored session deliver its queued file events before exposing Resume.
            try? await Task.sleep(for: .seconds(2))
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            reconciliation = nil
            guard isForeground else { return }
            guard self.transfer == transfer else { reconcile(); return }
            guard validation == nil,
                  !tasks.contains(where: { task in
                      task.state != .completed && task.state != .canceling && StudioImageTransferFile(task)?.transfer == transfer
                  }) else { return }
            if transfer.model.downloadFiles.contains(where: { file in
                !verifiedFiles.contains(file.name) && !blockedFiles.contains(file.name)
                    && delegate.isStaged(.init(transfer: transfer, file: file))
            }) {
                reconcile()
            } else {
                isInterrupted = true
                notice = blockedFiles.isEmpty
                    ? "Download er sat på pause. Fortsæt for at hente de filer, der mangler."
                    : "Kontrollen af billedmodellen blev afbrudt. Tjek den ledige plads, og fortsæt."
            }
        }
    }

    private func finish(_ transfer: StudioImageTransfer) {
        clear(transfer, notice: "\(transfer.model.title) er klar på telefonen.")
        Task {
            await JobNotifications.shared.completed(kind: "image-model", server: "phone", id: transfer.id.uuidString,
                                                     title: "Din lokale billedmodel er klar!")
        }
    }

    private func clear(_ transfer: StudioImageTransfer, notice: String) {
        validation?.cancel()
        delegate.clear(transfer)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        self.transfer = nil
        activeModel = nil
        fractions = [:]
        verifiedFiles = []
        blockedFiles.removeAll()
        progress = nil
        isInterrupted = false
        self.notice = notice
        session.getAllTasks { tasks in
            for task in tasks where StudioImageTransferFile(task)?.transfer == transfer { task.cancel() }
        }
    }
}

private final class StudioImageDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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

    func track(_ transfer: StudioImageTransfer) {
        lock.withLock { active = transfer }
    }

    func clear(_ transfer: StudioImageTransfer) {
        lock.withLock {
            guard active == transfer else { return }
            active = nil
            try? FileManager.default.removeItem(at: directory(for: transfer))
        }
    }

    func isStaged(_ file: StudioImageTransferFile) -> Bool {
        ((try? LocalFileStore.checkedFileSize(stagedURL(for: file), maximumBytes: Int.max)) ?? 0) > 0
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
        guard totalBytesExpectedToWrite > 0, let file = StudioImageTransferFile(downloadTask) else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        deliver?(.progress(file, floor(fraction * 100) / 100))
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
        guard size > 0 else { throw URLError(.zeroByteResource) }
        let contentType = response.mimeType?.lowercased() ?? ""
        let expectedSize = response.statusCode == 200 ? response.expectedContentLength :
            response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) } ?? -1
        // Catalog files with no hash must at least have a complete binary response and a known length.
        guard !contentType.hasPrefix("text/"), contentType != "application/json", !contentType.hasSuffix("+json"),
              expectedSize > 0 ? Int64(size) == expectedSize : file.file.sha256 != nil else {
            throw URLError(.cannotDecodeContentData)
        }
        try lock.withLock {
            guard active == file.transfer else { throw CancellationError() }
            try prepareDirectory(for: file.transfer)
            let staged = stagedURL(for: file)
            if !file.file.isPresent && !isStaged(file) {
                let manager = FileManager.default
                let incoming = staged.appendingPathExtension("incoming")
                try? manager.removeItem(at: incoming)
                defer { try? manager.removeItem(at: incoming) }
                try manager.moveItem(at: source, to: incoming)
                // The move can preserve the URLSession temporary file's protection class.
                try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                           ofItemAtPath: incoming.path)
                try manager.moveItem(at: incoming, to: staged)
            }
            try? FileManager.default.removeItem(at: resumeURL(for: file))
        }
    }

    func validateAndInstall(_ transferFile: StudioImageTransferFile) throws {
        let source = stagedURL(for: transferFile)
        let file = transferFile.file
        try Task.checkCancellation()
        if let expected = file.sha256 {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw MediaGenerationKitError.hashMismatch(file.name) }
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
