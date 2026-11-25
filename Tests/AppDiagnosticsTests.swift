import Foundation
import XCTest
@testable import SweatCaster

final class AppDiagnosticsTests: XCTestCase {
    @MainActor func testLocalErrorsHaveDifferentReasonsAndCancellationAddsNothing() async throws {
        let restore = isolateDiagnostics()
        defer { restore() }
        AppDiagnostics.record(LocalComputeError.busy)
        AppDiagnostics.record(LocalComputeError.lowMemory)
        let beforeCancellation = entries
        AppDiagnostics.record(CancellationError())
        AppDiagnostics.record(URLError(.cancelled))

        XCTAssertEqual(entries, beforeCancellation)
        XCTAssertEqual(entries.count, 2)
        let exported = try exportText()
        XCTAssertTrue(exported.contains("Lokal AI · Optaget — prøv igen, når den aktuelle opgave er færdig"))
        XCTAssertTrue(exported.contains("Lokal AI · For lidt ledig RAM"))
        XCTAssertFalse(exported.contains("App-fejl · LocalComputeError"))
    }

    @MainActor func testPrivateErrorPayloadsAreNotIncludedInExport() async throws {
        let restore = isolateDiagnostics()
        defer { restore() }
        let secret = "private-prompt-and-token-" + UUID().uuidString
        AppDiagnostics.record(NSError(domain: secret, code: 42, userInfo: [
            NSLocalizedDescriptionKey: secret,
            NSUnderlyingErrorKey: NSError(domain: secret, code: 7)
        ]))
        AppDiagnostics.record(APIError.http(503, Problem(code: secret, message: secret)))
        AppDiagnostics.record(V2Failure.http(status: 429, code: secret, message: secret))
        AppDiagnostics.record(APIError.addressLeadingZeros(secret))

        let exported = try exportText()
        XCTAssertFalse(exported.contains(secret))
        XCTAssertTrue(exported.contains("APIError HTTP 503"))
        XCTAssertTrue(exported.contains("V2Failure HTTP 429"))
        XCTAssertTrue(exported.contains("App-fejl · NSError"))
    }

    @MainActor func testExportSeparatesRecordedFailureFromCurrentMemoryReading() async throws {
        let restore = isolateDiagnostics()
        defer { restore() }
        let mib: UInt64 = 1_048_576
        AppDiagnostics.recordLowMemory(requiredMiB: 4096, availableBytes: 1536 * mib,
                                       footprintBytes: 768 * mib)
        let recorded = entries

        let exported = try exportText()
        let sections = exported.components(separatedBy: "\n\n")
        XCTAssertGreaterThanOrEqual(sections.count, 2)
        let header = sections.first ?? ""
        let history = sections.dropFirst().joined(separator: "\n\n")
        XCTAssertTrue(header.contains("RAM ved eksport · ikke en måling fra fejltidspunktet"))
        XCTAssertTrue(header.contains("FadedAIs RAM · "))
        XCTAssertTrue(header.contains("Anslået RAM-råderum · "))
        XCTAssertFalse(header.contains("krævet 4096 MiB"))
        XCTAssertTrue(history.contains("Lokal AI · For lidt RAM ved start · krævet 4096 MiB · råderum 1536 MiB · forbrug 768 MiB"))
        XCTAssertFalse(history.contains("RAM ved eksport"))
        XCTAssertEqual(entries, recorded, "En eksport må ikke ændre de historiske RAM-målinger.")
    }

    @MainActor func testMissingFootprintIsNotReportedAsZero() async throws {
        let restore = isolateDiagnostics()
        defer { restore() }
        AppDiagnostics.recordLowMemory(requiredMiB: 4096, availableBytes: 0, footprintBytes: nil)
        let history = entries.joined(separator: "\n")
        XCTAssertTrue(history.contains("råderum 0 MiB"))
        XCTAssertTrue(history.contains("forbrug ukendt"))
        XCTAssertFalse(history.contains("forbrug 0 MiB"))
    }

    @MainActor func testFailedPreflightRecordsRequiredMemoryWithoutLoadingModel() async throws {
        let restore = isolateDiagnostics()
        defer { restore() }
        LocalCompute.resume()
        var started = false
        do {
            try await LocalCompute.run(minimumMiB: 1_000_000) {
                started = true
            }
            XCTFail("En umulig RAM-anmodning skal afvises før modellen indlæses.")
        } catch LocalComputeError.lowMemory {
            // This is a rejection before model loading, not an allocation stress test.
        } catch {
            XCTFail("Forventede RAM-afvisning, fik \(type(of: error)).")
        }
        XCTAssertFalse(started)
        XCTAssertFalse(LocalCompute.isRunning)
        XCTAssertTrue(entries.contains { $0.contains("krævet 1000000 MiB") })
    }

    private var entries: [String] {
        UserDefaults.standard.stringArray(forKey: AppStorageKeys.diagnosticsApiV1) ?? []
    }

    private func isolateDiagnostics() -> () -> Void {
        let defaults = UserDefaults.standard
        let key = AppStorageKeys.diagnosticsApiV1
        let original = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        return {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    @MainActor private func exportText() throws -> String {
        let url = try AppDiagnostics.export(phoneModel: "Apple Foundation Models", pcConnected: false)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
