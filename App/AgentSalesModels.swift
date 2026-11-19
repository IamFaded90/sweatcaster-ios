import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AgentSalesIntent {
    static func matches(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.range(of: #"\b(?:sælg|sælge)\s+(?:ikke|aldrig)\b"#, options: .regularExpression) == nil else { return false }
        return text.range(of: #"^(?:(?:(?:kan|vil) du (?:lige )?)|(?:jeg vil (?:gerne )?))?(?:sælg|sælge|lav en salgsannonce|vis mine salg|åbn salgsagenten)\b"#,
                          options: .regularExpression) != nil
    }
}

struct AgentSale: Decodable, Identifiable {
    struct Message: Decodable, Identifiable {
        let id: UUID
        let kind, text, buyer, source: String
        let amount: Double?
        let withinLimit: Bool?
    }
    struct Attribute: Codable { let id: Int; var values: [String] }
    struct Shipping: Codable { let shippingProviderId, cost: Int }
    let id, botID: UUID
    let revision, photoCount, bytes: Int
    let title, description, currency, state, shipping: String
    let minimum, asking: Double
    let categoryID, bidderID: Int
    let attributes: [Attribute]
    let shippingOptions: [Shipping]
    let messages: [Message]
    let note, url, agreement, browserGoal: String?
    let priceSEK: Int?
    let transactionID: Int?
    let paid: Bool?

    var stateTitle: String {
        switch state {
        case "draft": "Kladde"
        case "preparing": "Klargøres hos Tradera"
        case "ready": "Klar til at udgive"
        case "publishing": "Afventer Tradera"
        case "published": "Til salg"
        case "agreed": "Aftale gemt"
        case "sold": "Solgt"
        case "shipped": "Afsendt"
        default: "Skal tjekkes"
        }
    }
}

struct AgentSaleAccess: Decodable {
    let configured, hasPublicKey, authorized: Bool
    let alias, expires: String?
}

struct AgentSaleCatalog: Decodable {
    struct Category: Decodable, Identifiable {
        let id: Int
        let name: String?
        let childCategories: [Category]?

        func leaves(prefix: String = "") -> [(Int, String)] {
            let title = prefix + (name ?? "Kategori")
            guard let children = childCategories, !children.isEmpty else { return [(id, title)] }
            return children.flatMap { $0.leaves(prefix: title + " › ") }
        }
    }
    struct Shipping: Decodable, Identifiable { let id, cost: Int; let name: String }
    struct Bidder: Decodable, Identifiable { let id: Int; let description: String? }
    let categories: [Category]
    let shipping: [Shipping]
    let bidders: [Bidder]
}

struct AgentSaleAttributes: Decodable {
    struct Field: Decodable, Identifiable {
        let id: Int
        let name: String?
        let minNumberOfValues: Int?
        let possibleTermValues: [String]?
    }
    let attributes: [Field]
}

struct AgentSalePhoto: Transferable, Sendable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file.file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1920,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                let bytes = NSMutableData()
                guard let target = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
                guard CGImageDestinationFinalize(target), bytes.length <= 2_500_000 else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                return Self(jpeg: bytes as Data)
            }
        }
    }
}

extension LiveAPI {
    func saleAction<T: Decodable>(_ path: String, body: [String: Any], bot: UUID) async throws -> T {
        try await moduleJSON(path, upload: JSONSerialization.data(withJSONObject: body), timeout: 190,
                             query: [.init(name: "bot_id", value: bot.uuidString.lowercased())])
    }
}
