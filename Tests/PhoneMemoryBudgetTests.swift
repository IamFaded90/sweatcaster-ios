import XCTest
@testable import SweatCaster

final class PhoneMemoryBudgetTests: XCTestCase {
    func testFluxDownloadBudgetsForAllThreeFilesAndInstallationSpace() {
        let flux = StudioImageModel.fluxKlein
        XCTAssertEqual(flux.downloadFiles.reduce(Int64.zero) { $0 + $1.bytes }, 8_743_059_456)
        let missingBytes = flux.downloadFiles.filter { !$0.isPresent }.reduce(Int64.zero) { $0 + $1.bytes }
        XCTAssertEqual(flux.minimumFreeBytes, missingBytes + 1_000_000_000)
    }

    func testTruncatedImageDependencyIsNotReady() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        try Data(repeating: 0, count: 63).write(to: url)
        XCTAssertFalse(file.matchesSize(at: url))
        try Data(repeating: 0, count: 64).write(to: url)
        XCTAssertTrue(file.matchesSize(at: url))
    }

    func testCachedSizeDoesNotHideCompletedImageDependency() throws {
        var url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        try Data(repeating: 0, count: 64).write(to: url)
        url.setTemporaryResourceValue(63, forKey: .fileSizeKey)
        XCTAssertTrue(file.matchesSize(at: url))
        try Data(repeating: 0, count: 63).write(to: url)
        url.setTemporaryResourceValue(64, forKey: .fileSizeKey)
        XCTAssertFalse(file.matchesSize(at: url))
    }

    func testImageDependencyRequiresRegularFileWithExactSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        let url = root.appendingPathComponent(file.name)
        try Data(repeating: 0, count: 65).write(to: url)
        XCTAssertFalse(file.matchesSize(at: url))
        try Data(repeating: 0, count: 64).write(to: url)
        let link = root.appendingPathComponent("link.ckpt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertFalse(file.matchesSize(at: link))
        XCTAssertFalse(file.matchesSize(at: root))
        XCTAssertFalse(file.matchesSize(at: root.appendingPathComponent("missing.ckpt")))
    }

    func testOtherAppsCanReduceBudgetEvenOnLargePhone() {
        let result = PhoneMemoryBudget.assess(required: 3_000_000_000, physical: 12_000_000_000, available: 2_000_000_000)
        XCTAssertEqual(result.fit, .unavailable)
        XCTAssertEqual(result.recommendedBytes, 2_000_000_000)
    }

    func testConservativeEstimateDoesNotBlockOtherwiseLoadableModel() {
        let result = PhoneMemoryBudget.assess(required: 8_000_000_000, physical: 12_000_000_000, available: 9_000_000_000)
        XCTAssertEqual(result.fit, .tight)
    }

    func testSmallModelAndUnknownMemory() {
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1_000_000_000, physical: 8_000_000_000, available: 5_000_000_000).fit, .comfortable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1, physical: 0, available: 0).fit, .unavailable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 0, physical: 8_000_000_000, available: 5_000_000_000).fit, .unavailable)
    }
}
