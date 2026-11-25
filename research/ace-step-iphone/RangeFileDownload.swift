// Isolated research prototype. Not part of FadedAI's production build.
// Each verified HTTP range is appended only after it has fully downloaded.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RangeDownloadFailure: Error, Equatable {
    case invalidConfiguration, incompleteState, identityMismatch, invalidPartialSize
    case unsupportedResponse, unexpectedRange, unexpectedChunkSize, verificationFailed
}

/// Caller must provide a cryptographically strong final file verifier before a
/// model is used. This component does not install, rename or expose the file.
/// A given partial path must have only one active downloader at a time.
struct RangeFileDownload {
    struct Identity: Codable, Equatable {
        let url: String
        let strongETag: String
        let bytes: Int64
        /// Absolute offset in the source file, and size of that whole file.
        let sourceOffset: Int64
        let sourceBytes: Int64
    }
    let chunkBytes: Int64
    let onRedirect: ((Int) -> Void)?

    init(chunkBytes: Int64 = 4 * 1024 * 1024, onRedirect: ((Int) -> Void)? = nil) {
        self.chunkBytes = chunkBytes
        self.onRedirect = onRedirect
    }

    /// A failed request never invalidates an earlier completed range. In-flight
    /// chunk bytes are stored by URLSession separately until response validation.
    func fetch(url: URL, partial: URL, size: Int64, sourceOffset: Int64 = 0,
               sourceBytes: Int64? = nil, strongETag: String,
               verify: (URL) throws -> Bool) async throws -> URL {
        try Task.checkCancellation()
        let totalSourceBytes = sourceBytes ?? size
        guard size > 0, chunkBytes > 0, partial.isFileURL,
              sourceOffset >= 0, totalSourceBytes > 0, sourceOffset <= totalSourceBytes,
              size <= totalSourceBytes - sourceOffset,
              strongETag.count >= 2, strongETag.hasPrefix("\""), strongETag.hasSuffix("\""),
              !strongETag.hasPrefix("W/") else { throw RangeDownloadFailure.invalidConfiguration }
        let identity = Identity(url: url.absoluteString, strongETag: strongETag, bytes: size,
                                sourceOffset: sourceOffset, sourceBytes: totalSourceBytes)
        let sidecar = partial.appendingPathExtension("identity.json")
        let fm = FileManager.default
        let hasPartial = fm.fileExists(atPath: partial.path)
        let hasSidecar = fm.fileExists(atPath: sidecar.path)
        guard hasPartial == hasSidecar else { throw RangeDownloadFailure.incompleteState }
        if hasPartial {
            let recorded = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: sidecar))
            guard recorded == identity else { throw RangeDownloadFailure.identityMismatch }
        } else {
            // The sidecar is created first, then the empty partial. If creation
            // fails, remove only the sidecar created by this invocation.
            try JSONEncoder().encode(identity).write(to: sidecar, options: .withoutOverwriting)
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                try? fm.removeItem(at: sidecar)
                throw RangeDownloadFailure.incompleteState
            }
        }
        var offset = try fileSize(partial)
        guard offset <= size else { throw RangeDownloadFailure.invalidPartialSize }
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
            let chunk = try await RangeChunk.receive(request: request, expectedRange: expectedRange,
                                                     expectedETag: strongETag, expectedBytes: length,
                                                     onRedirect: onRedirect)
            defer { try? fm.removeItem(at: chunk) }
            try Task.checkCancellation()
            guard try fileSize(chunk) == length else { throw RangeDownloadFailure.unexpectedChunkSize }
            try append(chunk: chunk, to: partial, originalSize: offset)
            offset += length
        }
        try Task.checkCancellation()
        guard try verify(partial) else { throw RangeDownloadFailure.verificationFailed }
        try Task.checkCancellation()
        return partial
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let value, value >= 0 else { throw RangeDownloadFailure.invalidPartialSize }
        return Int64(value)
    }

    private func append(chunk: URL, to partial: URL, originalSize: Int64) throws {
        let source = try FileHandle(forReadingFrom: chunk)
        defer { try? source.close() }
        let target = try FileHandle(forWritingTo: partial)
        defer { try? target.close() }
        guard try target.seekToEnd() == UInt64(originalSize) else { throw RangeDownloadFailure.invalidPartialSize }
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

/// The handler can race with task creation or completion. Never invoke
/// URLSession while holding the lock; installation after cancellation still
/// cancels the newly created network task.
private final class RangeCancellation: @unchecked Sendable {
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
private final class RangeChunk: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let expectedRange: String
    let expectedETag: String
    let expectedBytes: Int64
    let destination: URL
    let file: FileHandle
    let completion: (Result<URL, Error>) -> Void
    let onRedirect: ((Int) -> Void)?
    let cancellation: RangeCancellation
    var received: Int64 = 0
    var failure: Error?

    private init(expectedRange: String, expectedETag: String, expectedBytes: Int64,
                 destination: URL, file: FileHandle, onRedirect: ((Int) -> Void)?, cancellation: RangeCancellation,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        self.expectedRange = expectedRange
        self.expectedETag = expectedETag
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.file = file
        self.onRedirect = onRedirect
        self.cancellation = cancellation
        self.completion = completion
    }

    static func receive(request: URLRequest, expectedRange: String, expectedETag: String,
                        expectedBytes: Int64, onRedirect: ((Int) -> Void)?) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("range-chunk-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw RangeDownloadFailure.incompleteState
        }
        let file: FileHandle
        do { file = try FileHandle(forWritingTo: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        let cancellation = RangeCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = RangeChunk(expectedRange: expectedRange, expectedETag: expectedETag,
                                          expectedBytes: expectedBytes, destination: destination, file: file,
                                          onRedirect: onRedirect, cancellation: cancellation) {
                    continuation.resume(with: $0)
                }
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
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
        onRedirect?(response.statusCode)
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            failure = RangeDownloadFailure.unsupportedResponse
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        guard http.value(forHTTPHeaderField: "ETag") == expectedETag else {
            failure = RangeDownloadFailure.identityMismatch
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        guard http.value(forHTTPHeaderField: "Content-Range")?.caseInsensitiveCompare(expectedRange) == .orderedSame else {
            failure = RangeDownloadFailure.unexpectedRange
            dataTask.cancel()
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= expectedBytes - received else {
            failure = RangeDownloadFailure.unexpectedChunkSize
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
            guard received == expectedBytes else { throw RangeDownloadFailure.unexpectedChunkSize }
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
