import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OfflineSongRuntime

final class DownloadProgressTests: XCTestCase {
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PhoneSongDownloadUpdate] = []
        func append(_ value: PhoneSongDownloadUpdate) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [PhoneSongDownloadUpdate] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testGlobalProgressIncludesPreviouslyInstalledFilesAndResumedBytes() {
        let updates = Updates()
        let observer = SongDownloadProgress(label: "ACE", expected: 400, completed: 600, total: 1_000, report: { updates.append($0) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        observer.urlSession(session, downloadTask: task, didWriteData: 10, totalBytesWritten: 300, totalBytesExpectedToWrite: 400)
        XCTAssertEqual(updates.snapshot.last?.completedBytes, 900)
        XCTAssertEqual(updates.snapshot.last?.fraction, 0.9)
    }

    func testCompletionIsReportedEvenInsideTheThrottleWindow() {
        let updates = Updates()
        let observer = SongDownloadProgress(label: "ACE", expected: 400, completed: 600, total: 1_000, report: { updates.append($0) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        for written in 1...400 {
            observer.urlSession(session, downloadTask: task, didWriteData: 1,
                                totalBytesWritten: Int64(written), totalBytesExpectedToWrite: 400)
        }
        XCTAssertEqual(updates.snapshot.last?.fraction, 1)
        XCTAssertLessThan(updates.snapshot.count, 20, "Do not enqueue a UI task for every network packet")
    }

    func testUnexpectedServerLengthCannotOvershootOverallProgress() {
        let updates = Updates()
        let observer = SongDownloadProgress(label: "ACE", expected: 400, completed: 600, total: 1_000, report: { updates.append($0) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        observer.urlSession(session, downloadTask: task, didWriteData: 700,
                            totalBytesWritten: 700, totalBytesExpectedToWrite: -1)
        XCTAssertEqual(updates.snapshot.last?.completedBytes, 1_000)
        XCTAssertEqual(updates.snapshot.last?.fraction, 1)
    }

    func testWaitingForFirstByteHasReadableStatusAndZeroProgress() {
        let waiting = PhoneSongDownloadUpdate(message: "Forbinder til GitHub…", completedBytes: 0, totalBytes: 9_000_000_000)
        XCTAssertEqual(waiting.fraction, 0)
        XCTAssertFalse(waiting.message.isEmpty)
        XCTAssertFalse(waiting.byteSummary.isEmpty)
    }
}
