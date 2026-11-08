// Covers search ranking, token matching, result limits and duplicate IDs.
import XCTest
@testable import SweatCaster

final class FadedSearchTests: XCTestCase {
    func testRanksExactPrefixSubstringAndMetadataInThatOrder() {
        let records = [
            FadedSearchRecord(id: "metadata", category: .note, title: "Plan", keywords: "café", destination: .note),
            FadedSearchRecord(id: "substring", category: .note, title: "Min café", destination: .note),
            FadedSearchRecord(id: "prefix", category: .note, title: "Café næste uge", destination: .note),
            FadedSearchRecord(id: "exact", category: .note, title: "Café", destination: .note)
        ]
        XCTAssertEqual(FadedSearchIndex(records: records).matches("  CAFE\n").map(\.id),
                       ["exact", "prefix", "substring", "metadata"])
    }

    func testMatchesEveryWordAcrossTitleAndMetadata() {
        let records = [
            FadedSearchRecord(id: "both", category: .video, title: "Fortnite", detail: "Nyt klip", destination: .video(jobID: "job-a")),
            FadedSearchRecord(id: "one", category: .video, title: "Fortnite", destination: .video(jobID: "job-b"))
        ]
        let index = FadedSearchIndex(records: records)
        XCTAssertEqual(index.matches("fortnite\t klip").map(\.id), ["both"])
        XCTAssertTrue(index.matches(" \t\n ").isEmpty)
    }

    func testKeepsFirstRecordForDuplicateIDAndBoundsResults() {
        let first = FadedSearchRecord(id: "same", category: .file, title: "Rapport 0", destination: .file(path: "first.txt"))
        let duplicate = FadedSearchRecord(id: "same", category: .file, title: "Rapport", destination: .file(path: "duplicate.txt"))
        let additional = (1...100).map {
            FadedSearchRecord(id: "record-\($0)", category: .file, title: "Rapport \($0)", destination: .file(path: nil))
        }
        let matches = FadedSearchIndex(records: [first, duplicate] + additional).matches("rapport")
        XCTAssertEqual(matches.count, FadedSearchIndex.limit)
        XCTAssertEqual(matches.first, first)
        XCTAssertEqual(matches.last?.id, "record-79")
    }
}
