import Foundation
import XCTest
@testable import OfflineSongRuntime

final class AssetsTests: XCTestCase {
    func testPinnedFilesResolveToPublishedFlattenedAssets() {
        let files = PhoneSongAsset.all
        XCTAssertEqual(files.count, 30)
        XCTAssertEqual(Set(files.map(\.path)).count, files.count)
        XCTAssertTrue(files.allSatisfy { $0.bytes > 0 && !$0.path.hasPrefix("/") && !$0.path.contains("..") })
        let chunk = files.first { $0.path == "ace_dit_ane_c2.mlmodelc/weights/weight.bin" }
        XCTAssertEqual(chunk?.bytes, 755_752_384)
        XCTAssertEqual(chunk?.url.absoluteString,
            "https://github.com/yu314-coder/WhisperKit/releases/download/acestep-v3/ace_dit_ane_c2.mlmodelc__weights__weight.bin")
    }
    func testDownloadHasHonestSpaceRequirement() {
        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = PhoneSongAsset.downloadBytes
        XCTAssertGreaterThan(bytes, 9_000_000_000)
        XCTAssertLessThan(bytes, 10_000_000_000)
        XCTAssertEqual(PhoneSongAsset.requiredSpace(at: missingRoot), bytes + 1_000_000_000)
    }
    func testIncompleteFileIsNeverConsideredInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = PhoneSongAsset(path: "small.bin", bytes: 4, release: "acestep-v2")
        XCTAssertFalse(file.present(at: root))
        try Data([1, 2]).write(to: root.appendingPathComponent(file.path))
        XCTAssertFalse(file.present(at: root))
        try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent(file.path))
        XCTAssertTrue(file.present(at: root))
    }
}
