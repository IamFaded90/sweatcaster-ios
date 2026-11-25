import Foundation

enum AgentShortcutBridge {
    static let changed = Notification.Name("FadedAIAgentShortcutChanged")

    static func launchURL(job: AgentWorkspace.Job, botID: UUID) -> URL? {
        guard job.kind == .shortcut, let name = job.shortcutName, !name.isEmpty,
              name.count <= 120, let token = job.callbackToken else { return nil }
        func callback(_ outcome: String) -> String {
            var parts = URLComponents()
            parts.scheme = "fadedai"
            parts.host = "agent-shortcut"
            parts.queryItems = [URLQueryItem(name: "agent", value: botID.uuidString),
                URLQueryItem(name: "job", value: job.id.uuidString), URLQueryItem(name: "token", value: token.uuidString),
                URLQueryItem(name: "outcome", value: outcome)]
            return parts.url!.absoluteString
        }
        var parts = URLComponents()
        parts.scheme = "shortcuts"
        parts.host = "x-callback-url"
        parts.path = "/run-shortcut"
        parts.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: job.shortcutInput ?? ""),
            URLQueryItem(name: "x-success", value: callback("success")),
            URLQueryItem(name: "x-cancel", value: callback("cancel")), URLQueryItem(name: "x-error", value: callback("error"))]
        return parts.url
    }

    /// Callbacks confirm what Shortcuts reported, not the downstream service's result.
    @discardableResult static func receive(_ url: URL, root: URL = AgentWorkspace.root) throws -> Bool {
        guard url.scheme == "fadedai", url.host == "agent-shortcut", url.user == nil, url.password == nil,
              url.absoluteString.utf8.count <= 32_000,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let names = items.map(\.name)
        guard Set(names).count == names.count else { return false }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let bot = UUID(uuidString: values["agent"] ?? ""), let job = UUID(uuidString: values["job"] ?? ""),
              let token = UUID(uuidString: values["token"] ?? ""), let outcome = values["outcome"],
              ["success", "cancel", "error"].contains(outcome) else { return false }
        let workspace = AgentWorkspace(botID: bot, root: root)
        guard let pending = try workspace.load().jobs.first(where: { $0.id == job }), pending.kind == .shortcut,
              pending.state == .checking, pending.callbackToken == token, pending.submitted else { return false }
        try workspace.update(job) {
            $0.callbackToken = nil
            $0.state = outcome == "success" ? .completed : outcome == "cancel" ? .cancelled : .failed
            if outcome == "success" {
                $0.result = "Genveje meldte opgaven færdig.\n" + String((values["result"] ?? "Intet tekstresultat modtaget.").prefix(8_000))
            } else if outcome == "cancel" { $0.result = "Genvejen blev afbrudt. Eventuelle allerede udførte trin er ikke rullet tilbage." }
            else { $0.result = "Genvejen meldte fejl: " + String((values["errorMessage"] ?? "Ukendt fejl").prefix(500)) }
        }
        NotificationCenter.default.post(name: changed, object: bot)
        return true
    }
}
