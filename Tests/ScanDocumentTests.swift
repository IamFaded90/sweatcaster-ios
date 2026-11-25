import XCTest
@testable import SweatCaster

final class ScanDocumentTests: XCTestCase {
    func testReceiptTotalsKeepPrintedValueAndExactEvidence() {
        let text = "BUTIK\nSubtotal 90,00\nMoms 22,50\nI ALT: 112,50 kr.\nTotal: EUR 12.00"
        let amounts = ScanDocument.amounts(in: text)
        XCTAssertEqual(amounts.first?.value, "112,50 kr."); XCTAssertEqual(amounts.first?.quote, "I ALT: 112,50 kr.")
        XCTAssertFalse(amounts.contains { $0.quote.contains("Subtotal") || $0.quote.contains("Moms") })
    }
    func testQRNeverAutomaticallyTurnsWiFiOrExecutableSchemesIntoLinks() {
        XCTAssertNotNil(ScanDocument.qrURL("https://example.com/help"))
        for value in ["javascript:alert(1)", "WIFI:T:WPA;S:net;P:password;;", "https://user:password@example.com", "https://example.com\n"] { XCTAssertNil(ScanDocument.qrURL(value)) }
    }
    func testScopedPDFCopiesRequireValidHeaderAndKeepOtherAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanDocument.Store(botID: UUID(), base: root), other = ScanDocument.Store(botID: UUID(), base: root)
        let record = ScanDocument.Record(title: "Kvittering", text: "I alt: 112,50", pages: 1, totals: [])
        XCTAssertThrowsError(try store.save(record, pdf: Data("bad".utf8)))
        try store.save(record, pdf: Data("%PDF-test fixture".utf8)); try other.save(record, pdf: Data("%PDF-test fixture".utf8))
        XCTAssertThrowsError(try store.save(record, pdf: Data("%PDF-test fixture".utf8)))
        try store.remove(record.id); XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(record.id).path)); XCTAssertEqual(try other.load().count, 1)
    }
}
