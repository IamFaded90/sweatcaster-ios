// Standalone CPU fixture tests; compile with -D FADEDAI_RANGE_TESTS.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class SongFixtureProtocol: URLProtocol {
    static let data = Data((0..<100_003).map { UInt8($0 % 251) })
    static let lock = NSLock()
    static var counts: [String: Int] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    override func startLoading() {
        guard let url = request.url, let range = request.value(forHTTPHeaderField: "Range"),
              range.hasPrefix("bytes="), request.value(forHTTPHeaderField: "If-Range") == "\"fixture-v1\"",
              request.value(forHTTPHeaderField: "Accept-Encoding") == "identity",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let numbers = range.dropFirst(6).split(separator: "-")
        guard numbers.count == 2, let start = Int(numbers[0]), let end = Int(numbers[1]),
              start >= 0, end >= start, end < Self.data.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let path = url.path
        let key = "\(path):\(start)"
        Self.lock.lock(); Self.counts[key, default: 0] += 1; let visits = Self.counts[key]!; Self.lock.unlock()
        let status = path == "/ignored" ? 200 : (path == "/transient" && start == 38_384 && visits == 1 ? 503 : 206)
        let shownStart = path == "/wrong-range" ? start + 1 : start
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "ETag": path == "/changed" ? "\"changed\"" : "\"fixture-v1\"",
            "Content-Range": "bytes \(shownStart)-\(end)/\(Self.data.count)"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.data.subdata(in: start..<(end + 1))
        if path == "/slow" {
            Thread.sleep(forTimeInterval: 1)
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            if !cancelled { client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self) }
        } else {
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@main
private struct SongReferenceRangeDownloadTests {
    static func main() async throws {
        let host = "fixture.example"
        let allowed: Set<String> = [host]
        let base = URL(string: "https://fixture.example")!
        let downloader = SongReferenceRangeDownload(allowedHosts: allowed, chunkBytes: 16_384,
                                                     protocolClasses: [SongFixtureProtocol.self])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("song-range-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func path(_ name: String) -> URL { root.appendingPathComponent(name + ".partial") }
        let start: Int64 = 22_000, size: Int64 = 50_000, total: Int64 = 100_003
        let expected = SongFixtureProtocol.data.subdata(in: Int(start)..<Int(start + size))
        let verify: @Sendable (URL) throws -> Bool = { try Data(contentsOf: $0) == expected }

        precondition(SongReferenceRangeDownload.allowed(base, hosts: allowed, allowQuery: false))
        for invalid in ["http://fixture.example/x", "https://evil.example/x", "https://u:p@fixture.example/x",
                        "https://fixture.example:444/x", "https://fixture.example/x?secret=1"] {
            precondition(!SongReferenceRangeDownload.allowed(URL(string: invalid)!, hosts: allowed, allowQuery: false))
        }
        precondition(SongReferenceRangeDownload.allowed(URL(string: "https://fixture.example/x?signed=1")!, hosts: allowed, allowQuery: true))

        // Crash after sidecar creation: recreate only an empty partial when
        // the existing sidecar exactly identifies this requested range.
        let interruptedCreation = path("sidecar-only")
        let orphanSidecar = interruptedCreation.appendingPathExtension("identity.json")
        let sourceURL = base.appendingPathComponent("recovery")
        let identity = SongReferenceRangeDownload.Identity(url: sourceURL.absoluteString,
            strongETag: "\"fixture-v1\"", bytes: size, sourceOffset: start, sourceBytes: total)
        try JSONEncoder().encode(identity).write(to: orphanSidecar)
        let recovered = try await downloader.fetch(url: sourceURL, partial: interruptedCreation,
            size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
        let recoveredMatches = try verify(recovered)
        precondition(recoveredMatches)

        let mismatch = path("sidecar-mismatch")
        let mismatchSidecar = mismatch.appendingPathExtension("identity.json")
        let mismatchedIdentity = SongReferenceRangeDownload.Identity(url: sourceURL.absoluteString,
            strongETag: "\"different\"", bytes: size, sourceOffset: start, sourceBytes: total)
        let mismatchedData = try JSONEncoder().encode(mismatchedIdentity)
        try mismatchedData.write(to: mismatchSidecar)
        do {
            _ = try await downloader.fetch(url: sourceURL, partial: mismatch, size: size,
                sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
            preconditionFailure("mismatched orphan sidecar was accepted")
        } catch SongReferenceRangeFailure.identityMismatch { }
        precondition(!FileManager.default.fileExists(atPath: mismatch.path))
        let mismatchStillPresent = try Data(contentsOf: mismatchSidecar)
        precondition(mismatchStillPresent == mismatchedData)

        let missingSidecar = path("partial-only")
        let preserved = Data("preserve existing partial".utf8)
        try preserved.write(to: missingSidecar)
        do {
            _ = try await downloader.fetch(url: sourceURL, partial: missingSidecar, size: size,
                sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
            preconditionFailure("partial without identity was accepted")
        } catch SongReferenceRangeFailure.incompleteState { }
        let partialStillPresent = try Data(contentsOf: missingSidecar)
        precondition(partialStillPresent == preserved)
        precondition(!FileManager.default.fileExists(atPath: missingSidecar.appendingPathExtension("identity.json").path))

        let partial = path("resume")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: partial,
                size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
            preconditionFailure("transient failure was accepted")
        } catch SongReferenceRangeFailure.unsupportedResponse { }
        let savedSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(savedSize == 16_384)
        let resumed = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: partial,
            size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
        let resumedMatches = try verify(resumed)
        precondition(resumedMatches)
        precondition(SongFixtureProtocol.counts["/transient:22000"] == 1)
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: partial,
                size: size, sourceOffset: start + 1, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
            preconditionFailure("changed resume identity was accepted")
        } catch SongReferenceRangeFailure.identityMismatch { }

        for (name, failure) in [("ignored", SongReferenceRangeFailure.unsupportedResponse),
                                ("changed", .identityMismatch), ("wrong-range", .unexpectedRange)] {
            do {
                _ = try await downloader.fetch(url: base.appendingPathComponent(name), partial: path(name),
                    size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
                preconditionFailure("invalid response was accepted")
            } catch let error as SongReferenceRangeFailure { precondition(error == failure) }
            let savedSize = try path(name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            precondition(savedSize == 0)
        }

        let corrupt = path("corrupt")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("good"), partial: corrupt,
                size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"") { _ in false }
            preconditionFailure("corrupt file was accepted")
        } catch SongReferenceRangeFailure.verificationFailed { }
        precondition(!FileManager.default.fileExists(atPath: corrupt.path))
        precondition(!FileManager.default.fileExists(atPath: corrupt.appendingPathExtension("identity.json").path))
        let retried = try await downloader.fetch(url: base.appendingPathComponent("good"), partial: corrupt,
            size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
        let retriedMatches = try verify(retried)
        precondition(retriedMatches)

        let slow = Task {
            try await downloader.fetch(url: base.appendingPathComponent("slow"), partial: path("cancel"),
                size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("slow"), partial: path("cancel"),
                size: size, sourceOffset: start, sourceBytes: total, strongETag: "\"fixture-v1\"", verify: verify)
            preconditionFailure("concurrent transfer accepted")
        } catch SongReferenceRangeFailure.busy { }
        slow.cancel()
        do { _ = try await slow.value; preconditionFailure("cancellation was ignored") }
        catch is CancellationError { }
        print("PASS: HTTPS host policy, absolute ranges, resume, sidecar recovery, response validation, corrupt retry, cancellation and lock")
    }
}
