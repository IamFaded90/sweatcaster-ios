import XCTest
@testable import OfflineSongRuntime

final class CompatibilityTests: XCTestCase {
    func testACESupportedVocalLanguages() {
        XCTAssertEqual(ACESongLanguages.validated("da"), "da")
        XCTAssertEqual(ACESongLanguages.validated("en"), "en")
        XCTAssertEqual(ACESongLanguages.validated("unknown"), "unknown")
        XCTAssertNil(ACESongLanguages.validated("not-a-language"))
    }

    func testCopiesPaddedOuterDimensionsAndRows() {
        let layout = ACEStridedTensor(shape: [2, 2, 2], strides: [10, 3, 1])
        let source: [UInt16] = [1, 2, 90, 3, 4, 90, 90, 90, 90, 90, 5, 6, 90, 7, 8]
        XCTAssertFalse(layout.isContiguous)
        XCTAssertEqual(source.withUnsafeBufferPointer { layout.copy(from: $0) }, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testCopiesNonUnitColumnStrideAndPreservesFloat16Bits() {
        let layout = ACEStridedTensor(shape: [2, 2], strides: [5, 2])
        let original: [Float16] = [0.5, 99, -2, 99, 99, 3.25, 99, 4.5]
        let values = original.withUnsafeBufferPointer { layout.copy(from: $0) }
        XCTAssertFalse(layout.isContiguous)
        XCTAssertEqual(values.map(\.bitPattern), [Float16(0.5), -2, 3.25, 4.5].map(\.bitPattern))
    }

    func testDenseLayoutWithSingletonAxisIsRecognized() {
        XCTAssertTrue(ACEStridedTensor(shape: [2, 1, 3], strides: [3, 999, 1]).isContiguous)
        XCTAssertFalse(ACEStridedTensor(shape: [2, 1, 3], strides: [4, 999, 1]).isContiguous)
    }

    func testStaleSongResumeTriesFreshButTemporaryServerFailuresPreserveProgress() {
        XCTAssertTrue(SongDownloadPolicy.restartAfterResume(status: 200, received: 49, expected: 100))
        XCTAssertTrue(SongDownloadPolicy.restartAfterResume(status: 206, received: 49, expected: 100))
        XCTAssertTrue(SongDownloadPolicy.restartAfterResume(status: 404, received: 0, expected: 100))
        XCTAssertTrue(SongDownloadPolicy.restartAfterResume(status: 416, received: 0, expected: 100))
        XCTAssertFalse(SongDownloadPolicy.restartAfterResume(status: 206, received: 100, expected: 100))
        XCTAssertFalse(SongDownloadPolicy.restartAfterResume(status: 503, received: 0, expected: 100))
        XCTAssertFalse(SongDownloadPolicy.restartAfterResume(status: nil, received: nil, expected: 100))
    }

    func testVeryLargeDurationsDoNotOverflowWhileParsing() {
        XCTAssertEqual(PromptMetadata.duration(in: String(repeating: "9", count: 100) + " seconds"), 384)
        XCTAssertEqual(PromptMetadata.duration(in: "0 seconds"), 5)
        XCTAssertEqual(PromptMetadata.duration(in: "1 minute 21 seconds"), 81)
    }

    func testDownloadIntegrityRejectsWrongBytesEvenWhenFileSizeMatches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = "770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c"
        try Data("good".utf8).write(to: file)
        XCTAssertTrue(try SongFileIntegrity.matches(file, sha256: expected))
        try Data("evil".utf8).write(to: file)
        XCTAssertFalse(try SongFileIntegrity.matches(file, sha256: expected))
        XCTAssertFalse(try SongFileIntegrity.matches(file, sha256: "not-a-sha256"))
    }
}
