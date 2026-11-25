import Foundation

@MainActor enum AgentInternetTools {
    static var phoneAvailable: Bool { ComposioPhoneKey.exists() }
    static let paidSearchKey = "fadedai.composio.phone.paid-search.v1"

    static func research(query: String, api: LiveAPI?) async throws -> AgentWebSources {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000 else { throw APIError.input }
        let pc: (() async throws -> AgentWebSources)? = api.map { api in
            { _ = try await api.health(); return try await api.chatResearch(query: query) }
        }
        return try await AgentInternetRead.run(phoneAvailable: phoneAvailable, computer: pc,
            mayFallback: isConnectionFailure) {
            let client = try await ComposioCloud.client()
            let url = URL(string: query)
            let isLink = url?.host != nil && ["https", "http"].contains(url?.scheme?.lowercased() ?? "")
            let slug = isLink ? "TAVILY_EXTRACT" : "TAVILY_SEARCH"
            let discovery = try await client.discover(isLink
                ? "Read one public web page with TAVILY_EXTRACT."
                : "Search the public web with TAVILY_SEARCH and return source URLs and text snippets.")
            try checkAccess("tavily", slug: slug, discovery: discovery)
            let arguments: [String: Any] = isLink
                ? ["urls": [query], "format": "text", "extract_depth": "basic", "include_images": false]
                : ["query": query, "max_results": 5, "search_depth": "basic", "include_answer": false,
                   "include_images": false, "include_raw_content": false]
            let output = try await client.execute(slug, arguments: arguments, discovery: discovery)
            let pages: [AgentInternetPayload.Page]
            do { pages = try AgentInternetPayload.pages(output, extracted: isLink) }
            catch { throw ComposioCloudError.unavailable("Søgningen gav ingen læsbare kilder. Prøv et andet søgeord eller link.") }
            return AgentWebSources(context: pages.map { "\($0.title)\n\($0.url.absoluteString)\n\($0.text)" }.joined(separator: "\n\n"),
                sources: pages.map { .init(title: $0.title, url: $0.url, readPage: $0.readPage) })
        }
    }

    static func gmailMessages(query: String, api: LiveAPI?) async throws -> BotMailMessages {
        if !phoneAvailable, let api {
            return try await api.moduleJSON("composio/gmail/messages", timeout: 75,
                query: [URLQueryItem(name: "q", value: query)])
        }
        let output = try await gmail("GMAIL_FETCH_EMAILS", arguments: [
            "user_id": "me", "query": query, "max_results": 12, "verbose": false,
            "include_payload": false, "include_spam_trash": false
        ])
        do {
            return BotMailMessages(messages: try AgentInternetPayload.mails(output).map {
                .init(id: $0.id, sender: $0.sender, subject: $0.subject, timestamp: $0.timestamp, threadID: $0.threadID)
            })
        } catch { throw ComposioCloudError.invalidResponse }
    }

    static func gmailMessage(id: String, api: LiveAPI?) async throws -> BotMailContent {
        guard AgentInternetPayload.identifier(id) != nil else { throw APIError.input }
        if !phoneAvailable, let api {
            return try await api.moduleJSON("composio/gmail/message/\(Server.segment(id))", timeout: 75)
        }
        let output = try await gmail("GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", arguments: [
            "user_id": "me", "message_id": id, "format": "full"
        ])
        do {
            let value = try AgentInternetPayload.message(output, expectedID: id)
            return BotMailContent(text: value.text, messageID: value.id, threadID: value.threadID)
        } catch { throw ComposioCloudError.invalidResponse }
    }

    private static func gmail(_ slug: String, arguments: [String: Any]) async throws -> [String: Any] {
        let client = try await ComposioCloud.client()
        let discovery = try await client.discover("Read Gmail with \(slug). Do not modify or mark messages as read.")
        try checkAccess("gmail", slug: slug, discovery: discovery)
        return try await client.execute(slug, arguments: arguments, discovery: discovery)
    }

    private static func checkAccess(_ toolkit: String, slug: String, discovery: [String: Any]) throws {
        let rows = discovery["toolkit_connection_statuses"] as? [[String: Any]] ?? []
        guard let row = rows.first(where: { ($0["toolkit"] as? String)?.lowercased() == toolkit }),
              row["has_active_connection"] as? Bool == true else {
            throw ComposioCloudError.unavailable(toolkit == "gmail"
                ? "Forbind Gmail i din Composio-konto. Så kan agenten læse mail direkte fra iPhone."
                : "Forbind websøgning i Composio, eller brug PC’ens søgning.")
        }
        if let instant = row["instant_account"] as? [String: Any],
           let allowed = instant["allowed_tool_slugs"] as? [String], !allowed.contains(slug) {
            throw ComposioCloudError.unavailable("Din Composio-forbindelse giver ikke adgang til dette opslag.")
        }
        if toolkit == "tavily", AgentInternetPayload.searchNeedsConsent(row, slug: slug),
           !UserDefaults.standard.bool(forKey: paidSearchKey) {
            throw ComposioCloudError.unavailable("Composios websøgning bruger saldo. Tillad det under Composio på iPhone, forbind din egen søgekonto, eller brug PC’ens søgning.")
        }
    }

    static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError { return connectionCode(error.code.rawValue) }
        switch error as? APIError {
        case .offline, .unhealthy, .localNetwork: return true
        case .transport(let code): return connectionCode(code)
        default: return false
        }
    }

    private static func connectionCode(_ code: Int) -> Bool {
        [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
         .dnsLookupFailed, .notConnectedToInternet].contains { $0.rawValue == code }
    }
}
