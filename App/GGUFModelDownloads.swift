import CryptoKit
import Foundation
import Observation
import Security

enum GGUFHub {
    struct Repository: Decodable, Identifiable, Sendable {
        let id: String
    }

    struct File: Codable, Equatable, Identifiable, Sendable {
        let repository: String
        let revision: String
        let name: String
        let bytes: Int64
        let sha256: String
        var id: String { repository + "/" + revision + "/" + name }
        var isCatalogMiniCPM: Bool {
            repository == GGUFHub.miniCPM.repository && name == GGUFHub.miniCPM.name &&
                bytes == GGUFHub.miniCPM.bytes && sha256 == GGUFHub.miniCPM.sha256
        }
    }

    static let miniCPM = File(repository: "openbmb/MiniCPM5-1B-GGUF",
                              revision: "5385560dd3e232bcc3577fd9442c332cad2facbd",
                              name: "MiniCPM5-1B-Q4_K_M.gguf", bytes: 688_065_920,
                              sha256: "81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa")

    enum Failure: Error {
        case request, credentials, invalidHash

        var message: String {
            switch self {
            case .request: "Kunne ikke hente modeller fra Hugging Face. Tjek forbindelsen og prøv igen."
            case .credentials: "Modellen kræver adgang på Hugging Face. Acceptér vilkårene dér, og gem en læsenøgle."
            case .invalidHash: "Den hentede model stemmer ikke med originalen. Hent den igen."
            }
        }
    }

    private struct ModelInfo: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let sha256: String }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        let sha: String
        let siblings: [Sibling]
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let origin = URL(string: "https://huggingface.co")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private static func repoComponents(_ value: String) -> [String]? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({
            (1...96).contains($0.count) && $0 != "." && $0 != ".." &&
                $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || [45, 46, 95].contains($0) }
        }) else { return nil }
        return parts
    }

    static func search(_ query: String) async throws -> [Repository] {
        var url = URLComponents(url: origin.appending(path: "api/models"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "search", value: query), .init(name: "filter", value: "gguf"),
                          .init(name: "limit", value: "25")]
        let results: [Repository] = try await json(url.url!)
        return results.filter { repoComponents($0.id) != nil }
    }

    static func files(in repository: String) async throws -> [File] {
        guard let path = repoComponents(repository) else { throw Failure.request }
        let base = path.reduce(origin.appending(path: "api/models")) { $0.appending(component: $1) }
        var url = URLComponents(url: base.appending(path: "revision/main"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "blobs", value: "true")]
        let info: ModelInfo = try await json(url.url!)
        guard validHex(info.sha, length: 40) else { throw Failure.request }
        return info.siblings.compactMap { sibling in
            guard GGUFPhoneModel.validFileName(sibling.rfilename),
                  let size = sibling.size, (24...GGUFPhoneModel.maximumBytes).contains(size),
                  let hash = sibling.lfs?.sha256, validHex(hash, length: 64) else { return nil }
            return File(repository: repository, revision: info.sha, name: sibling.rfilename, bytes: size, sha256: hash.lowercased())
        }.sorted { lhs, rhs in
            let left = lhs.name.localizedCaseInsensitiveContains("Q4_K_M")
            let right = rhs.name.localizedCaseInsensitiveContains("Q4_K_M")
            return left == right ? lhs.bytes < rhs.bytes : left
        }
    }

    private static func validHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func json<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        if let token = GGUFHubKey.load() { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.request }
        if [401, 403].contains(http.statusCode) { throw Failure.credentials }
        guard http.statusCode == 200, data.count <= 2_000_000 else { throw Failure.request }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func signedLink(for file: File) async throws -> URL {
        guard let path = repoComponents(file.repository), validHex(file.revision, length: 40),
              GGUFPhoneModel.validFileName(file.name) else { throw Failure.request }
        let base = path.reduce(origin) { $0.appending(component: $1) }
        let url = base.appending(path: "resolve").appending(component: file.revision).appending(component: file.name)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let token = GGUFHubKey.load()
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.request }
        if [401, 403].contains(http.statusCode) { throw Failure.credentials }
        if http.statusCode == 200, token == nil { return url }
        guard (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL, permittedHost(target) else {
            throw Failure.request
        }
        return target
    }

    static func permittedHost(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }
}

