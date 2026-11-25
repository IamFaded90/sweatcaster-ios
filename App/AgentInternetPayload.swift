import Foundation

/// Decodes the read-only phone tools without treating a failed/malformed lookup as an empty inbox.
enum AgentInternetPayload {
    enum Failure: Error { case malformed, missingMessage, noSources }
    struct Page {
        let title: String
        let url: URL
        let text: String
        let readPage: Bool
    }
    struct Mail {
        let id, sender, subject, timestamp: String
        let threadID: String?
    }
    struct Message {
        let id, text: String
        let threadID: String?
    }

    static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func object(_ output: [String: Any]) -> [String: Any] {
        (output["response_data"] as? [String: Any]) ?? output
    }

    static func searchNeedsConsent(_ connection: [String: Any], slug: String) -> Bool {
        guard let instant = connection["instant_account"] as? [String: Any] else { return false }
        let prices = instant["prices"] as? [String: [String: Any]] ?? [:]
        return (prices[slug]?["discount"] as? String) != "100"
    }

    static func pages(_ output: [String: Any], extracted: Bool) throws -> [Page] {
        guard let rows = object(output)["results"] as? [[String: Any]] else { throw Failure.malformed }
        var seen = Set<URL>()
        let pages = rows.prefix(20).compactMap { row -> Page? in
            guard let raw = row["url"] as? String, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, seen.insert(url).inserted else { return nil }
            let text = ((row[extracted ? "raw_content" : "content"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Page(title: String(((row["title"] as? String) ?? url.host ?? "Kilde").prefix(300)),
                        url: url, text: String(text.prefix(1_400)), readPage: extracted)
        }
        guard !pages.isEmpty else { throw Failure.noSources }
        return Array(pages.prefix(5))
    }

    static func mails(_ output: [String: Any]) throws -> [Mail] {
        guard let rows = object(output)["messages"] as? [[String: Any]] else { throw Failure.malformed }
        var seen = Set<String>()
        let mails = rows.prefix(40).compactMap { row -> Mail? in
            guard let id = identifier(row["messageId"] ?? row["id"]), seen.insert(id).inserted else { return nil }
            let headers = headers(row["payload"] as? [String: Any] ?? [:])
            return Mail(id: id, sender: String(((row["sender"] as? String) ?? headers["from"] ?? "").prefix(300)),
                        subject: String(((row["subject"] as? String) ?? headers["subject"] ?? "").prefix(350)),
                        timestamp: timestamp(row), threadID: identifier(row["threadId"]))
        }
        if !rows.isEmpty && mails.isEmpty { throw Failure.malformed }
        return Array(mails.prefix(12))
    }

    static func message(_ output: [String: Any], expectedID: String) throws -> Message {
        let row = object(output)
        guard identifier(row["messageId"] ?? row["id"]) == expectedID else { throw Failure.missingMessage }
        let payload = row["payload"] as? [String: Any] ?? [:]
        let plain = body(payload, mime: "text/plain")
        let supplied = (row["messageText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let html = body(payload, mime: "text/html")
        let full = !plain.isEmpty ? plain : !supplied.isEmpty ? supplied : htmlText(html)
        let snippet = row["snippet"] as? String ?? ""
        let text = full.isEmpty && !snippet.isEmpty ? "Kort uddrag fra mailen:\n" + snippet : full
        let clipped = text.count > 12_000 ? String(text.prefix(12_000)) + "\n\nResten kan læses i Gmail." : text
        return Message(id: expectedID, text: clipped, threadID: identifier(row["threadId"]))
    }

    private static func timestamp(_ row: [String: Any]) -> String {
        if let value = row["internalDate"] as? String { return String(value.prefix(64)) }
        if let value = row["messageTimestamp"] as? NSNumber { return value.stringValue }
        let value = String((row["messageTimestamp"] as? String ?? "").prefix(64))
        if let date = ISO8601DateFormatter().date(from: value) { return String(date.timeIntervalSince1970) }
        return value
    }

    private static func headers(_ payload: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for row in (payload["headers"] as? [[String: Any]] ?? []).prefix(100) {
            if let name = row["name"] as? String, let value = row["value"] as? String { result[name.lowercased()] = value }
        }
        return result
    }

    private static func body(_ payload: [String: Any], mime: String, depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        if (payload["mimeType"] as? String) == mime, (payload["filename"] as? String ?? "").isEmpty,
           let body = payload["body"] as? [String: Any], let raw = body["data"] as? String, raw.count <= 200_000 {
            var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            if let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) { return text }
        }
        return (payload["parts"] as? [[String: Any]] ?? []).prefix(30)
            .map { body($0, mime: mime, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func htmlText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)<(?:br\s*/?|/p|/div)>"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Only read operations may use this fallback; writes keep their existing review and verification flow.
@MainActor enum AgentInternetRead {
    static func run<T>(phoneAvailable: Bool, computer: (() async throws -> T)?,
                       mayFallback: (Error) -> Bool, phone: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if let computer {
            do { return try await computer() }
            catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled,
                      phoneAvailable, mayFallback(error) else { throw error }
            }
        }
        try Task.checkCancellation()
        return try await phone()
    }
}
