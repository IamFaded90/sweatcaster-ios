import Foundation

extension LiveAPI {
    func lumiChat(message: String, history: [[String: String]], language: String,
                  scene: LumiSceneCard? = nil, initiative: LumiInitiative = .together, opening: Bool = false) async throws -> String {
        struct Reply: Decodable { let reply: String }
        var input: [String: Any] = ["message": message, "history": history, "language": language]
        let hasSceneSettings = scene != nil || initiative != .together || opening
        if hasSceneSettings {
            if let scene { input["scene"] = scene.wire }
            input["initiative"] = initiative.rawValue
            input["opening"] = opening
        }
        let body = try JSONSerialization.data(withJSONObject: input)
        let result: Reply = try await lumiRequest(hasSceneSettings ? "scene-chat" : "chat", body: body, timeout: 190)
        return result.reply
    }

    func lumiImage(prompt: String, reference: Data? = nil) async throws -> Data {
        var input = ["prompt": prompt]
        if let reference {
            guard (1...1_000_000).contains(reference.count) else { throw APIError.input }
            input["reference"] = reference.base64EncodedString()
        }
        let body = try JSONEncoder().encode(input)
        let (data, response) = try await lumiData("image", body: body, timeout: 330)
        try checked(response, expected: 200, data: data)
        guard data.count <= 15_000_000, data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else {
            throw APIError.malformed
        }
        return data
    }

    func privateStudioImage(prompt: String, negative: String, reference: Data?, mask: Data?,
                            strength: Float?, seed: UInt32) async throws -> Data {
        struct Edit: Encodable {
            let prompt: String, negative: String
            let reference: Data?, mask: Data?, strength: Float?
            let seed: UInt32
        }
        let body = try JSONEncoder().encode(Edit(prompt: prompt, negative: negative, reference: reference,
                                                  mask: mask, strength: strength, seed: seed))
        let (data, response) = try await lumiData("private-image", body: body, timeout: 330)
        try checked(response, expected: 200, data: data)
        guard data.count <= 15_000_000, data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else { throw APIError.malformed }
        return data
    }

    func lumiStartVideo(prompt: String) async throws -> LumiVideoJob {
        let body = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        return try await lumiRequest("video", body: body, timeout: 30)
    }

    func lumiVideoStatus(id: UUID) async throws -> LumiVideoJob {
        let url = try lumiURL("video/" + id.uuidString.lowercased())
        let (data, response) = try await loggedData(for: request(url))
        try checked(response, expected: 200, data: data)
        guard data.count <= 10_000 else { throw APIError.malformed }
        return try loggedDecode(LumiVideoJob.self, from: data, decoder: JSONDecoder())
    }

    func lumiVideoFile(id: UUID) async throws -> Data {
        let url = try lumiURL("video/" + id.uuidString.lowercased() + "/file")
        var endpoint = request(url)
        endpoint.timeoutInterval = 90
        let (data, response) = try await loggedData(for: endpoint)
        try checked(response, expected: 200, data: data)
        guard data.count <= 40_000_000, data.count >= 8,
              Data(data[4..<8]) == Data("ftyp".utf8) else { throw APIError.malformed }
        return data
    }

    private func lumiRequest<T: Decodable>(_ action: String, body: Data,
                                           timeout: TimeInterval) async throws -> T {
        let (data, response) = try await lumiData(action, body: body, timeout: timeout)
        try checked(response, expected: 200, data: data)
        guard data.count <= 100_000 else { throw APIError.malformed }
        return try loggedDecode(T.self, from: data, decoder: JSONDecoder())
    }

    private func lumiData(_ action: String, body: Data,
                          timeout: TimeInterval) async throws -> (Data, URLResponse) {
        guard ["chat", "scene-chat", "image", "private-image", "video"].contains(action) else { throw APIError.input }
        let url = try lumiURL(action)
        var endpoint = request(url, method: "POST")
        endpoint.setValue("application/json", forHTTPHeaderField: "Content-Type")
        endpoint.httpBody = body
        endpoint.timeoutInterval = timeout
        return try await loggedData(for: endpoint)
    }

