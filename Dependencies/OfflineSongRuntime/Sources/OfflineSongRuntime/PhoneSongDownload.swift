import Foundation

enum PhoneSongDownload {
    static func fetch(to root: URL, progress: @Sendable @escaping (String) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let missing = PhoneSongAsset.all.filter { !$0.present(at: root) }
        for (index, file) in missing.enumerated() {
            try Task.checkCancellation()
            let path = root.appendingPathComponent(file.path)
            let resume = root.appendingPathComponent(file.path + ".resume")
            try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let observer = SongDownloadProgress(label: "Henter ACE-Step · fil \(index + 1)/\(missing.count)",
                                                expected: file.bytes, report: progress)
            let existingSize = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if existingSize != file.bytes {
                do {
                    let result: (URL, URLResponse)
                    let saved = try? Data(contentsOf: resume)
                    var partial: (URL, URLResponse)?
                    if let saved, !saved.isEmpty, saved.count < 4_000_000 {
                        do {
                            partial = try await session.download(resumeFrom: saved, delegate: observer)
                        } catch {
                            // Preserve partial progress for cancellation and transient network failures.
                            let failure = error as NSError
                            let transient = [NSURLErrorCancelled, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                                             NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                             NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
                            if Task.isCancelled || error is CancellationError ||
                                (failure.domain == NSURLErrorDomain && transient.contains(failure.code)) { throw error }
                        }
                    }
                    if let partial, let http = partial.1 as? HTTPURLResponse,
                       ![401, 403, 416].contains(http.statusCode) {
                        result = partial
                    } else {
                        if let partial { try? manager.removeItem(at: partial.0) }
                        try? manager.removeItem(at: resume)
                        result = try await fresh(file, session: session, observer: observer)
                    }
                    defer { try? manager.removeItem(at: result.0) }
                    guard let response = result.1 as? HTTPURLResponse, [200, 206].contains(response.statusCode),
                          let size = try result.0.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          Int64(size) == file.bytes else {
                        throw PhoneSongFailure.download
                    }
                    if manager.fileExists(atPath: path.path) { try manager.removeItem(at: path) }
                    try manager.moveItem(at: result.0, to: path)
                    try? manager.removeItem(at: resume)
                } catch {
                    let errorInfo = (error as NSError).userInfo
                    if let data = errorInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty, data.count < 4_000_000 {
                        try? data.write(to: resume, options: .atomic)
                    }
                    throw error
                }
            }
            try Task.checkCancellation()
            guard file.present(at: root) else { throw PhoneSongFailure.download }
        }
    }

    private static func fresh(_ file: PhoneSongAsset, session: URLSession, observer: SongDownloadProgress) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: file.url)
        request.timeoutInterval = 120
        return try await session.download(for: request, delegate: observer)
    }
}

private final class SongDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let label: String
    let expected: Int64
    let report: @Sendable (String) -> Void
    init(label: String, expected: Int64, report: @escaping @Sendable (String) -> Void) {
        self.label = label; self.expected = expected; self.report = report
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(label + " · \(Int(min(100, Double(totalBytesWritten) / Double(max(1, expected)) * 100)))%")
    }
}
