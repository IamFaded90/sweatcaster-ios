import Foundation

enum ProductHuntPage {
    static func offer(at url: URL) async throws -> ProductOffer.Offer? {
        guard ProductHunt.publicURL(url) else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral, delegate: ProductPageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let final = response.url, ProductHunt.publicURL(final),
              ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { return nil }
        var data = Data(); data.reserveCapacity(512_000)
        for try await byte in stream {
            if data.count >= 512_000 { break }
            data.append(byte)
            if data.count % 8_192 == 0 { try Task.checkCancellation() }
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return ProductOffer.read(html: html)
    }
}

private final class ProductPageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ProductHunt.publicURL) == true ? request : nil)
    }
}