    private func lumiURL(_ suffix: String) throws -> URL {
        guard let url = URL(string: server.origin.absoluteString + "/api/modules/v1/lumi/" +
                            VillageBot.lumiID.uuidString.lowercased() + "/" + suffix) else {
            throw APIError.input
        }
        return url
    }

    func moduleJSON<T: Decodable>(_ path: String, upload: Data? = nil, timeout: TimeInterval? = nil,
                                          query: [URLQueryItem] = [], maximumBytes: Int = 2_000_000) async throws -> T {
        var endpoint = try v2Request("modules")
        guard let url = endpoint.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw V2Failure.invalidInput
        }
        components.path = "/api/modules/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let target = components.url else { throw V2Failure.invalidInput }
        endpoint = request(target, method: upload == nil ? "GET" : "PUT")
        if let timeout { endpoint.timeoutInterval = timeout }
        if let upload {
            endpoint.httpBody = upload
            endpoint.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await loggedData(for: endpoint)
        try checked(response, expected: 200, data: data)
        guard data.count <= maximumBytes else { throw AppDiagnostics.record(V2Failure.invalidResponse) }
        return try loggedDecode(T.self, from: data, decoder: JSONDecoder())
    }

    func moduleManifest() async throws -> ModuleManifest { try await moduleJSON("manifest") }

    func castRelayURL(source: URL, page: URL?) async throws -> URL {
        struct Input: Encodable { let url: String; let origin: String? }
        struct Relay: Decodable { let path: String }
        guard server.profile == .home else { throw APIError.offline }
        let origin = page.flatMap { address -> String? in
            guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(parts.scheme ?? ""), parts.host != nil,
                  parts.user == nil, parts.password == nil else { return nil }
            parts.path = ""
            parts.query = nil
            parts.fragment = nil
            return parts.string
        }
        let data = try JSONEncoder().encode(Input(url: source.absoluteString, origin: origin))
        let result: Relay = try await moduleJSON("cast-relay", upload: data, timeout: 8, maximumBytes: 1024)
        let path = #"^/api/modules/v1/cast-relay/play/[A-Za-z0-9_-]{32}/[A-Za-z0-9_-]{24}$"#
        guard result.path.range(of: path, options: .regularExpression) != nil,
              let receiver = URL(string: server.origin.absoluteString + result.path) else { throw APIError.malformed }
        return receiver
    }

    func grokTemplate(_ link: String) async throws -> GrokTemplateReceipt {
        try await moduleJSON("grok-template", upload: JSONEncoder().encode(["url": link]), timeout: 50)
    }

    func christelConfigured() async throws -> Bool {
        struct Status: Decodable { let configured: Bool }
        let status: Status = try await moduleJSON("christel", timeout: 7)
        return status.configured
    }

    func christelAudio(_ text: String) async throws -> Data {
        struct Speech: Decodable { let audio: Data }
        let result: Speech = try await moduleJSON("christel", upload: JSONEncoder().encode(["text": text]), timeout: 35)
        guard !result.audio.isEmpty, result.audio.count <= 1_400_000 else { throw APIError.malformed }
        return result.audio
    }

    func beginVideoReview(_ batch: Batch) async throws -> PCVideoReview {
        try batch.validate(limit: 1)
        return try await moduleJSON("video-review", upload: JSONEncoder().encode(batch))
    }

    func videoReview(_ id: String) async throws -> PCVideoReview {
        guard validWireID(id) else { throw APIError.input }
        return try await moduleJSON("video-review/\(id)")
    }

