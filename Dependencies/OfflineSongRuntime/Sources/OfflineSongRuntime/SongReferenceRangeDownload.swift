// Internal, bounded range downloader for optional song-reference model files.
// Each verified HTTP range is appended only after it has fully downloaded.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SongReferenceRangeFailure: Error, Equatable {
    case invalidConfiguration, incompleteState, identityMismatch, invalidPartialSize
    case unsupportedResponse, unexpectedRange, unexpectedChunkSize, verificationFailed
    case rejectedRedirect, busy
}

/// The verifier must stream-check a digest pinned independently of the response.
/// This downloads only: the caller must separately verify and atomically install
/// the completed model. One in-process transfer per partial is enforced.
struct SongReferenceRangeDownload {
    struct Identity: Codable, Equatable {
        let url: String
        let strongETag: String
        let bytes: Int64
        /// Absolute offset in the source file, and size of that whole file.
        let sourceOffset: Int64
        let sourceBytes: Int64
    }
    let chunkBytes: Int64
    let allowedHosts: Set<String>
    private let protocolClasses: [AnyClass]?

    init(allowedHosts: Set<String>, chunkBytes: Int64 = 4 * 1024 * 1024) {
        self.chunkBytes = chunkBytes
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.protocolClasses = nil
    }
    #if FADEDAI_RANGE_TESTS
    init(allowedHosts: Set<String>, chunkBytes: Int64, protocolClasses: [AnyClass]) {
        self.chunkBytes = chunkBytes
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.protocolClasses = protocolClasses
    }
    #endif

    /// A failed request never invalidates an earlier completed range. In-flight
    /// chunk bytes are stored by URLSession separately until response validation.
    func fetch(url: URL, partial: URL, size: Int64, sourceOffset: Int64 = 0,
               sourceBytes: Int64? = nil, strongETag: String,
               verify: (URL) throws -> Bool) async throws -> URL {
        try Task.checkCancellation()
        let totalSourceBytes = sourceBytes ?? size
        guard Self.allowed(url, hosts: allowedHosts, allowQuery: false),
              size > 0, chunkBytes > 0, chunkBytes <= 16 * 1024 * 1024, partial.isFileURL,
              sourceOffset >= 0, totalSourceBytes > 0, sourceOffset <= totalSourceBytes,
              size <= totalSourceBytes - sourceOffset,
              strongETag.count >= 2, strongETag.utf8.count <= 256,
              strongETag.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }),
              strongETag.hasPrefix("\""), strongETag.hasSuffix("\""),
              !strongETag.hasPrefix("W/") else { throw SongReferenceRangeFailure.invalidConfiguration }
        let lockKey = partial.standardizedFileURL.resolvingSymlinksInPath().path
        guard SongReferenceRangeLocks.acquire(lockKey) else { throw SongReferenceRangeFailure.busy }
        defer { SongReferenceRangeLocks.release(lockKey) }
        let identity = Identity(url: url.absoluteString, strongETag: strongETag, bytes: size,
                                sourceOffset: sourceOffset, sourceBytes: totalSourceBytes)
        let sidecar = partial.appendingPathExtension("identity.json")
        let fm = FileManager.default
        for path in [partial, sidecar] {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw SongReferenceRangeFailure.incompleteState
            }
        }
        let hasPartial = fm.fileExists(atPath: partial.path)
        let hasSidecar = fm.fileExists(atPath: sidecar.path)
        guard !hasPartial || hasSidecar else { throw SongReferenceRangeFailure.incompleteState }
        if hasSidecar {
            try validateRegular(sidecar)
            guard try fileSize(sidecar) <= 4096 else { throw SongReferenceRangeFailure.incompleteState }
            let recorded = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: sidecar))
            guard recorded == identity else { throw SongReferenceRangeFailure.identityMismatch }
            if hasPartial {
                try validateRegular(partial)
            } else {
                // A crash between creating the matching sidecar and partial
                // is recoverable. Never replace a file appearing meanwhile.
                try Data().write(to: partial, options: .withoutOverwriting)
            }
        } else {
            // The sidecar is created first, then the empty partial. If creation
            // fails, remove only the sidecar created by this invocation.
            try JSONEncoder().encode(identity).write(to: sidecar, options: .withoutOverwriting)
            do {
                try Data().write(to: partial, options: .withoutOverwriting)
            } catch {
                try? fm.removeItem(at: sidecar)
                throw error
            }
        }
        var offset = try fileSize(partial)
        guard offset <= size else { throw SongReferenceRangeFailure.invalidPartialSize }
        while offset < size {
            try Task.checkCancellation()
            let length = min(chunkBytes, size - offset)
            let start = sourceOffset + offset
            let end = start + length - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.setValue(strongETag, forHTTPHeaderField: "If-Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let expectedRange = "bytes \(start)-\(end)/\(totalSourceBytes)"
            let chunk = try await SongReferenceRangeChunk.receive(request: request, expectedRange: expectedRange,
                                                     expectedETag: strongETag, expectedBytes: length,
                                                     allowedHosts: allowedHosts, protocolClasses: protocolClasses)
            defer { try? fm.removeItem(at: chunk) }
            try Task.checkCancellation()
            guard try fileSize(chunk) == length else { throw SongReferenceRangeFailure.unexpectedChunkSize }
            try append(chunk: chunk, to: partial, originalSize: offset)
            offset += length
        }
        try Task.checkCancellation()
        if try !verify(partial) {
            // A complete but corrupt partial would otherwise fail forever on
            // retry. Delete only the two files owned by this download.
            try fm.removeItem(at: partial)
            try fm.removeItem(at: sidecar)
            throw SongReferenceRangeFailure.verificationFailed
        }
        try Task.checkCancellation()
        return partial
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let value, value >= 0 else { throw SongReferenceRangeFailure.invalidPartialSize }
        return Int64(value)
    }

    private func validateRegular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SongReferenceRangeFailure.incompleteState
        }
    }

    static func allowed(_ url: URL, hosts: Set<String>, allowQuery: Bool) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              hosts.contains(host), !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, (parts.port == nil || parts.port == 443),
              allowQuery || parts.query == nil else { return false }
        return true
    }

    private func append(chunk: URL, to partial: URL, originalSize: Int64) throws {
        let source = try FileHandle(forReadingFrom: chunk)
        defer { try? source.close() }
        let target = try FileHandle(forWritingTo: partial)
        defer { try? target.close() }
        guard try target.seekToEnd() == UInt64(originalSize) else { throw SongReferenceRangeFailure.invalidPartialSize }
        do {
            while let data = try source.read(upToCount: 64 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try target.write(contentsOf: data)
            }
            try Task.checkCancellation()
            try target.synchronize()
        } catch {
            try? target.truncate(atOffset: UInt64(originalSize))
            throw error
        }
    }
}

