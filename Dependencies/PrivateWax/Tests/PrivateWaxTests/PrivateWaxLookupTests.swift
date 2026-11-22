#if os(Linux)
import Glibc
#endif
import Foundation
import XCTest
@testable import FadedAIPrivateWax

final class PrivateWaxLookupTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testDanishLookupUsesTrueWaxAndRemovesItsFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID()
        let hits = try await PrivateWaxLookup(root: root).search("TURKIS kompas", in: [
            .init(id: a, text: "Et turkis kompas lå i den opdigtede månehave."),
            .init(id: b, text: "Den fiktive kobberstation har en orange tekande.")
        ])
        XCTAssertEqual(hits, [a])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let next = try await PrivateWaxLookup(root: root).search("kompas", in: [.init(id: b, text: "tekande")])
        XCTAssertEqual(next, [])
    }

    func testAllWordsMustOccurInTheSameTurn() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID(), c = UUID()
        let turns: [PrivateWaxLookup.Turn] = [.init(id: a, text: "kompas i nord"), .init(id: b, text: "sejl mod syd"), .init(id: c, text: "kompas med sejl")]
        let hits = try await PrivateWaxLookup(root: root).search("kompas sejl", in: turns)
        XCTAssertEqual(hits, [c])
        let missing = try await PrivateWaxLookup(root: root).search("kompas ukendt", in: turns)
        XCTAssertTrue(missing.isEmpty)
    }

    func testCleanupRemovesOrphanOnlyInsideDedicatedDirectory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("synthetic only".utf8).write(to: abandoned.appendingPathComponent("sidecar"))
        try Data().write(to: root.appendingPathComponent("unrelated"))
        try PrivateWaxLookup.cleanAbandoned(in: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["unrelated"])
    }

    func testNoMatchAndPunctuationCreateNoFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let turns = [PrivateWaxLookup.Turn(id: UUID(), text: "En opdigtet scene i måneskin")]
        for query in ["", "?!", "søstjerne"] {
            let result = try await PrivateWaxLookup(root: root).search(query, in: turns)
            XCTAssertTrue(result.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testCancelInvalidatesLateResultsAndRemovesTheActiveIndex() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lookup = PrivateWaxLookup(root: root)
        let turns = (0..<200).map { PrivateWaxLookup.Turn(id: UUID(), text: "Unik fiktiv bjergstation nummer " + String($0)) }
        let pending = Task { try await lookup.search("bjergstation", in: turns) }
        var store: URL?
        for _ in 0..<600 {
            let first = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first
            if let first, let h = try? FileHandle(forReadingFrom: first.appendingPathComponent("chat.wax")) {
                let marker = try? h.read(upToCount: 4)
                try? h.close()
                guard marker == Data("WAX1".utf8) else { try await Task.sleep(for: .milliseconds(5)); continue }
                store = first.appendingPathComponent("chat.wax")
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let store {
            let data = try Data(contentsOf: store)
            XCTAssertEqual(data.prefix(4), Data("WAX1".utf8))
            XCTAssertNil(data.range(of: Data("bjergstation".utf8)))
            try PrivateWaxLookup.cleanAbandoned(in: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        } else { XCTFail("A real Wax index should be observable during a long search") }
        lookup.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled lookup returned a result") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        do { _ = try await lookup.search("nyt", in: turns); XCTFail("Cancelled search was reused") } catch { }
    }
    #if os(Linux)
    func testKilledProcessIsCleanedOnNextLaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["PrivateWaxTests.PrivateWaxLookupTests/testCrashWorker"]
        var env = ProcessInfo.processInfo.environment
        env["FADEDAI_WAX_SYNTHETIC_TEST_ROOT"] = root.path
        child.environment = env
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        var file: URL?
        for _ in 0..<1500 {
            if !child.isRunning { break }
            let entry = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first
            if let url = entry?.appendingPathComponent("chat.wax"), let info = try? url.resourceValues(forKeys: [.fileSizeKey]),
               (info.fileSize ?? 0) > 1_000_000, let handle = try? FileHandle(forReadingFrom: url) {
                let header = try? handle.read(upToCount: 4)
                try? handle.close()
                if header == Data("WAX1".utf8) { file = url; break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let captured = try XCTUnwrap(file)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(Glibc.kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        let bytes = try Data(contentsOf: captured)
        XCTAssertEqual(bytes.prefix(4), Data("WAX1".utf8))
        XCTAssertNil(bytes.range(of: Data("hemmeligtkompas".utf8)))
        try PrivateWaxLookup.cleanAbandoned(in: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCrashWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["FADEDAI_WAX_SYNTHETIC_TEST_ROOT"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let turns = (0..<8_000).map { PrivateWaxLookup.Turn(id: UUID(), text: "hemmeligtkompas opdigtet scene nummer " + String($0)) }
        _ = try await PrivateWaxLookup(root: root).search("hemmeligtkompas", in: turns)
    }
    #endif
}