    func renderVideoReview(_ id: String, lines: [String], preview: Bool) async throws -> PCVideoReview {
        struct Input: Encodable { let lines: [String]; let preview: Bool }
        guard validWireID(id) else { throw APIError.input }
        let data = try JSONEncoder().encode(Input(lines: lines, preview: preview))
        return try await moduleJSON("video-review/\(id)/render", upload: data)
    }

    func downloadVideoReview(_ id: String) async throws -> URL {
        guard validWireID(id),
              let url = URL(string: server.origin.absoluteString + "/api/modules/v1/video-review/\(id)/preview")
        else { throw APIError.input }
        return try await downloadVideo(at: url)
    }

    func deleteVideoReviewPreview(_ id: String) async throws -> PCVideoReview {
        guard validWireID(id),
              let url = URL(string: server.origin.absoluteString + "/api/modules/v1/video-review/\(id)/preview")
        else { throw APIError.input }
        let (data, response) = try await loggedData(for: request(url, method: "DELETE"))
        try checked(response, expected: 200, data: data)
        guard data.count <= 100_000 else { throw APIError.malformed }
        return try loggedDecode(PCVideoReview.self, from: data, decoder: JSONDecoder())
    }

    func botMailbox(_ botID: UUID, createFor name: String? = nil) async throws -> BotMailboxState {
        let body = try name.map { try JSONEncoder().encode(["name": $0]) }
        return try await moduleJSON("agentmail/\(botID.uuidString.lowercased())", upload: body, timeout: 48)
    }

    func enrollAgentMail(_ botID: UUID, email: String) async throws -> BotMailboxState {
        try await moduleJSON("agentmail/\(botID.uuidString.lowercased())/enroll",
                             upload: JSONEncoder().encode(["email": email]), timeout: 35)
    }

    func verifyAgentMail(_ botID: UUID, code: String) async throws -> BotMailboxState {
        try await moduleJSON("agentmail/\(botID.uuidString.lowercased())/verify",
                             upload: JSONEncoder().encode(["code": code]), timeout: 45)
    }

    func resendAgentMailCode(_ botID: UUID) async throws -> BotMailboxState {
        try await moduleJSON("agentmail/\(botID.uuidString.lowercased())/resend",
                             upload: Data("{}".utf8), timeout: 30)
    }

    func botMailMessages(_ botID: UUID) async throws -> BotMailMessages {
        try await moduleJSON("agentmail/\(botID.uuidString.lowercased())/messages", timeout: 34)
    }

    func botMailMessage(_ botID: UUID, id: String) async throws -> BotMailContent {
        try await moduleJSON("agentmail/\(botID.uuidString.lowercased())/message", timeout: 34,
                             query: [.init(name: "message_id", value: id)])
    }

    func mailAppointments(_ botID: UUID, enabled: Bool? = nil) async throws -> MailAppointmentState {
        let upload = try enabled.map { value in
            struct Input: Encodable { let enabled: Bool; let zone: String }
            return try JSONEncoder().encode(Input(enabled: value, zone: TimeZone.current.identifier))
        }
        return try await moduleJSON("mail-appointments/\(botID.uuidString.lowercased())", upload: upload, timeout: 48)
    }

    func scanMailAppointments(_ botID: UUID) async throws -> MailAppointmentState {
        try await moduleJSON("mail-appointments/\(botID.uuidString.lowercased())/scan", upload: Data("{}".utf8))
    }

    func hideMailAppointment(_ botID: UUID, id: UUID) async throws -> MailAppointmentState {
        try await moduleJSON("mail-appointments/\(botID.uuidString.lowercased())/hide",
                             upload: JSONEncoder().encode(["id": id.uuidString.lowercased()]))
    }

    func pcMetrics() async throws -> PCMetrics { try await moduleJSON("pc-metrics", timeout: 10) }

    func pcSetup() async throws -> PCSetup { try await moduleJSON("pc-setup", timeout: 52) }

    func attentionQueue() async throws -> AttentionQueue { try await moduleJSON("attention", timeout: 12) }

