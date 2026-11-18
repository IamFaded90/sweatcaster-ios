// Adapter to the Spotube-derived native NewPipe bridge. This prototype is not
// included in the application target until the XCFramework has been verified.
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FadedMusicCore)
import FadedMusicCore
#endif

enum MusicCatalogError: LocalizedError {
    case unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Musikkilden er ikke installeret på denne iPhone."
        case .invalidResponse: "Musikkilden sendte et ugyldigt svar."
        }
    }
}

@MainActor final class NativeMusicCatalog {
    static let shared = NativeMusicCatalog()
    #if canImport(FadedMusicCore)
    private let client = FadedMusicClient()
    #endif

    var available: Bool {
        #if canImport(FadedMusicCore)
        true
        #else
        false
        #endif
    }

    func search(_ query: String) async throws -> [MusicTrack] {
        #if canImport(FadedMusicCore)
        struct Results: Decodable { let tracks: [MusicTrack] }
        let json = try await client.searchJson(query: query)
        guard let data = json.data(using: .utf8), data.count <= 250_000 else { throw MusicCatalogError.invalidResponse }
        return Array(try JSONDecoder().decode(Results.self, from: data).tracks.prefix(20))
        #else
        throw MusicCatalogError.unavailable
        #endif
    }

    func stream(_ id: String) async throws -> (URL, TimeInterval) {
        #if canImport(FadedMusicCore)
        struct Stream: Decodable { let url: URL; let expiresIn: Int }
        let json = try await client.streamJson(id: id)
        guard let data = json.data(using: .utf8), data.count <= 16_000 else { throw MusicCatalogError.invalidResponse }
        let stream = try JSONDecoder().decode(Stream.self, from: data)
        guard stream.url.scheme == "https", stream.url.user == nil, stream.url.password == nil,
              stream.url.host?.lowercased().hasSuffix(".googlevideo.com") == true else { throw MusicCatalogError.invalidResponse }
        return (stream.url, TimeInterval(min(1800, max(0, stream.expiresIn))))
        #else
        throw MusicCatalogError.unavailable
        #endif
    }
}
