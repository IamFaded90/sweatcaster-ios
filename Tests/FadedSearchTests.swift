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

final class AgentDocumentSearchTests: XCTestCase {
    func testOversizedPassagesDoNotHideLaterEvidenceOrExceedBudget() {
        let question = "Hvad siger notatet?"
        func hit(_ id: Int, _ text: String) -> AgentDocumentMatch {
            .init(source: .init(id: id, name: "Notat", page: id), text: text)
        }
        let firstFit = hit(2, "Første relevante uddrag: øvelse.")
        let secondFit = hit(3, "Andet relevante uddrag: 🟢.")
        let exactLimit = (question + "\n\n" + AgentDocumentMatch.promptContext([firstFit, secondFit])).unicodeScalars.count
        let oversized = hit(1, String(repeating: "x", count: exactLimit))
        let overflow = hit(4, "Et uddrag mere, som ikke længere passer.")
        let packet = AgentDocumentMatch.request(question: question, matches: [oversized, firstFit, secondFit, overflow], limit: exactLimit)
        XCTAssertEqual(packet.sources.map(\.id), [2, 3])
        XCTAssertEqual(packet.sources.compactMap(\.excerpt), [firstFit.text, secondFit.text])
        XCTAssertEqual(packet.prompt.unicodeScalars.count, exactLimit)
        XCTAssertFalse(packet.prompt.contains(overflow.text))
        XCTAssertTrue(packet.prompt.contains("[2] " + firstFit.text))
        XCTAssertTrue(packet.prompt.contains("[3] " + secondFit.text))

        let roomForFirst = (question + "\n\n" + AgentDocumentMatch.promptContext([firstFit])).unicodeScalars.count
        let priority = AgentDocumentMatch.request(question: question, matches: [firstFit, secondFit], limit: roomForFirst)
        XCTAssertEqual(priority.sources.map(\.id), [2])
        XCTAssertLessThanOrEqual(priority.prompt.unicodeScalars.count, roomForFirst)
    }

    func testDocumentOverviewAndFollowUpKeepPageEvidence() throws {
        let texts = ["Prøveplan for november", "Adgangskoden er gråspurv.", "Første møde i Farsø",
                     "Revision i marts", "Året afsluttes i Odense."]
        let doc = AgentDocument(id: UUID(), name: "Plan.pdf", model: nil, passages: texts.enumerated().map {
            .init(page: $0.offset + 1, text: $0.element, vector: nil)
        })
        for question in ["Opsummér dokumentet", "Kan du give mig et kort resumé af brevet?", "What is this about?"] {
            let matches = try AgentDocumentIndex.matches(question, document: doc)
            let packet = AgentDocumentMatch.request(question: question, matches: matches, limit: 2_000)
            XCTAssertEqual(packet.sources.compactMap(\.page), [1, 3, 5])
            for source in packet.sources {
                let excerpt = try XCTUnwrap(source.excerpt)
                XCTAssertTrue(packet.prompt.contains("[\(source.id)] " + excerpt))
                XCTAssertEqual(excerpt, texts[try XCTUnwrap(source.page) - 1])
            }
        }
        let targeted = try AgentDocumentIndex.matches("Opsummér afsnittet om adgangskoden", document: doc)
        XCTAssertEqual(targeted.map(\.source.page), [2])
        XCTAssertTrue(try AgentDocumentIndex.matches("Vandtemperatur?", document: doc).isEmpty)
    }

    func testDocumentCitationsUseWholeExcerptsWithinTheComputerLimit() throws {
        let evidence = String(repeating: "ø", count: 463) + " kode 781"
        let doc = AgentDocument(id: UUID(), name: "Notat.txt", model: nil, passages: [
            .init(page: nil, text: evidence, vector: nil), .init(page: nil, text: evidence + "B", vector: nil)
        ])
        let question = "kode " + String(repeating: "å", count: 1_195)
        let matches = try AgentDocumentIndex.matches(question, document: doc)
        let packet = AgentDocumentMatch.request(question: question, matches: matches, limit: 2_000)
        XCTAssertEqual(packet.sources.count, 1)
        XCTAssertEqual(packet.sources.first?.excerpt, evidence)
        XCTAssertTrue(packet.prompt.hasSuffix(evidence))
        XCTAssertLessThanOrEqual(packet.prompt.unicodeScalars.count, 2_000)
        let legacy = try JSONDecoder().decode(AgentDocumentSource.self, from: Data(#"{"id":1,"name":"Brev","page":1}"#.utf8))
        XCTAssertNil(legacy.excerpt)
    }
}