    func codeAddOns() async throws -> CodeAddOn.Library { try await moduleJSON("addons", timeout: 10) }

    func draftCodeAddOn(_ brief: String) async throws -> CodeAddOn {
        try await moduleJSON("addons/draft", upload: JSONEncoder().encode(["brief": brief]), timeout: 190)
    }

    func findGitHubAddOn(_ url: String, local: Bool) async throws -> CodeAddOn {
        struct Input: Encodable { let url: String; let local: Bool }
        return try await moduleJSON("addons/github", upload: JSONEncoder().encode(Input(url: url, local: local)), timeout: 80)
    }

    func installCodeAddOn(_ addOn: CodeAddOn) async throws -> CodeAddOn {
        try await moduleJSON("addons", upload: JSONEncoder().encode(addOn), timeout: addOn.source?.kind == .staticFiles ? 40 : 15)
    }

    func codeAddOnWebFiles(_ id: UUID) async throws -> CodeAddOnWebFiles {
        try await moduleJSON("addons/\(id.uuidString.lowercased())/files", timeout: 25, maximumBytes: 8_500_000)
    }

    func removeCodeAddOn(_ id: UUID) async throws {
        struct Receipt: Decodable { let ok: Bool }
        let result: Receipt = try await moduleJSON("addons/\(id.uuidString.lowercased())/remove",
                                                   upload: Data("{}".utf8), timeout: 15)
        guard result.ok else { throw APIError.malformed }
    }

    func composioProviders(refresh: Bool = false) async throws -> ComposioProviders {
        do {
            return try await moduleJSON("composio/integrations", timeout: 85,
                                        query: refresh ? [URLQueryItem(name: "refresh", value: "true")] : [])
        } catch APIError.http(404, _) {
            return try await moduleJSON("composio", timeout: 85)
        }
    }

    func composioLink(_ provider: String) async throws -> ComposioLink {
        let empty = Data("{}".utf8)
        return try await moduleJSON("composio/\(Server.segment(provider))/link", upload: empty, timeout: 65)
    }

    func composioItems(_ provider: String) async throws -> ComposioItems {
        try await moduleJSON("composio/\(Server.segment(provider))/items", timeout: 45)
    }

    func composioContext(_ provider: String, item: String) async throws -> ComposioContext {
        let data = try JSONEncoder().encode(["item": item])
        return try await moduleJSON("composio/\(Server.segment(provider))/context", upload: data, timeout: 85)
    }

    func youtubeChannels() async throws -> YouTubeChannels {
        try await moduleJSON("youtube/channels", timeout: 24)
    }

    func kokoroAudio(_ text: String, voice: String) async throws -> Data {
        struct Speech: Decodable { let audio: Data }
        let result: Speech = try await moduleJSON("kokoro", upload: JSONEncoder().encode(["text": text, "voice": voice]),
                                                  timeout: 60, maximumBytes: 12_000_000)
        guard !result.audio.isEmpty else { throw APIError.malformed }
        return result.audio
    }

    func googleDriveFiles(parent: String?, page: String?) async throws -> PCDriveFiles {
        let query = [parent.map { URLQueryItem(name: "parent", value: $0) },
                     page.map { URLQueryItem(name: "page", value: $0) }].compactMap { $0 }
        return try await moduleJSON("google-drive/files", timeout: 25, query: query)
    }

    func pcWebSearch(query: String) async throws -> PCWebSearch {
        let data = try JSONEncoder().encode(["query": query])
        return try await moduleJSON("web-search", upload: data, timeout: 16)
    }

    func chatResearch(query: String) async throws -> AgentWebSources {
        let data = try JSONEncoder().encode(["query": query])
        return try await moduleJSON("chat-research", upload: data, timeout: 45)
    }

    func agentChat(model: String, prompt: String, instructions: String) async throws -> String {
        struct Reply: Decodable { let text: String }
        let data = try JSONEncoder().encode(["modelID": model, "prompt": prompt, "instructions": instructions])
        let result: Reply = try await moduleJSON("agent-chat", upload: data, timeout: 160)
        return result.text
    }

