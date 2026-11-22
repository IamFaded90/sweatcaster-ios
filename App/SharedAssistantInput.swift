import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads user-selected content delivered by the Share extension. Extraction stays on the phone.
struct SharedAssistantInput: Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case text, url, pdf, image }

    struct Prepared: Sendable {
        let id: UUID
        let title: String
        let kind: Kind
        let document: AgentDocument?
        let url: URL?
        let excerpt: String
        let notice: String?
    }

    enum Failure: LocalizedError {
        case unavailable, malformed, tooLarge, noReadableText

        var errorDescription: String? {
            switch self {
            case .unavailable: "Deling er ikke sat op i denne iPhone-version."
            case .malformed: "Det delte indhold kunne ikke læses. Prøv at dele det igen."
            case .tooLarge: "Den delte fil er for stor. Prøv med en fil på højst 10 MB."
            case .noReadableText: "Jeg fandt ingen læsbar tekst. Prøv at dele en tydeligere kopi."
            }
        }
    }

    private struct Manifest: Decodable, Sendable {
        let id: UUID
        let kind: Kind
        let title: String
        let value: String?
        let filename: String?
    }

    static let appGroup = FadedSharedContainer.identifier
    private static let fileLimit = 10 * 1_024 * 1_024
    private static let textLimit = 24_000
    private static let pageLimit = 30
    private static let scannedPageLimit = 3
    private static let manifestLimit = 128 * 1_024

    private let manifest: Manifest
    private let inbox: URL
    private let folder: URL

    var id: UUID { manifest.id }
    var title: String {
        let cleaned = manifest.title.replacingOccurrences(of: "\0", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? "Delt indhold" : String(cleaned.prefix(100))
    }
    var kind: Kind { manifest.kind }

    static func pending(in explicitInbox: URL? = nil) throws -> [Self] {
        let inbox: URL
        if let explicitInbox { inbox = explicitInbox }
        else {
            guard let group = FadedSharedContainer.url else {
                throw Failure.unavailable
            }
            inbox = group.appending(path: "ShareInbox", directoryHint: .isDirectory)
        }
        guard FileManager.default.fileExists(atPath: inbox.path) else { return [] }
        let inboxInfo = try inbox.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard inboxInfo.isDirectory == true, inboxInfo.isSymbolicLink != true else { throw Failure.malformed }
        let folders = try FileManager.default.contentsOfDirectory(at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey], options: [.skipsHiddenFiles])
        return folders.compactMap { folder -> (Self, Date)? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let info = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
                  info.isDirectory == true, info.isSymbolicLink != true,
                  let bytes = try? readFile("item.json", in: folder, limit: manifestLimit),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes), manifest.id == id else { return nil }
            return (Self(manifest: manifest, inbox: inbox, folder: folder), info.creationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id.uuidString < rhs.0.id.uuidString : lhs.1 > rhs.1
        }.map(\.0)
    }

    static func latest() throws -> Self? { try pending().first }

    func prepare() async throws -> Prepared {
        let work = Task.detached(priority: .userInitiated) { try self.extract() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func pdfCopy() throws -> Data {
        guard kind == .pdf else { throw Failure.malformed }
        return try attachment()
    }

    /// Removes only the app group's temporary copy, never the source shared by the user.
    func remove() throws {
        guard UUID(uuidString: folder.lastPathComponent) == id,
              folder.deletingLastPathComponent().standardizedFileURL == inbox.standardizedFileURL else {
            throw Failure.malformed
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw Failure.malformed }
        try FileManager.default.removeItem(at: folder)
    }

    private func extract() throws -> Prepared {
        try Task.checkCancellation()
        switch kind {
        case .url:
            guard let value = manifest.value, let url = Self.checkedURL(value) else { throw Failure.malformed }
            return Prepared(id: id, title: title, kind: kind, document: nil, url: url,
                excerpt: url.absoluteString, notice: "Du kan åbne linket eller dele tekst fra siden til chatten.")
        case .text:
            guard let value = manifest.value else { throw Failure.malformed }
            return try document([(nil, value)], truncated: value.unicodeScalars.count > Self.textLimit)
        case .pdf:
            let readable = try Self.readPDF(attachment())
            return try document(readable.pages, truncated: readable.truncated)
        case .image:
            let image = try Self.thumbnail(attachment())
            return try document([(nil, Self.recognizeText(image))], truncated: false)
        }
    }

    private func attachment() throws -> Data {
        guard let name = manifest.filename,
              name.range(of: #"^attachment\.[a-z0-9]{1,10}$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw Failure.malformed
        }
        let directory = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw Failure.malformed }
        return try Self.readFile(name, in: folder, limit: Self.fileLimit)
    }

    private static func readFile(_ name: String, in folder: URL, limit: Int) throws -> Data {
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size > 0 else {
            throw Failure.malformed
        }
        guard size <= limit else { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty else { throw Failure.malformed }
        guard bytes.count <= limit else { throw Failure.tooLarge }
        return bytes
    }

    private static func checkedURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 4_096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    private func document(_ pages: [(Int?, String)], truncated: Bool) throws -> Prepared {
        var remaining = Self.textLimit
        var wasTruncated = truncated
        var passages: [AgentDocument.Passage] = []
        for (page, body) in pages {
            try Task.checkCancellation()
            let valid = body.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let capped = valid.unicodeScalars.prefix(remaining)
            wasTruncated = wasTruncated || capped.count < valid.unicodeScalars.count
            remaining -= capped.count
            var start = capped.startIndex
            while start < capped.endIndex {
                let candidate = capped.index(start, offsetBy: 440, limitedBy: capped.endIndex) ?? capped.endIndex
                let slice = capped[start..<candidate]
                let softBreak = candidate == capped.endIndex ? nil : slice.lastIndex(where: CharacterSet.whitespacesAndNewlines.contains)
                let end: String.UnicodeScalarView.Index
                if let softBreak, capped.distance(from: start, to: softBreak) >= 220 { end = capped.index(after: softBreak) }
                else { end = candidate }
                let text = String(capped[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { passages.append(.init(page: page, text: text, vector: nil)) }
                start = end
            }
        }
        guard !passages.isEmpty else { throw Failure.noReadableText }
        let document = AgentDocument(id: id, name: title, model: nil, passages: passages)
        let excerpt = passages.prefix(4).map(\.text).joined(separator: "\n\n")
        return Prepared(id: id, title: title, kind: kind, document: document, url: nil, excerpt: excerpt,
                        notice: wasTruncated ? "De første læsbare sider eller tegn er klar til chatten." : nil)
    }

    private static func readPDF(_ bytes: Data) throws -> (pages: [(Int?, String)], truncated: Bool) {
        guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else { throw Failure.malformed }
        var pages: [(Int?, String)] = []
        var scanned = 0
        var remaining = textLimit
        var truncated = document.pageCount > pageLimit
        for index in 0..<min(document.pageCount, pageLimit) {
            try Task.checkCancellation()
            guard remaining > 0 else { truncated = true; break }
            guard let page = document.page(at: index) else { continue }
            let recognized: String
            if let readable = page.string, !readable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recognized = readable
            } else if scanned < scannedPageLimit {
                scanned += 1
                recognized = try recognizePage(page)
            } else { truncated = true; continue }
            let capped = recognized.unicodeScalars.prefix(remaining)
            remaining -= capped.count
            truncated = truncated || capped.count < recognized.unicodeScalars.count
            pages.append((index + 1, String(capped)))
        }
        return (pages, truncated)
    }

    static func recognizePage(_ page: PDFPage) throws -> String {
        guard let image = renderedPage(page) else { return "" }
        return try recognizeText(image)
    }

    private static func renderedPage(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 1, box.height > 1 else { return nil }
        let scale = min(2, 1_400 / max(box.width, box.height))
        let width = max(1, Int(ceil(box.width * scale)))
        let height = max(1, Int(ceil(box.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    private static func thumbnail(_ bytes: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...24_000).contains(width), (1...24_000).contains(height), width * height <= 100_000_000 else {
            throw Failure.malformed
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true]
        guard let result = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.malformed }
        return result
    }

    private static func recognizeText(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return request.results?.prefix(80).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}
