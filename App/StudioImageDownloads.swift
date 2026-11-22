import Foundation
import MediaGenerationKit
import Observation

struct StudioImageDownloadFile: Sendable {
    let name: String
    let bytes: Int64
    let sha256: String?

    var isPresent: Bool {
        MediaGenerationEnvironment.default.externalUrls.contains { root in
            matchesSize(at: root.appendingPathComponent(name))
        }
    }

    func matchesSize(at url: URL) -> Bool {
        (try? LocalFileStore.checkedFileSize(url, maximumBytes: Int.max)) == Int(bytes)
    }
}

@MainActor @Observable final class StudioImageDownloads {
    static let shared = StudioImageDownloads()
    static let backgroundIdentifier = "dk.fadedai.image-model-download"
    private static let pendingKey = "offline.studio.pendingImageDownload"
    private static let pausedKey = "offline.studio.pausedImageDownload"
    private static let pauseNotice = "Hentningen er på pause. Filer, der er hentet færdigt, ligger klar på telefonen."

    private enum RestoredValidation {
        case allowed, requiresConfirmation, paused
    }

    private(set) var activeModel: StudioImageModel?
    var transferID: UUID? { transfer?.id }
    private(set) var progress: Double?
    private(set) var validationLabel: String?
    private(set) var notice: String?
    private(set) var isInterrupted = false
    private(set) var isUserPaused = false
    var isWaitingForModelCheck: Bool { restoredValidation == .paused }
    private var restoredValidation: RestoredValidation = .allowed
    private var modelRevision = 0
    private var transfer: StudioImageTransfer?
    private var fractions: [String: Double] = [:]
    private var verifiedFiles = Set<String>()
    private var blockedFiles = Set<String>()
    private var invalidFiles = Set<String>()
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var validation: Task<Void, Never>?
    @ObservationIgnored private let validationGate = StudioImageValidationGate()
    @ObservationIgnored private var reconciliation: Task<Void, Never>?
    @ObservationIgnored private var taskUpdate: Task<Void, Never>?
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
            if UserDefaults.standard.string(forKey: Self.pausedKey) == transfer.identifier {
                isUserPaused = true
                isInterrupted = true
                notice = Self.pauseNotice
            } else if transfer.model == .fluxKlein { restoredValidation = .requiresConfirmation }
        }
    }

    func activate() {
        guard let transfer else { return }
        _ = session
        if isUserPaused { updateTasks(for: transfer) }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        validationGate.setActive(active && !isUserPaused)
        if active { reconcile() }
    }

    func start(_ model: StudioImageModel) {
        guard transfer == nil, !model.isInstalled else { return }
        guard model != .fluxKlein || ProcessInfo.processInfo.physicalMemory >= model.minimumWorkingMemoryMiB * 1_048_576 else {
            notice = "Denne iPhone har for lidt arbejdshukommelse til FLUX. Vælg Stable Diffusion eller brug din PC."
            return
        }
        guard PhoneModels.hasDownloadSpace(bytes: model.minimumFreeBytes) else {
            notice = "Du skal have ca. \(ModelDiskStorage.gigabytes(model.minimumFreeBytes)) fri til de resterende filer og installationen."
            return
        }
        let missing = model.downloadFiles.filter { !$0.isPresent }
        guard !missing.isEmpty else {
            notice = "Telefonen kunne ikke åbne billedmodellen. Genåbn FadedAI, og prøv igen."
            return
        }
        let transfer = StudioImageTransfer(model: model)
        track(transfer)
        validationGate.setActive(isForeground)
        UserDefaults.standard.set(transfer.identifier, forKey: Self.pendingKey)
        enqueue(missing, for: transfer)
    }

    func pause() {
        guard let transfer, !isUserPaused else { return }
        isUserPaused = true
        isInterrupted = true
        restoredValidation = .allowed
        notice = Self.pauseNotice
        UserDefaults.standard.set(transfer.identifier, forKey: Self.pausedKey)
        validationGate.setActive(false)
        updateTasks(for: transfer)
    }

    func resume() {
        guard let transfer, isInterrupted else { return }
        delegate.recoverStagedFiles(for: transfer)
        isUserPaused = false
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        restoredValidation = .allowed
        isInterrupted = false
        notice = nil
        blockedFiles.removeAll()
        invalidFiles.removeAll()
        validationGate.setActive(isForeground)
        updateTasks(for: transfer)
    }

    private func updateTasks(for transfer: StudioImageTransfer) {
        reconciliation?.cancel()
        reconciliation = nil
        taskUpdate?.cancel()
        taskUpdate = Task {
            let tasks = await session.allTasks
            guard !Task.isCancelled, self.transfer == transfer else { return }
            let result = transfer.adjust(tasks, paused: isUserPaused) { file in
                file.isPresent || delegate.isStaged(.init(transfer: transfer, file: file))
            }
            fractions.merge(result.fractions, uniquingKeysWith: max)
            if !isUserPaused {
                for file in result.missing { fractions[file.name] = nil }
                enqueue(result.missing, for: transfer)
            }
            updateProgress(for: transfer)
            taskUpdate = nil
            reconcile()
        }
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

    func isInstalled(_ model: StudioImageModel) -> Bool {
        _ = modelRevision
        return model.isInstalled
    }

    func hasLocalFiles(_ model: StudioImageModel) -> Bool {
        _ = modelRevision
        return !localFiles(for: model, in: imageRoots).isEmpty
    }

    func removeLocalFiles(_ model: StudioImageModel) {
        guard transfer == nil, !LocalCompute.isRunning else {
            notice = "Vent til billedopgaven eller hentningen er færdig."
            return
        }
        let roots = imageRoots
        defer { modelRevision += 1 }
        do {
            for file in localFiles(for: model, in: roots) {
                try ModelDiskStorage.delete(file, within: roots)
            }
            StudioImageProbeHistory.shared.forget(model: model.id)
            notice = "\(model.title) er slettet fra telefonen."
        } catch {
            AppDiagnostics.record(error)
            notice = "Billedmodellen kunne ikke slettes helt. Prøv igen."
        }
    }

    private var imageRoots: [URL] {
        ModelDiskStorage.allowedImageRoots(MediaGenerationEnvironment.default.externalUrls)
    }

    private func localFiles(for model: StudioImageModel, in roots: [URL]) -> [ModelDiskStorage.Item] {
        let shared = Set(StudioImageModel.allCases.filter { $0 != model }.flatMap { $0.downloadFiles.map(\.name) })
        let names = model.downloadFiles.map(\.name).filter { !shared.contains($0) }
        return roots.flatMap { root in
            names.compactMap { name in
                let url = root.appendingPathComponent(name)
                guard let bytes = try? LocalFileStore.checkedFileSize(url, maximumBytes: Int.max) else { return nil }
                return ModelDiskStorage.Item(url: url, name: name, kind: "Billedmodelfil", bytes: Int64(bytes))
            }
        }
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
        invalidFiles.removeAll()
        progress = nil
        notice = nil
        isInterrupted = false
        restoredValidation = .allowed
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
            if !isUserPaused && !isWaitingForModelCheck {
                isInterrupted = false
                notice = nil
            }
            receive(.progress(file, 1))
            reconcile()
        case let .failed(file, error):
            guard file.transfer == transfer else { return }
            AppDiagnostics.record(error)
            if (error as? URLError)?.code == .cannotDecodeContentData { invalidDownload(file) }
            if isForeground, !isUserPaused, taskUpdate == nil, file.usedResumeData, !delegate.hasResumeData(for: file),
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
        let files = transfer.model.downloadFiles
        let received = files.reduce(0.0) { $0 + Double($1.bytes) * (fractions[$1.name] ?? 0) }
        progress = fractions.isEmpty ? nil : received / Double(files.reduce(0) { $0 + $1.bytes })
    }

    private func reconcile() {
        guard isForeground, !isUserPaused, taskUpdate == nil, let transfer, validation == nil else { return }
        let files = transfer.model.downloadFiles
        verifiedFiles = Set(files.filter(\.isPresent).map(\.name))
        for name in verifiedFiles { fractions[name] = 1 }
        updateProgress(for: transfer)
        if verifiedFiles.count == files.count { finish(transfer); return }
        let staged = files.filter { file in
            !verifiedFiles.contains(file.name) && !blockedFiles.contains(file.name)
                && delegate.isStaged(.init(transfer: transfer, file: file))
        }
        // Give the user a chance to stop an unfinished FLUX install after reopening the app.
        // The background session can still finish downloading files while validation waits.
        if restoredValidation == .paused || (restoredValidation == .requiresConfirmation && !staged.isEmpty) {
            restoredValidation = .paused
            isInterrupted = true
            notice = "FLUX blev afbrudt sidst. Fortsæt modelkontrollen, eller stop download."
            return
        }
        if !staged.isEmpty {
            for file in staged { fractions[file.name] = 1 }
            updateProgress(for: transfer)
            validation = Task.detached(priority: .utility) { [weak self, delegate] in
                for file in staged {
                    let candidate = StudioImageTransferFile(transfer: transfer, file: file)
                    do {
                        try await delegate.validateAndInstall(candidate) { percent in
                            guard let self else { throw CancellationError() }
                            try await self.validationCheckpoint(candidate, percent: percent)
                        }
                    } catch is CancellationError {
                        break
                    } catch let error as MediaGenerationKitError {
                        if case .hashMismatch = error {
                            delegate.discardStaged(candidate)
                            await self?.invalidDownload(candidate)
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
        validationLabel = nil
        reconcile()
    }

    private func validationCheckpoint(_ candidate: StudioImageTransferFile, percent: Int) async throws {
        try await validationGate.waitUntilActive()
        guard transfer == candidate.transfer, let index = candidate.transfer.model.downloadFiles.firstIndex(where: {
            $0.name == candidate.file.name
        }) else { throw CancellationError() }
        let label = "Kontrollerer fil \(index + 1) af \(candidate.transfer.model.downloadFiles.count) · \(percent) %"
        if validationLabel != label { validationLabel = label }
    }

    private func blockValidation(for file: StudioImageTransferFile) {
        if transfer == file.transfer { blockedFiles.insert(file.file.name) }
    }

    private func invalidDownload(_ file: StudioImageTransferFile) {
        guard transfer == file.transfer else { return }
        invalidFiles.insert(file.file.name)
        fractions[file.file.name] = nil
        updateProgress(for: file.transfer)
    }

    private func inspectRemainingTasks(for transfer: StudioImageTransfer) {
        guard reconciliation == nil else { return }
        reconciliation = Task {
            // Let the restored session deliver its queued file events before exposing Resume.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            let tasks = await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            reconciliation = nil
            guard isForeground else { return }
            guard self.transfer == transfer else { reconcile(); return }
            guard validation == nil, taskUpdate == nil, !isUserPaused, !isWaitingForModelCheck,
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
                if let index = transfer.model.downloadFiles.firstIndex(where: { invalidFiles.contains($0.name) }) {
                    notice = "Fil \(index + 1) af \(transfer.model.downloadFiles.count) bestod ikke kontrollen. Fortsæt for at hente de manglende filer. De godkendte filer bevares."
                } else if !blockedFiles.isEmpty {
                    notice = "Kontrollen af billedmodellen blev afbrudt. Tjek den ledige plads, og fortsæt."
                } else {
                    notice = "Download er sat på pause. Fortsæt for at hente de filer, der mangler."
                }
            }
        }
    }

    private func finish(_ transfer: StudioImageTransfer) {
        clear(transfer, notice: "\(transfer.model.title) er hentet og kontrolleret.")
        Task {
            await JobNotifications.shared.completed(kind: "image-model", server: "phone", id: transfer.id.uuidString,
                                                     title: "\(transfer.model.title) er hentet")
        }
    }

    private func clear(_ transfer: StudioImageTransfer, notice: String) {
        taskUpdate?.cancel()
        taskUpdate = nil
        isUserPaused = false
        validation?.cancel()
        validationGate.wake()
        validationLabel = nil
        delegate.clear(transfer)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        self.transfer = nil
        activeModel = nil
        fractions = [:]
        verifiedFiles = []
        blockedFiles.removeAll()
        progress = nil
        isInterrupted = false
        restoredValidation = .allowed
        self.notice = notice
        session.getAllTasks { tasks in
            for task in tasks where StudioImageTransferFile(task)?.transfer == transfer { task.cancel() }
        }
    }
}