    func villageBotActivity(ids: [UUID]) async throws -> VillageBotActivity {
        let data = try JSONEncoder().encode(["botIDs": ids.map { $0.uuidString.lowercased() }])
        return try await moduleJSON("bot-activity", upload: data, timeout: 10)
    }

    func moduleCards(_ id: String, upload: Data? = nil) async throws -> ModuleCards {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)", upload: upload)
    }
    func moduleInformation(_ id: String) async throws -> ModuleInformation {
        guard ModuleTab.validID(id) else { throw V2Failure.invalidInput }
        return try await moduleJSON("tabs/\(id)")
    }

    func codeBatches() async throws -> CodeBatchList { try await moduleJSON("code-batches") }
    func teamRoutines() async throws -> TeamPCRoutines { try await moduleJSON("routines") }
    func saveTeamRoutines(_ routines: [TeamPCRoutine.Configuration]) async throws -> TeamPCRoutines {
        struct Input: Encodable { let routines: [TeamPCRoutine.Configuration] }
        return try await moduleJSON("routines", upload: JSONEncoder().encode(Input(routines: routines)))
    }

    func cloneCodeRepository(_ repo: String) async throws {
        struct Receipt: Decodable { let repo, revision: String }
        let data = try JSONEncoder().encode(["repo": repo])
        let _: Receipt = try await moduleJSON("code-repositories", upload: data, timeout: 190)
    }

    func enqueueCodeBatch(repo: String, goal: String, files: [String], highPriority: Bool = false) async throws {
        struct Input: Encodable { let repo, goal: String; let files: [String]; let priority: Int? }
        struct Receipt: Decodable { let id: String }
        let input = Input(repo: repo, goal: goal, files: files, priority: highPriority ? 1 : nil)
        let receipt: Receipt = try await moduleJSON("code-batches", upload: JSONEncoder().encode(input))
        await JobNotifications.shared.trackCodeJob(server: server.address, id: receipt.id)
    }

    func codeBatch(_ id: String) async throws -> CodeBatchDetail {
        try await moduleJSON("code-batches/\(Server.segment(id))")
    }

    func approveCodeBatch(_ id: String) async throws -> CodeBatchDetail.Proposal {
        try await moduleJSON("code-batches/\(Server.segment(id))/approval", upload: JSONEncoder().encode(["approved": true]))
    }

    func rejectCodeBatch(_ id: String) async throws -> CodeBatchDetail {
        try await moduleJSON("code-batches/\(Server.segment(id))/rejection", upload: JSONEncoder().encode(["rejected": true]))
    }

    func botComputerResponse(botID: UUID, route: BotComputerRoute,
                             body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: server.origin, resolvingAgainstBaseURL: false) else {
            throw APIError.address
        }
        components.path = "/api/modules/v1/bot-computers/\(botID.uuidString.lowercased())" + route.suffix
        guard let url = components.url else { throw APIError.input }
        let mime = route.isScreen ? "image/png" : "application/json"
        var endpoint = request(url, method: route.method)
        endpoint.setValue(mime, forHTTPHeaderField: "Accept")
        if let timeout = route.timeout { endpoint.timeoutInterval = timeout }
        if let body {
            endpoint.httpBody = body
            endpoint.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loggedData(for: endpoint)
        } catch let error as URLError where !Task.isCancelled {
            throw mapped(error, posting: route.method == "POST")
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.malformed }
        let expected = (200...202).contains(http.statusCode) ? http.statusCode : 200
        try checked(http, expected: expected, data: data)
        let limit = route.isScreen ? 8 * 1024 * 1024 : 2_000_000
        guard data.count <= limit, http.mimeType?.lowercased() == mime else { throw APIError.malformed }
        return (data, http)
    }

}
