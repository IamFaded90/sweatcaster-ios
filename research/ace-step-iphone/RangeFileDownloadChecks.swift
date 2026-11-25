// Standalone integration checks against the loopback-only fixture server.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct RangeFileDownloadChecks {
    static func good(_ file: URL) throws -> Bool {
        let expected = Data((0..<100_003).map { UInt8($0 % 251) })
        return try Data(contentsOf: file) == expected
    }
    static func bytes(_ file: URL) throws -> Int64 {
        Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("range-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size: Int64 = 100_003
        let downloader = RangeFileDownload(chunkBytes: 16_384)
        let base = URL(string: "http://127.0.0.1:18473")!
        func part(_ name: String) -> URL { root.appendingPathComponent(name + ".partial") }
        let interrupted = part("interrupted")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: interrupted,
                                           size: size, strongETag: "\"fixture-v1\"", verify: good)
            preconditionFailure("Transient error was accepted")
        } catch RangeDownloadFailure.unsupportedResponse { }
        let initialBytes = try bytes(interrupted)
        precondition(initialBytes == 16_384, "A previously finished chunk was not preserved")
        let completed = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: interrupted,
                                                   size: size, strongETag: "\"fixture-v1\"", verify: good)
        let completedMatches = try good(completed)
        precondition(completedMatches, "Resumed file has different contents")
        let (statsData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let counts = try JSONDecoder().decode([String: Int].self, from: statsData)
        precondition(counts["/transient:0"] == 1 && counts["/transient:16384"] == 2,
                     "A completed range was downloaded again")

        let subrangeStart: Int64 = 22_000
        let subrangeSize: Int64 = 50_000
        let allBytes = Data((0..<100_003).map { UInt8($0 % 251) })
        let expectedRange = allBytes.subdata(in: Int(subrangeStart)..<Int(subrangeStart + subrangeSize))
        let subrange = part("subrange")
        let verifySubrange: (URL) throws -> Bool = { try Data(contentsOf: $0) == expectedRange }
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("subrange-transient"), partial: subrange,
                                           size: subrangeSize, sourceOffset: subrangeStart, sourceBytes: size,
                                           strongETag: "\"fixture-v1\"", verify: verifySubrange)
            preconditionFailure("Subrange interruption was accepted")
        } catch RangeDownloadFailure.unsupportedResponse { }
        let partialBytes = try bytes(subrange)
        precondition(partialBytes == 16_384, "First absolute-range chunk was not preserved")
        let resumed = try await downloader.fetch(url: base.appendingPathComponent("subrange-transient"), partial: subrange,
                                                 size: subrangeSize, sourceOffset: subrangeStart, sourceBytes: size,
                                                 strongETag: "\"fixture-v1\"", verify: verifySubrange)
        let subrangeMatches = try verifySubrange(resumed)
        precondition(subrangeMatches, "Resumed absolute range has wrong contents")
        let (subrangeStats, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let subrangeCounts = try JSONDecoder().decode([String: Int].self, from: subrangeStats)
        precondition(subrangeCounts["/subrange-transient:22000"] == 1 &&
                     subrangeCounts["/subrange-transient:38384"] == 2,
                     "Absolute range resumed at a wrong offset or re-downloaded an earlier block")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("subrange-transient"), partial: subrange,
                                           size: subrangeSize, sourceOffset: subrangeStart + 1, sourceBytes: size,
                                           strongETag: "\"fixture-v1\"", verify: verifySubrange)
            preconditionFailure("Changed source offset was accepted")
        } catch RangeDownloadFailure.identityMismatch { }
        for wrong in ["malformed", "wrong-start"] {
            let destination = part("absolute-" + wrong)
            do {
                _ = try await downloader.fetch(url: base.appendingPathComponent(wrong), partial: destination,
                                               size: subrangeSize, sourceOffset: subrangeStart, sourceBytes: size,
                                               strongETag: "\"fixture-v1\"", verify: verifySubrange)
                preconditionFailure("Wrong absolute Content-Range was accepted")
            } catch RangeDownloadFailure.unexpectedRange { }
            let preservedBytes = try bytes(destination)
            precondition(preservedBytes == 0, "Wrong Content-Range modified partial file")
        }
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: part("out-of-bounds"),
                                           size: 4, sourceOffset: Int64.max - 1, sourceBytes: Int64.max,
                                           strongETag: "\"fixture-v1\"", verify: good)
            preconditionFailure("Overflowing source range was accepted")
        } catch RangeDownloadFailure.invalidConfiguration { }

        let immediate = Task {
            try await downloader.fetch(url: base.appendingPathComponent("immediate"), partial: part("immediate"),
                                       size: size, strongETag: "\"fixture-v1\"", verify: good)
        }
        immediate.cancel()
        do {
            _ = try await immediate.value
            preconditionFailure("Already-cancelled transfer was accepted")
        } catch is CancellationError { }

        // The second block streams slowly. Cancel only after its body starts,
        // then prove that the first complete block survives and the network
        // task is actually closed. A later attempt should resume at block two.
        let cancelled = part("cancelled")
        let slowTask = Task {
            try await downloader.fetch(url: base.appendingPathComponent("slowcancel"), partial: cancelled,
                                       size: size, strongETag: "\"fixture-v1\"", verify: good)
        }
        var started = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let state = try JSONDecoder().decode([String: Int].self, from: data)
            if (state["slowcancel.bytes_sent"] ?? 0) >= 256 { started = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(started, "Slow second block did not start")
        slowTask.cancel()
        do {
            _ = try await slowTask.value
            preconditionFailure("Cancelled transfer was accepted")
        } catch is CancellationError { }
        let cancelledBytes = try bytes(cancelled)
        precondition(cancelledBytes == 16_384, "Cancelled transfer altered completed-block boundary")
        var sentBeforeDisconnect = Int.max
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let state = try JSONDecoder().decode([String: Int].self, from: data)
            if state["slowcancel.done"] == 1 { sentBeforeDisconnect = state["slowcancel.bytes_sent"] ?? Int.max; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(sentBeforeDisconnect < 16_384, "Cancelled network transfer continued until end of chunk")
        let cancelResume = try await downloader.fetch(url: base.appendingPathComponent("slowcancel"), partial: cancelled,
                                                       size: size, strongETag: "\"fixture-v1\"", verify: good)
        let cancelResumeMatches = try good(cancelResume)
        precondition(cancelResumeMatches, "Resumption after cancellation returned different data")
        let (cancelStats, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let cancelCounts = try JSONDecoder().decode([String: Int].self, from: cancelStats)
        precondition(cancelCounts["/slowcancel:0"] == 1 && cancelCounts["/slowcancel:16384"] == 2,
                     "Cancellation repeated a completed block or missed resumption")
        print("Cancelled slow chunk after server sent \(sentBeforeDisconnect) of 16384 bytes; previous block preserved")

        let largeIgnored = part("large-ignored")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("ignored-large"), partial: largeIgnored,
                                           size: size, strongETag: "\"fixture-v1\"", verify: good)
            preconditionFailure("A 200 response ignoring range was accepted")
        } catch RangeDownloadFailure.unsupportedResponse { }
        let rejectedBytes = try bytes(largeIgnored)
        precondition(rejectedBytes == 0, "A rejected response modified the partial")
        var sent = Int.max
        for _ in 0..<100 {
            let (postLargeData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
            let postLargeCounts = try JSONDecoder().decode([String: Int].self, from: postLargeData)
            if let completed = postLargeCounts["ignored-large.bytes_sent"] { sent = completed; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(sent < 4 * 1024 * 1024, "The server sent too much before cancellation: \(sent)")
        print("Ignoring Range: cancelled after server sent \(sent) of 67108864 bytes")

        for (name, failure) in [("ignored", RangeDownloadFailure.unsupportedResponse),
                                ("malformed", .unexpectedRange), ("changed", .identityMismatch),
                                ("short", .unexpectedChunkSize)] {
            let destination = part(name)
            do {
                _ = try await downloader.fetch(url: base.appendingPathComponent(name), partial: destination,
                                               size: size, strongETag: "\"fixture-v1\"", verify: good)
                preconditionFailure("Invalid \(name) response was accepted")
            } catch let error as RangeDownloadFailure {
                precondition(error == failure, "Unexpected error for \(name): \(error)")
            }
            let destinationBytes = try bytes(destination)
            precondition(destinationBytes == 0, "Invalid response modified the partial file")
        }

        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: interrupted,
                                           size: size, strongETag: "\"other\"", verify: good)
            preconditionFailure("Changed identity was accepted")
        } catch RangeDownloadFailure.identityMismatch { }
        let preserved = try good(interrupted)
        precondition(preserved, "Identity mismatch changed the partial")
        do {
            _ = try await downloader.fetch(url: base.appendingPathComponent("transient"), partial: interrupted,
                                           size: size, strongETag: "\"fixture-v1\"", verify: { _ in false })
            preconditionFailure("Bad final verification was accepted")
        } catch RangeDownloadFailure.verificationFailed { }
        print("PASS: resumable ranges, transient failure, bad ranges/ETags/lengths and final verification")
        print("Prototype only: no iPhone, production server or device memory test was performed.")
    }
}