enum GGUFHubKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "FadedAI Hugging Face",
         kSecAttrAccount as String: "read"]
    }

    static func load() -> String? {
        var filter = query
        filter[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(filter as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("hf_"), CloudModelKey.isValid(key) else { throw APIError.input }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}

@MainActor @Observable final class GGUFModelDownloads {
    static let shared = GGUFModelDownloads()
    static let backgroundIdentifier = "dk.fadedai.gguf-download"
    private static let pendingKey = "fadedai.gguf.pending"

    struct Pending: Codable, Equatable, Sendable {
        let uuid: UUID
        let file: GGUFHub.File
        var installationID: UUID { file.isCatalogMiniCPM ? GGUFPhoneModel.miniCPMFolder : uuid }
    }

    private(set) var pending: Pending?
    private(set) var progress: Double?
    private(set) var interrupted = false
    private(set) var isPausing = false
    private(set) var notice: String?
    private(set) var noticeFile: GGUFHub.File?
    private(set) var revision = 0
    private let delegate = GGUFDownloadDelegate()
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private lazy var session: URLSession = {
        delegate.deliver = { [weak self] event in
            DispatchQueue.main.async { self?.receive(event) }
        }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.pendingKey),
           let saved = try? JSONDecoder().decode(Pending.self, from: data) {
            pending = saved
            delegate.track(saved)
        }
    }

    func activate() {
        guard let pending else { return }
        let downloadSession = session
        Task {
            let items = await downloadSession.allTasks
            guard self.pending == pending, preparing == nil else { return }
            if GGUFPhoneModel.installed(pending.installationID) != nil || GGUFPhoneModel.installed(pending.uuid) != nil {
                clear(pending, notice: "Modellen er klar på iPhone.")
            } else if !items.contains(where: { $0.taskDescription == pending.uuid.uuidString }) {
                interrupted = true
            }
        }
    }

    func start(_ file: GGUFHub.File) {
        guard pending == nil else { return }
        noticeFile = file
        if file.isCatalogMiniCPM, GGUFPhoneModel.installed(GGUFPhoneModel.miniCPMFolder) != nil {
            notice = "MiniCPM5 er allerede hentet."
            return
        }
        guard PhoneModels.hasDownloadSpace(bytes: file.bytes + 100_000_000) else {
            notice = "Der er for lidt ledig plads til modellen."
            return
        }
        let entry = Pending(uuid: UUID(), file: file)
        pending = entry
        delegate.track(entry)
        UserDefaults.standard.set(try? JSONEncoder().encode(entry), forKey: Self.pendingKey)
        enqueue(entry)
    }

    func resume() {
        guard interrupted, !isPausing, preparing == nil, let pending else { return }
        enqueue(pending)
    }

    func pause() {
        guard let pending, !isPausing, !interrupted else { return }
        isPausing = true; preparing?.cancel(); notice = "Gemmer downloadposition…"
        Task {
            for task in await session.allTasks where task.taskDescription == pending.uuid.uuidString {
                if let download = task as? URLSessionDownloadTask {
                    let data: Data? = await withCheckedContinuation { continuation in download.cancel { continuation.resume(returning: $0) } }
                    if let data { delegate.saveResumeData(data, id: pending.uuid) }
                } else { task.cancel() }
            }
            guard self.pending == pending else { return }
            isPausing = false; interrupted = true
            notice = "Hentningen er på pause. Tryk Fortsæt. Serveren afgør, om den afbrudte fil kan fortsættes fra samme sted."
        }
    }

    func cancel() {
        guard let pending else { return }
        preparing?.cancel()
        preparing = nil
        let downloadSession = session
        clear(pending, notice: "Download stoppet.")
        Task {
            for task in await downloadSession.allTasks where task.taskDescription == pending.uuid.uuidString {
                task.cancel()
            }
        }
    }

    private func enqueue(_ entry: Pending) {
        interrupted = false
        noticeFile = entry.file
        notice = nil
        preparing = Task {
            defer { if pending == entry { preparing = nil } }
            do {
                let task: URLSessionDownloadTask
                if let data = delegate.takeResumeData(entry.uuid) {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    progress = 0
                    let url = try await GGUFHub.signedLink(for: entry.file)
                    try Task.checkCancellation()
                    task = session.downloadTask(with: url)
                }
                guard pending == entry, !Task.isCancelled else { task.cancel(); return }
                task.taskDescription = entry.uuid.uuidString
                task.resume()
            } catch is CancellationError {
                return
            } catch {
                guard pending == entry else { return }
                interrupted = true
                notice = (error as? GGUFHub.Failure)?.message ?? GGUFHub.Failure.request.message
            }
        }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        _ = session
    }

    func notifyCatalogChange() { revision += 1 }

    private func receive(_ event: GGUFDownloadDelegate.Event) {
        if case .finishedEvents = event {
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
            return
        }
        guard let pending else { return }
        switch event {
        case let .progress(id, value) where id == pending.uuid:
            progress = max(progress ?? 0, value)
        case let .installed(id) where id == pending.uuid:
            clear(pending, notice: "Modellen er klar på iPhone.")
        case let .failed(id, message) where id == pending.uuid:
            interrupted = true
            notice = message
        default:
            break
        }
    }

    private func clear(_ entry: Pending, notice: String) {
        delegate.track(nil)
        _ = delegate.takeResumeData(entry.uuid)
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        pending = nil
        progress = nil
        interrupted = false
        isPausing = false
        noticeFile = entry.file
        self.notice = notice
        revision += 1
    }
}

private final class GGUFDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(UUID, Double), installed(UUID), failed(UUID, String), finishedEvents
    }

    var deliver: ((Event) -> Void)?
    private let lock = NSLock()
    private var active: GGUFModelDownloads.Pending?

    func track(_ entry: GGUFModelDownloads.Pending?) { lock.withLock { active = entry } }

    private func resumeURL(_ id: UUID) -> URL {
        GGUFPhoneModel.root.appending(component: ".resume-" + id.uuidString)
    }

    func takeResumeData(_ id: UUID) -> Data? {
        lock.withLock {
            let path = resumeURL(id)
            defer { try? FileManager.default.removeItem(at: path) }
            return try? Data(contentsOf: path)
        }
    }

    func saveResumeData(_ data: Data, id: UUID) {
        lock.withLock {
            guard active?.uuid == id, ModelTransferPolicy.keepResumeData(bytes: data.count, status: nil) else { return }
            try? FileManager.default.createDirectory(at: GGUFPhoneModel.root, withIntermediateDirectories: true)
            try? data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = UUID(uuidString: downloadTask.taskDescription ?? ""),
              let expected = lock.withLock({ active?.uuid == id ? active?.file.bytes : nil }) else { return }
        guard let value = ModelTransferPolicy.progress(written: totalBytesWritten, expected: expected) else { downloadTask.cancel(); return }
        deliver?(.progress(id, value))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = lock.withLock({ active }), entry.uuid.uuidString == downloadTask.taskDescription else { return }
        do {
            guard let http = downloadTask.response as? HTTPURLResponse,
                  [200, 206].contains(http.statusCode), GGUFHub.permittedHost(http.url),
                  try GGUFPhoneModel.fileSize(location) == entry.file.bytes else { throw GGUFHub.Failure.request }
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                guard lock.withLock({ active == entry }) else { return }
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", Int($0)) }.joined()
            guard digest == entry.file.sha256 else { throw GGUFHub.Failure.invalidHash }
            try lock.withLock {
                guard active == entry else { throw CancellationError() }
                try GGUFPhoneModel.put(location, uuid: entry.installationID, filename: entry.file.name, moving: true)
            }
            deliver?(.installed(entry.uuid))
        } catch is CancellationError {
            return
        } catch {
            deliver?(.failed(entry.uuid, (error as? GGUFHub.Failure)?.message ?? "Modelfilen kunne ikke gemmes."))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = UUID(uuidString: task.taskDescription ?? "") else { return }
        let tracked = lock.withLock {
            guard active?.uuid == id else { return false }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if [401,403,416].contains(status ?? 0) { try? FileManager.default.removeItem(at: resumeURL(id)) }
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               ModelTransferPolicy.keepResumeData(bytes: data.count, status: status) {
                try? FileManager.default.createDirectory(at: GGUFPhoneModel.root, withIntermediateDirectories: true)
                try? data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return true
        }
        if tracked { deliver?(.failed(id, "Download afbrudt. Tryk Fortsæt for at prøve igen.")) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { deliver?(.finishedEvents) }
}
