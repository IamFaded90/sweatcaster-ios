// Exercises file-picker behavior with temporary files and no Photos permission.
import Foundation
import XCTest
@testable import SweatCaster

final class PickerConnectorTests: XCTestCase {
    @MainActor func testFilesAreListedSearchedFetchedAndCleared() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Rapport.txt")
        let bytes = Data("Lokalt indhold".utf8)
        try bytes.write(to: url)
        let connector = PickerConnector(source: .files)

        try await connector.connect()
        XCTAssertTrue(connector.showPicker)
        connector.pickFile(.success(url))
        try await waitForRead(connector)

        XCTAssertEqual(connector.status, .selected(1))
        let records = try await connector.list(path: "/")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.name, "Rapport.txt")
        XCTAssertEqual(record.size, bytes.count)
        let matches = try await connector.search(query: "RAPPORT")
        XCTAssertEqual(matches.map(\.id), [record.id])
        let missing = try await connector.search(query: "andre filer")
        XCTAssertTrue(missing.isEmpty)
        let content = try await connector.fetch(id: record.id)
        XCTAssertEqual(content, bytes)

        await connector.disconnect()
        XCTAssertEqual(connector.status, .ready)
        let cleared = try await connector.list(path: "")
        XCTAssertTrue(cleared.isEmpty)
        do {
            _ = try await connector.fetch(id: record.id)
            XCTFail("Disconnected records must not remain accessible")
        } catch {}
    }

    @MainActor func testFilesRejectOversizedInputWithoutLosingValidSelection() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appending(path: "small.txt")
        let large = folder.appending(path: "large.txt")
        try Data("keep".utf8).write(to: small)
        try Data(repeating: 0, count: 5_000_001).write(to: large)
        let connector = PickerConnector(source: .files)

        connector.pickFile(.success(small))
        try await waitForRead(connector)
        let original = try await connector.list(path: "")
        connector.pickFile(.success(large))
        try await waitForRead(connector)

        XCTAssertEqual(connector.notice, "Filen er for stor til en lokal forhåndsvisning.")
        let retained = try await connector.list(path: "")
        XCTAssertEqual(retained.map(\.id), original.map(\.id))
        XCTAssertEqual(retained.first?.name, "small.txt")
    }

    @MainActor func testPickerCannotBrowsePathsOrUpload() async throws {
        for source in [PickerConnector.Source.files, .photos] {
            let connector = PickerConnector(source: source)
            do {
                _ = try await connector.list(path: "../Documents")
                XCTFail("A picker may only list user-selected records")
            } catch {}
            do {
                try await connector.upload(data: Data("fixture".utf8), path: "/")
                XCTFail("Picker connectors are read-only")
            } catch {}
        }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @MainActor private func waitForRead(_ connector: PickerConnector) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while connector.loading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(connector.loading, "Picker file read did not finish in time")
    }
}
