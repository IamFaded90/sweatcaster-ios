// Exercises pairing storage using isolated Keychain accounts.
import Foundation
import Security
import XCTest
@testable import SweatCaster

final class PairingKeychainTests: XCTestCase {
    private let currentService = "dk.fadedai.pairing"
    private let legacyService = "AI Sweat-Caster pairing v1"

    func testDeviceOnlyItemIsUpdatedForSameAccount() throws {
        let account = "fadedai-test-\(UUID())"
        try requireKeychain(account)
        defer { cleanup(account) }

        try PairingKeychain.save("fixture-first", for: account)
        try PairingKeychain.save("fixture-updated", for: account)

        XCTAssertEqual(try PairingKeychain.load(account), "fixture-updated")
        var lookup = query(currentService, account: account)
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, account)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testLegacyItemMigratesAndRemovesOldCopy() throws {
        let account = "fadedai-test-\(UUID())"
        try requireKeychain(account)
        defer { cleanup(account) }

        var item = query(legacyService, account: account)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = Data("fixture-legacy".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(try PairingKeychain.load(account), "fixture-legacy")
        XCTAssertEqual(SecItemCopyMatching(query(currentService, account: account) as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(SecItemCopyMatching(query(legacyService, account: account) as CFDictionary, nil), errSecItemNotFound)
    }

    func testUnknownAccountReturnsMissingToken() throws {
        let account = "fadedai-test-\(UUID())"
        try requireKeychain(account)
        XCTAssertThrowsError(try PairingKeychain.load(account)) { error in
            guard case .token? = error as? APIError else { return XCTFail("Expected a missing pairing token") }
        }
    }

    private func query(_ service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func requireKeychain(_ account: String) throws {
        let status = SecItemCopyMatching(query(currentService, account: account) as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw XCTSkip("Test host has no Keychain entitlement") }
        XCTAssertEqual(status, errSecItemNotFound)
    }

    private func cleanup(_ account: String) {
        for service in [currentService, legacyService] {
            SecItemDelete(query(service, account: account) as CFDictionary)
        }
    }
}
