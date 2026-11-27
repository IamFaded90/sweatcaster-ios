import Foundation

enum PhoneSongDownload {
    static func fetch(to root: URL, progress: @Sendable @escaping (PhoneSongDownloadUpdate) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let configuration = URLSessionConfiguration.ephemeral
        // Bound a stalled connection, not the duration of an actively moving 10 GB download.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let missing = PhoneSongAsset.all.filter { !$0.present(at: root) }
        let total = PhoneSongAsset.downloadBytes
        var completed = total - missing.reduce(0) { $0 + $1.bytes }
        for (index, file) in missing.enumerated() {
            try Task.checkCancellation()
            let path = root.appendingPathComponent(file.path)
            let resume = root.appendingPathComponent(file.path + ".resume")
            try manager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let observer = SongDownloadProgress(label: "Henter ACE-Step · fil \(index + 1)/\(missing.count)",
                                                expected: file.bytes, completed: completed, total: total, report: progress)
            progress(.init(message: "Forbinder til GitHub · fil \(index + 1)/\(missing.count)…",
                           completedBytes: completed, totalBytes: total))
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
                    if let partial {
                        let status = (partial.1 as? HTTPURLResponse)?.statusCode
                        let size = (try? partial.0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                        if SongDownloadPolicy.restartAfterResume(status: status, received: size, expected: file.bytes) {
                            try? manager.removeItem(at: partial.0)
                            try? manager.removeItem(at: resume)
                            result = try await fresh(file, session: session, observer: observer)
                        } else {
                            result = partial
                        }
                    } else {
                        try? manager.removeItem(at: resume)
                        result = try await fresh(file, session: session, observer: observer)
                    }
                    defer { try? manager.removeItem(at: result.0) }
                    guard let response = result.1 as? HTTPURLResponse else { throw PhoneSongFailure.download }
                    guard [200, 206].contains(response.statusCode) else { throw PhoneSongFailure.downloadHTTP(response.statusCode) }
                    guard let size = try result.0.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          Int64(size) == file.bytes else {
                        throw PhoneSongFailure.download
                    }
                    progress(.init(message: "Kontrollerer sangmodel · fil \(index + 1)/\(missing.count)…",
                                   completedBytes: completed + file.bytes, totalBytes: total))
                    guard let expected = file.sha256, try SongFileIntegrity.matches(result.0, sha256: expected) else {
                        try? manager.removeItem(at: resume)
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
            completed += file.bytes
        }
    }

    private static func fresh(_ file: PhoneSongAsset, session: URLSession, observer: SongDownloadProgress) async throws -> (URL, URLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: file.url)
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await session.download(for: request, delegate: observer)
    }
}
