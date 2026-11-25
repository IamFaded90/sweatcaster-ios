import XCTest
@testable import SweatCaster

final class ProductHuntTests: XCTestCase {
    private func html(_ value: String) -> String { "<script type='application/ld+json'>\(value)</script>" }
    func testPriceMustBelongToOneProductAndOneExplicitOffer() {
        let offer = ProductOffer.read(html: html(#"{"@type":"Product","name":"Grøn stol","offers":{"@type":"Offer","price":"1499.00","priceCurrency":"DKK"}}"#))
        XCTAssertEqual(offer?.amount, 1499)
        XCTAssertEqual(offer?.currency, "DKK")
        XCTAssertNil(ProductOffer.read(html: "Grøn stol. Før 1999 kr, nu 1499 kr. Fragt 49 kr."))
        XCTAssertNil(ProductOffer.read(html: html(#"{"@type":"Product","name":"Stol","offers":{"@type":"AggregateOffer","lowPrice":"999","priceCurrency":"DKK"}}"#)))
        XCTAssertNil(ProductOffer.read(html: html(#"{"@type":"Product","name":"Stol","offers":[{"@type":"Offer","price":"10","priceCurrency":"EUR"},{"@type":"Offer","price":"20","priceCurrency":"EUR"}]}"#)))
    }
    func testUnrelatedProductsAndMalformedPricesAreNotCompared() {
        let product = #"{"@type":"Product","name":"Stol","offers":{"@type":"Offer","price":"12.50","priceCurrency":"EUR"}}"#
        XCTAssertNil(ProductOffer.read(html: html("[" + product + "," + product + "]")))
        XCTAssertNil(ProductOffer.read(html: html(product.replacingOccurrences(of: "12.50", with: "1,200.00"))))
        XCTAssertNil(ProductOffer.read(html: html(product.replacingOccurrences(of: "EUR", with: "XYZ"))))
    }
    func testCropIsNormalizedClampedAndWorksInEitherDirection() throws {
        let crop = try XCTUnwrap(ProductHunt.Crop.selection(from: .init(x: 120, y: 160), to: .init(x: -10, y: 40), size: .init(width: 200, height: 200)))
        XCTAssertEqual(crop.x, 0); XCTAssertEqual(crop.y, 0.2)
        XCTAssertEqual(crop.width, 0.6); XCTAssertEqual(crop.height, 0.6, accuracy: 0.0001)
        XCTAssertNil(ProductHunt.Crop.selection(from: .zero, to: .init(x: 1, y: 1), size: .init(width: 200, height: 200)))
    }
    func testSaveReopenAndDeletePreserveOtherAgentsAndOriginalPhotos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProductHunt.Store(botID: UUID(), root: root), second = ProductHunt.Store(botID: UUID(), root: root)
        var hunt = ProductHunt(botID: first.botID)
        let match = ProductHunt.Match(title: "Stol", url: URL(string: "https://shop.example.com/stol")!)
        hunt.matches = [match]; hunt.favorite(match); hunt.confirm(match.id)
        try first.save(hunt); try first.savePhoto(Data([1, 2, 3]))
        try second.save(.init(botID: second.botID))
        XCTAssertEqual(try first.load(), hunt)
        XCTAssertTrue(try first.load().favorites[0].identityConfirmed)
        XCTAssertEqual(try first.photo(), Data([1, 2, 3]))
        try first.remove()
        XCTAssertNil(try first.photo()); XCTAssertTrue(try first.load().favorites.isEmpty)
        XCTAssertEqual(try second.load().botID, second.botID)
    }
    func testFindEmailIsNotShoppingAndUnsafeLinksAreNotAccepted() {
        XCTAssertFalse(ProductHunt.command("Find den e-mail fra butikken"))
        XCTAssertTrue(ProductHunt.command("Find den her sko", withPhoto: true))
        XCTAssertTrue(ProductHunt.command("Hvor kan jeg købe den her lampe?"))
        XCTAssertFalse(ProductHunt.publicURL(URL(string: "https://user:pass@shop.example.com/")!))
        XCTAssertFalse(ProductHunt.publicURL(URL(string: "https://127.0.0.1/item")!))
        XCTAssertFalse(ProductHunt.publicURL(URL(string: "https://printer.local/item")!))
    }
}