private enum SongReferenceRangeLocks {
    private static let lock = NSLock()
    private static var active: Set<String> = []
    static func acquire(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.insert(path).inserted
    }
    static func release(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        active.remove(path)
    }
}

/// The handler can race with task creation or completion. Never invoke
/// URLSession while holding the lock; installation after cancellation still
/// cancels the newly created network task.
private final class SongReferenceRangeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?
    func install(_ value: URLSessionTask) {
        lock.lock(); task = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    func finish() { lock.lock(); task = nil; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

/// One data task per bounded chunk. Validate response headers *before* telling
/// URLSession to deliver its body; do not use download(for:), which waits for
/// an entire HTTP 200 response before exposing headers to the caller.
private final class SongReferenceRangeChunk: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let expectedRange: String
    let expectedETag: String
    let expectedBytes: Int64
    let destination: URL
    let file: FileHandle
    let completion: (Result<URL, Error>) -> Void
    let allowedHosts: Set<String>
    let cancellation: SongReferenceRangeCancellation
    var received: Int64 = 0
    var failure: Error?
    var redirects = 0

    private init(expectedRange: String, expectedETag: String, expectedBytes: Int64,
                 destination: URL, file: FileHandle, allowedHosts: Set<String>, cancellation: SongReferenceRangeCancellation,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        self.expectedRange = expectedRange
        self.expectedETag = expectedETag
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.file = file
        self.allowedHosts = allowedHosts
        self.cancellation = cancellation
        self.completion = completion
    }

    static func receive(request: URLRequest, expectedRange: String, expectedETag: String,
                        expectedBytes: Int64, allowedHosts: Set<String>, protocolClasses: [AnyClass]?) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("range-chunk-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SongReferenceRangeFailure.incompleteState
        }
        let file: FileHandle
        do { file = try FileHandle(forWritingTo: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        let cancellation = SongReferenceRangeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = SongReferenceRangeChunk(expectedRange: expectedRange, expectedETag: expectedETag,
                                          expectedBytes: expectedBytes, destination: destination, file: file,
                                          allowedHosts: allowedHosts, cancellation: cancellation) {
                    continuation.resume(with: $0)
                }
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                if let protocolClasses { configuration.protocolClasses = protocolClasses }
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
                let task = session.dataTask(with: request)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url,
              SongReferenceRangeDownload.allowed(url, hosts: allowedHosts, allowQuery: true) else {
            failure = SongReferenceRangeFailure.rejectedRedirect
            completionHandler(nil)
            return
        }
        var safe = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Referer"] {
            safe.setValue(nil, forHTTPHeaderField: header)
        }
        let rangeParts = expectedRange.split(separator: "/", maxSplits: 1)
        if let range = rangeParts.first { safe.setValue(String(range).replacingOccurrences(of: "bytes ", with: "bytes="), forHTTPHeaderField: "Range") }
        safe.setValue(expectedETag, forHTTPHeaderField: "If-Range")
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(safe)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            failure = SongReferenceRangeFailure.unsupportedResponse
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        guard http.value(forHTTPHeaderField: "ETag") == expectedETag else {
            failure = SongReferenceRangeFailure.identityMismatch
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        guard http.value(forHTTPHeaderField: "Content-Range")?.caseInsensitiveCompare(expectedRange) == .orderedSame else {
            failure = SongReferenceRangeFailure.unexpectedRange
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
           !encoding.isEmpty && encoding.caseInsensitiveCompare("identity") != .orderedSame {
            failure = SongReferenceRangeFailure.unsupportedResponse
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= expectedBytes - received else {
            failure = SongReferenceRangeFailure.unexpectedChunkSize
            dataTask.cancel(); return
        }
        do {
            try file.write(contentsOf: data)
            received += Int64(data.count)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { cancellation.finish(); session.finishTasksAndInvalidate() }
        do {
            if cancellation.isCancelled { throw CancellationError() }
            if let failure { throw failure }
            if let error { throw error }
            guard received == expectedBytes else { throw SongReferenceRangeFailure.unexpectedChunkSize }
            try file.synchronize()
            try file.close()
            completion(.success(destination))
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: destination)
            completion(.failure(error))
        }
    }
}
