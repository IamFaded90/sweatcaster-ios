// Tests the scanner acceptance path separately from structural QR parsing.
import Foundation
import XCTest
@testable import SweatCaster

final class PairingQRCodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    @MainActor func testScannerAcceptsFractionalExpiryAndCanonicalizesAddress() throws {
        let expiry = now.addingTimeInterval(30.125)
        let payload = try PairingQRSession.accept(qr(address: "http://100.64.1.42:8765/api/v1", expiry: expiry), now: now)
        XCTAssertEqual(payload.address, "100.64.1.42")
        XCTAssertEqual(try Server(payload.address).profile, .tailscale)
        XCTAssertEqual(try XCTUnwrap(payload.expiresAt).timeIntervalSince(now), 30.125, accuracy: 0.001)
    }

    @MainActor func testScannerRejectsMissingPastAndExactExpiry() throws {
        for expiry in [nil, now.addingTimeInterval(-1), now] as [Date?] {
            let text = try qr(expiry: expiry)
            XCTAssertThrowsError(try PairingQRSession.accept(text, now: now)) { error in
                guard case .pairingExpired? = error as? APIError else { return XCTFail("Expected an expired QR code") }
            }
        }
    }

    @MainActor func testScannerRejectsReusedNonceEvenWhenAddressChanges() throws {
        let nonce = UUID().uuidString
        let expiry = now.addingTimeInterval(60)
        let first = try qr(expiry: expiry, nonce: nonce)
        let reused = try qr(address: "192.168.1.99", expiry: expiry, nonce: nonce)
        XCTAssertEqual(try PairingQRSession.accept(first, now: now).nonce, nonce)
        XCTAssertThrowsError(try PairingQRSession.accept(reused, now: now)) { error in
            guard case .replay? = error as? PairingQRSession.Failure else { return XCTFail("Expected a nonce replay") }
        }
    }

    @MainActor func testOptionalNonceAndInvalidTimestamp() throws {
        let valid = try qr(expiry: now.addingTimeInterval(60))
        XCTAssertNil(try PairingQRSession.accept(valid, now: now).nonce)
        XCTAssertNoThrow(try PairingQRSession.accept(valid, now: now))
        let invalid = #"{"version":1,"address":"192.168.1.42","token":"fixture","expiresAt":"tomorrow"}"#
        XCTAssertThrowsError(try PairingQRSession.accept(invalid, now: now))
    }

    private func qr(address: String = "192.168.1.42", expiry: Date?, nonce: String? = nil) throws -> String {
        var fields: [String: Any] = ["version": 1, "address": address, "token": "fixture"]
        if let expiry {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields["expiresAt"] = formatter.string(from: expiry)
        }
        if let nonce { fields["nonce"] = nonce }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return String(decoding: data, as: UTF8.self)
    }
}
