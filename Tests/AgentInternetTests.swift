import Foundation
import XCTest
@testable import SweatCaster

final class AgentInternetTests: XCTestCase {
    func testEmptyInboxIsDistinctFromInvalidResponse() throws {
        XCTAssertTrue(try AgentInternetPayload.mails(["messages": [[String: Any]]()]).isEmpty)
        XCTAssertThrowsError(try AgentInternetPayload.mails(["error": "not authorized"]))
        XCTAssertThrowsError(try AgentInternetPayload.mails(["messages": [["id": "../invalid"]]]))
        let mails = try AgentInternetPayload.mails(["messages": [
            ["messageId": "abc123", "subject": "Fredag", "sender": "Test", "threadId": "def456"],
            ["messageId": "abc123", "subject": "Dublet"], ["id": "abc124", "subject": "Lørdag"]
        ]])
        XCTAssertEqual(mails.map(\.id), ["abc123", "abc124"])
        XCTAssertEqual(mails.first?.threadID, "def456")
    }

    func testMailBodyUsesRequestedMessageAndPrefersPlainTextOverHTML() throws {
        let plain = "Mødet er fredag klokken 14."
        let encoded = Data(plain.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let mail: [String: Any] = ["messageId": "abc123", "threadId": "def456", "payload": [
            "mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/html", "body": ["data": Data("<p>HTML</p>".utf8).base64EncodedString()]],
                ["mimeType": "text/plain", "body": ["data": encoded]]
            ]
        ]]
        XCTAssertEqual(try AgentInternetPayload.message(mail, expectedID: "abc123").text, plain)
        XCTAssertThrowsError(try AgentInternetPayload.message(mail, expectedID: "another"))
        XCTAssertThrowsError(try AgentInternetPayload.message(["messageText": plain], expectedID: "abc123"))
    }

    func testHTMLMailNeverExecutesOrIncludesTrackingCodeAndExcerptIsLabelled() throws {
        let html = "<style>hidden CSS</style><script>tracking()</script><p>Hej &amp; tak</p><img src='https://example.com/pixel'>"
        let mail: [String: Any] = ["id": "abc123", "payload": ["mimeType": "text/html",
            "body": ["data": Data(html.utf8).base64EncodedString()]]]
        XCTAssertEqual(try AgentInternetPayload.message(mail, expectedID: "abc123").text, "Hej & tak")
        let excerpt = try AgentInternetPayload.message(["id": "abc123", "snippet": "Hej"], expectedID: "abc123")
        XCTAssertTrue(excerpt.text.hasPrefix("Kort uddrag"))
        let large = try AgentInternetPayload.message(["id": "abc123", "messageText": String(repeating: "x", count: 13_000)], expectedID: "abc123")
        XCTAssertTrue(large.text.hasSuffix("Resten kan læses i Gmail."))
    }

    func testSourcesAreDeduplicatedAndSnippetsAreNotClaimedAsFullPages() throws {
        let rows: [[String: Any]] = [
            ["url": "https://example.com/news", "title": "Nyhed", "content": "Et kildeuddrag"],
            ["url": "https://example.com/news", "content": "Gentaget"],
            ["url": "javascript:alert(1)", "content": "Ikke en kilde"],
            ["url": "https://secret@example.com", "content": "Ikke en kilde"],
            ["url": "https://example.com/empty", "content": ""]
        ]
        let pages = try AgentInternetPayload.pages(["response_data": ["results": rows]], extracted: false)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].text, "Et kildeuddrag")
        XCTAssertFalse(pages[0].readPage)
        XCTAssertThrowsError(try AgentInternetPayload.pages(["results": rows], extracted: true))
        XCTAssertThrowsError(try AgentInternetPayload.pages(["error": "quota"], extracted: false))
    }

    func testInstantSearchCannotSilentlySpendBalance() {
        XCTAssertFalse(AgentInternetPayload.searchNeedsConsent(["has_active_connection": true], slug: "TAVILY_SEARCH"))
        XCTAssertTrue(AgentInternetPayload.searchNeedsConsent(["instant_account": [:]], slug: "TAVILY_SEARCH"))
        XCTAssertTrue(AgentInternetPayload.searchNeedsConsent(["instant_account": ["prices": [
            "TAVILY_SEARCH": ["discount": "50"]]]], slug: "TAVILY_SEARCH"))
        XCTAssertFalse(AgentInternetPayload.searchNeedsConsent(["instant_account": ["prices": [
            "TAVILY_SEARCH": ["discount": "100"]]]], slug: "TAVILY_SEARCH"))
    }

    @MainActor func testReadUsesPCWhenAvailableAndPhoneOnceWhenPCIsOffline() async throws {
        var calls = 0
        let pc = try await AgentInternetRead.run(phoneAvailable: true, computer: { "PC" }, mayFallback: { _ in true }) {
            calls += 1; return "iPhone"
        }
        XCTAssertEqual(pc, "PC")
        XCTAssertEqual(calls, 0)
        let phone: String = try await AgentInternetRead.run(phoneAvailable: true,
            computer: { throw URLError(.cannotConnectToHost) }, mayFallback: { _ in true }) {
                calls += 1; return "iPhone"
            }
        XCTAssertEqual(phone, "iPhone")
        XCTAssertEqual(calls, 1)
        let direct = try await AgentInternetRead.run(phoneAvailable: true, computer: nil, mayFallback: { _ in false }) { "direct" }
        XCTAssertEqual(direct, "direct")
    }

    @MainActor func testCancellationAndRejectedAccessNeverTriggerAnotherRequest() async {
        for error in [URLError(.cancelled), URLError(.userAuthenticationRequired)] {
            var calls = 0
            do {
                let _: String = try await AgentInternetRead.run(phoneAvailable: true,
                    computer: { throw error }, mayFallback: { _ in error.code == .cancelled }) {
                        calls += 1; return "unexpected"
                    }
                XCTFail("A cancelled or rejected lookup must fail")
            } catch { }
            XCTAssertEqual(calls, 0)
        }
        var calls = 0
        do {
            let _: String = try await AgentInternetRead.run(phoneAvailable: false,
                computer: { throw URLError(.cannotConnectToHost) }, mayFallback: { _ in true }) {
                    calls += 1; return "unexpected"
                }
        } catch { }
        XCTAssertEqual(calls, 0)
    }
}
