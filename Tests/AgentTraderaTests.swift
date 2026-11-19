import Foundation
import XCTest
@testable import SweatCaster

final class AgentTraderaTests: XCTestCase {
    func testWatchRequestsAndQuestions() {
        for phrase in ["hold øje med denne tradera-annonce", "kan du holde øje med prisen på tradera",
                       "giv mig besked, hvis tradera-prisen er under 450 dkk", "opret en prisvagt",
                       "https://www.tradera.com/da/item/100/123456789/cykel?ref=mail"] {
            guard case .traderaWatch? = AgentTraderaIntent.match(phrase) else { return XCTFail(phrase) }
        }
        for phrase in ["vis mine prisvagter", "kan du vise mine tradera-prisvagter"] {
            guard case .traderaWatches? = AgentTraderaIntent.match(phrase) else { return XCTFail(phrase) }
        }
        for question in ["hvordan laver jeg en prisvagt", "hold ikke øje med tradera", "hold øje med min mail"] {
            XCTAssertNil(AgentTraderaIntent.match(question))
        }
    }

    func testListingLinksAreCleanAndSpecific() {
        let url = "https://www.tradera.com/da/item/100/123456789/cykel"
        XCTAssertEqual(AgentTraderaIntent.listingInPrompt("Hold øje med \(url)?ref=mail#pris.")?.absoluteString, url)
        XCTAssertNotNil(AgentTraderaIntent.listing("https://tradera.com/item/100/123456789"))
        for bad in ["https://tradera.com.evil.example/item/1/2", "https://x@tradera.com/item/1/2",
                    "http://tradera.com/item/1/2", "https://tradera.com/search", "https://tradera.com/item/12345"] {
            XCTAssertNil(AgentTraderaIntent.listing(bad))
        }
    }

    func testDKKAndSEKAreExplicit() {
        let dkk = AgentTraderaIntent.limit(in: "Giv besked under 1.299,95 danske kroner")
        XCTAssertEqual(dkk.currency, "DKK")
        XCTAssertEqual(AgentTraderaIntent.amount(dkk.amount), 1299.95)
        XCTAssertEqual(AgentTraderaIntent.limit(in: "mindre end 600 SEK").currency, "SEK")
        XCTAssertEqual(AgentTraderaIntent.limit(in: "under 600 kr.").currency, "")
        XCTAssertEqual(AgentTraderaIntent.limit(in: "under 80 euro").amount, "")
        XCTAssertEqual(AgentTraderaIntent.limit(in: "under 300 norske kroner").amount, "")
        XCTAssertEqual(AgentTraderaIntent.limit(in: "se denne annonce").amount, "")
        for bad in ["0", "-1", "1,3456", "1e4", "1000000000"] { XCTAssertNil(AgentTraderaIntent.amount(bad)) }
    }

    func testWatchSourceDependsOnActualPCSupport() throws {
        func access(_ json: String) throws -> AgentTraderaAccess {
            try JSONDecoder().decode(AgentTraderaAccess.self, from: Data(json.utf8))
        }
        let connected = try access(#"{"configured":false,"mailAvailable":true}"#)
        XCTAssertEqual(connected.suggested, .traderaMail)
        XCTAssertTrue(connected.ready(.traderaMail))
        XCTAssertFalse(connected.ready(.api))
        let needsLogin = try access(#"{"configured":false,"mailAvailable":false}"#)
        XCTAssertEqual(needsLogin.suggested, .traderaMail)
        XCTAssertFalse(needsLogin.ready(.traderaMail))
        let alreadySetUp = try access(#"{"configured":true,"mailAvailable":true}"#)
        XCTAssertEqual(alreadySetUp.suggested, .api)
        XCTAssertTrue(alreadySetUp.ready(.traderaMail))
        let olderPC = try access(#"{"configured":true}"#)
        XCTAssertEqual(olderPC.suggested, .api)
        XCTAssertFalse(olderPC.ready(.traderaMail))
    }

    func testExplicitCurrencyWinsOverPersonalAndSharedWishes() {
        let wishes = ["jeg foretrækker priser i danske kroner", "mine prisvagter skal bruge SEK"]
        XCTAssertEqual(AgentTraderaIntent.currency(for: "SEK", wishes: wishes), "SEK")
        XCTAssertEqual(AgentTraderaIntent.currency(for: "", wishes: wishes), "DKK")
        XCTAssertEqual(AgentTraderaIntent.currency(for: "", wishes: ["jeg vil ikke have priser i SEK"]), "")
        XCTAssertEqual(AgentTraderaIntent.currency(for: "", wishes: ["jeg vil sammenligne priser i DKK og SEK"]), "")
        XCTAssertEqual(AgentTraderaIntent.currency(for: "", wishes: ["jeg har 350 danske kroner til frokost"]), "")
    }

    func testMailObservationKeepsItsSourceAndTime() throws {
        let json = """
        {"id":"16841369-F412-49C7-B6B3-E1548976B184","url":"https://tradera.com/item/1/2","title":"Cykel",
         "state":"waitingMail","threshold":350,"currency":"DKK","source":"traderaMail","priceAt":null}
        """
        let waiting = try JSONDecoder().decode(AgentTraderaItem.self, from: Data(json.utf8))
        XCTAssertTrue(waiting.awaitsUpdate)
        XCTAssertTrue(waiting.stateLabel.contains("Venter på en mail"))
        XCTAssertNil(waiting.price)
        let received = json.replacingOccurrences(of: "waitingMail", with: "triggered").replacingOccurrences(of: "null", with: "100")
        let alert = try JSONDecoder().decode(AgentTraderaItem.self, from: Data(received.utf8))
        XCTAssertEqual(alert.source, .traderaMail)
        XCTAssertEqual(alert.priceAt, 100)
        XCTAssertTrue(alert.stateLabel.contains("Tradera skrev"))
    }

    func testStoredWatchCanBeReopenedWithOrWithoutPrice() throws {
        func item(_ state: String, _ price: String, _ email: String) throws -> AgentTraderaItem {
            let json = """
            {"id":"16841369-F412-49C7-B6B3-E1548976B184","url":"https://tradera.com/item/1/2",
             "title":"Cykel","state":"\(state)","threshold":350,"currency":"DKK",
             "price":\(price),"priceCurrency":"SEK","emailStatus":"\(email)"}
            """
            return try JSONDecoder().decode(AgentTraderaItem.self, from: Data(json.utf8))
        }
        let active = try item("watching", "400", "off")
        XCTAssertEqual(active.price, 400)
        XCTAssertTrue(active.awaitsUpdate)
        let notified = try item("triggered", "0", "sent")
        XCTAssertEqual(notified.price, 0)
        XCTAssertFalse(notified.awaitsUpdate)
        XCTAssertTrue(try item("triggered", "300", "waiting").awaitsUpdate)
        let cancelled = try item("cancelled", "null", "off")
        XCTAssertNil(cancelled.price)
        XCTAssertFalse(cancelled.awaitsUpdate)
    }
}
