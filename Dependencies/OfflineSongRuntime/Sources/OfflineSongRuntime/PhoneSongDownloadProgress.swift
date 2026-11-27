import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PhoneSongDownloadUpdate: Sendable {
    public let message: String
    public let completedBytes, totalBytes: Int64
    public var fraction: Double { min(1, max(0, Double(completedBytes) / Double(max(1, totalBytes)))) }
    public var byteSummary: String {
        ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file) + " / " +
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

final class SongDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let label: String
    let expected: Int64
    let completed, total: Int64
    let report: @Sendable (PhoneSongDownloadUpdate) -> Void
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    init(label: String, expected: Int64, completed: Int64, total: Int64,
         report: @escaping @Sendable (PhoneSongDownloadUpdate) -> Void) {
        self.label = label; self.expected = expected; self.completed = completed; self.total = total; self.report = report
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let emit = now.timeIntervalSince(lastReport) >= 0.25 || totalBytesWritten >= expected
        if emit { lastReport = now }
        lock.unlock()
        guard emit else { return }
        report(.init(message: label, completedBytes: completed + min(expected, max(0, totalBytesWritten)), totalBytes: total))
    }
}
