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

    init?(_ task: URLSessionTask) {
        guard let description = task.taskDescription, let separator = description.lastIndex(of: ":"),
              let transfer = StudioImageTransfer(String(description[..<separator])),
              let file = transfer.model.downloadFiles.first(where: { $0.name == description[description.index(after: separator)...] })
        else { return nil }
        self.transfer = transfer
        self.file = file
    }
}

@MainActor @Observable final class StudioImageDownloads {
    static let shared = StudioImageDownloads()
    static let backgroundIdentifier = "dk.fadedai.image-model-download"
    private static let pendingKey = "offline.studio.pendingImageDownload"

    private(set) var activeModel: StudioImageModel?
    private(set) var progress: Double?
    private(set) var notice: String?
    private var transfer: StudioImageTransfer?
    private var fractions: [String: Double] = [:]
    private var verifiedFiles = Set<String>()
    private var pendingNotification: Task<Void, Never>?
    private var backgroundCompletion: (() -> Void)?
    private let delegate = StudioImageDownloadDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        delegate.deliver = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    private init() {
        if let identifier = UserDefaults.standard.string(forKey: Self.pendingKey),
           let transfer = StudioImageTransfer(identifier) {
            track(transfer)
        }
    }

    func activate() {
        guard let transfer else { return }
        // Allow the background session to replay events from before this process started.
        let session = self.session
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            guard self.transfer == transfer,
                  !delegate.isValidating(transfer),
                  !tasks.contains(where: { StudioImageTransferFile($0)?.transfer == transfer }) else { return }
            if transfer.model.isInstalled {
                finish(transfer)
            } else {
                clear(transfer, notice: "Download blev afbrudt. Tryk Hent billedmodel for at fortsætte.")
            }
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
        let host = URL(string: "https://static.libnnc.org")!
        for file in missing {
            let task = session.downloadTask(with: host.appendingPathComponent(file.name))
            task.taskDescription = "\(transfer.identifier):\(file.name)"
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
        progress = nil
        notice = nil
    }

    private func receive(_ event: StudioImageDownloadDelegate.Event) {
        switch event {
        case let .progress(file, fraction):
            guard file.transfer == transfer else { return }
            let previous = fractions[file.file.name] ?? 0
            guard fraction > previous else { return }
            fractions[file.file.name] = fraction
            progress = fractions.values.reduce(0, +) / Double(file.transfer.model.downloadFiles.count)
        case let .completed(file, error):
            guard file.transfer == transfer else { return }
            if let error {
                AppDiagnostics.record(error)
                clear(file.transfer, notice: "Billedmodellen kunne ikke hentes. Tjek internet og ledig plads, og prøv igen.")
            } else {
                verifiedFiles.insert(file.file.name)
                receive(.progress(file, 1))
                if verifiedFiles.count == file.transfer.model.downloadFiles.count {
                    if file.transfer.model.isInstalled {
                        finish(file.transfer)
                    } else {
                        clear(file.transfer, notice: "Telefonen kunne ikke åbne billedmodellen. Genåbn FadedAI, og prøv igen.")
                    }
                }
            }
        case .eventsFinished:
            guard let completion = backgroundCompletion else { return }
            backgroundCompletion = nil
            let notification = pendingNotification
            Task { @MainActor in
                await notification?.value
                completion()
            }
        }
    }

    private func finish(_ transfer: StudioImageTransfer) {
        clear(transfer, notice: "\(transfer.model.title) er klar på telefonen.")
        pendingNotification = Task {
            await JobNotifications.shared.completed(kind: "image-model", server: "phone", id: transfer.id.uuidString,
                                                     title: "Din lokale billedmodel er klar!")
        }
    }

    private func clear(_ transfer: StudioImageTransfer, notice: String) {
        delegate.track(nil)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        self.transfer = nil
        activeModel = nil
        fractions = [:]
        verifiedFiles = []
        progress = nil
        self.notice = notice
        session.getAllTasks { tasks in
            for task in tasks where StudioImageTransferFile(task)?.transfer == transfer { task.cancel() }
        }
    }
}

private final class StudioImageDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(StudioImageTransferFile, Double)
        case completed(StudioImageTransferFile, Error?)
        case eventsFinished
    }

    var deliver: (@Sendable (Event) -> Void)?
    private let lock = NSLock()
    private var active: StudioImageTransfer?
    private var validating: StudioImageTransfer?

    func track(_ transfer: StudioImageTransfer?) {
        lock.withLock { active = transfer }
    }

    func isValidating(_ transfer: StudioImageTransfer) -> Bool {
        lock.withLock { validating == transfer }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let file = StudioImageTransferFile(downloadTask) else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        deliver?(.progress(file, floor(fraction * 100) / 100))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let transferFile = StudioImageTransferFile(downloadTask) else { return }
        lock.withLock { validating = transferFile.transfer }
        defer { lock.withLock { validating = nil } }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  [200, 206].contains(response.statusCode) else { throw URLError(.badServerResponse) }
            try install(transferFile, from: location, response: response)
            deliver?(.completed(transferFile, nil))
        } catch {
            deliver?(.completed(transferFile, error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let file = StudioImageTransferFile(task) else { return }
        deliver?(.completed(file, error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        deliver?(.eventsFinished)
    }

    private func install(_ transferFile: StudioImageTransferFile, from source: URL, response: HTTPURLResponse) throws {
        let file = transferFile.file
        let size = try LocalFileStore.checkedFileSize(source, maximumBytes: Int.max)
        guard size > 0 else { throw URLError(.zeroByteResource) }
        if let expected = file.sha256 {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                guard lock.withLock({ active == transferFile.transfer }) else { throw CancellationError() }
                hash.update(data: data)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw MediaGenerationKitError.hashMismatch(file.name) }
        } else {
            // The catalog provides no hash for the FLUX VAE. Validate the complete binary response.
            let expectedSize = response.statusCode == 200 ? response.expectedContentLength :
                response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) } ?? -1
            guard !(response.mimeType ?? "").hasPrefix("text/"), response.mimeType != "application/json",
                  expectedSize <= 0 || Int64(size) == expectedSize else { throw URLError(.cannotDecodeContentData) }
        }
        try lock.withLock {
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
