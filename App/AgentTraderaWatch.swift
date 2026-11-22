import Foundation
import Observation
import SwiftUI

enum AgentTraderaIntent {
    static func match(_ text: String) -> AgentChatAction.Kind? {
        let start = #"^(?:(?:kan|vil) du (?:godt |lige )?)?"#
        func starts(_ phrase: String) -> Bool {
            text.range(of: start + phrase, options: .regularExpression) != nil
        }
        if starts(#"(?:vis(?:e)?|tjek(?:ke)?|åbn(?:e)?|se) (?:mine |dine |alle )?(?:tradera[ -]?)?prisvagter\b"#) {
            return .traderaWatches
        }
        guard text.contains("tradera") || text.contains("prisvagt") || publicLink(in: text) != nil else { return nil }
        if listing(text) != nil { return .traderaWatch }
        if starts(#"(?:hold(?:e)? øje med|overvåg(?:e)?|følg(?:e)? prisen|(?:lav(?:e)?|opret(?:te)?|start(?:e)?|sæt(?:te)?) (?:en )?prisvagt|giv(?:e)? mig besked,? (?:når|hvis))\b"#) {
            return .traderaWatch
        }
        return nil
    }

    static func listing(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), ["www.tradera.com", "tradera.com"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.range(of: #"^/(?:[a-zA-Z]{2}/)?item/[0-9]+/[0-9]+(?:/[^/]*)?/?$"#, options: .regularExpression) != nil else { return nil }
        var clean = parts
        clean.query = nil
        clean.fragment = nil
        return clean.url
    }

    static func listingInPrompt(_ prompt: String) -> URL? {
        guard let match = prompt.range(of: #"https://(?:www\.)?tradera\.com/[^\s<>"]+"#,
                                       options: [.regularExpression, .caseInsensitive]) else { return nil }
        return listing(String(prompt[match]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)”")))
    }

    static func publicLink(in text: String) -> URL? {
        guard let match = text.range(of: #"https://[^\s<>"]+"#, options: [.regularExpression, .caseInsensitive]),
              let parts = URLComponents(string: String(text[match]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)”"))),
              let host = parts.host, host.contains("."), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        return parts.url
    }

    static func amount(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
        if value.range(of: #"^\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?$"#, options: .regularExpression) != nil {
            value = value.replacingOccurrences(of: ".", with: "")
        }
        guard value.range(of: #"^\d{1,10}(?:[,.]\d{1,2})?$"#, options: .regularExpression) != nil,
              let result = Double(value.replacingOccurrences(of: ",", with: ".")), result > 0, result <= 999_999_999.99 else { return nil }
        return result
    }

    static func limit(in prompt: String) -> (amount: String, currency: String) {
        let pattern = #"\b(?:under|lavere end|mindre end|billigere end)\s+(\d+(?:[.,]\d+)*)(?:\s*(dkk\b|sek\b|danske kroner\b|svenske kroner\b|nok\b|eur(?:o)?\b|usd\b|dollars?\b|gbp\b|pund\b|norske kroner\b|[€£$]))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let amount = Range(result.range(at: 1), in: prompt) else { return ("", "") }
        let unit = Range(result.range(at: 2), in: prompt).map { prompt[$0].lowercased() } ?? ""
        switch unit {
        case "dkk", "danske kroner": return (String(prompt[amount]), "DKK")
        case "sek", "svenske kroner": return (String(prompt[amount]), "SEK")
        case "": return (String(prompt[amount]), "")
        default: return ("", "")
        }
    }

    static func currency(for limit: String, wishes: [String]) -> String {
        if !limit.isEmpty { return limit }
        for wish in wishes {
            let text = wish.lowercased()
            guard text.range(of: #"\b(?:pris(?:er|erne|vagt\w*)?|valuta)\b"#, options: .regularExpression) != nil,
                  text.range(of: #"\b(?:ikke|undgå|undtagen|bortset|aldrig|hvis)\b"#, options: .regularExpression) == nil else { continue }
            let dkk = text.range(of: #"\b(?:dkk|danske kroner)\b"#, options: .regularExpression) != nil
            let sek = text.range(of: #"\b(?:sek|svenske kroner)\b"#, options: .regularExpression) != nil
            if dkk != sek { return dkk ? "DKK" : "SEK" }
        }
        return ""
    }
}

enum AgentTraderaSource: String, Codable {
    case api, traderaMail, publicPage
}

struct AgentTraderaAccess: Decodable {
    let configured: Bool
    let mailAvailable: Bool?
    let publicPageAvailable: Bool?

    var suggested: AgentTraderaSource {
        if configured || mailAvailable == nil { return .api }
        if publicPageAvailable == true { return .publicPage }
        return .traderaMail
    }

    func ready(_ source: AgentTraderaSource) -> Bool {
        switch source {
        case .api: configured
        case .traderaMail: mailAvailable == true
        case .publicPage: publicPageAvailable == true
        }
    }
}

struct AgentTraderaItem: Decodable, Identifiable {
    let id: UUID
    let url, title, state, currency: String
    let threshold: Double
    let price: Double?
    let priceCurrency, note, emailStatus: String?
    let lastChecked, alertedAt: Double?
    let source: AgentTraderaSource?
    let priceAt: Double?

    static func money(_ value: Double, _ code: String) -> String {
        value.formatted(.number.locale(Locale(identifier: "da_DK")).precision(.fractionLength(0...2))) + " " + code
    }

    var awaitsUpdate: Bool {
        switch state {
        case "watching", "waitingMail", "error", "currencyMismatch": true
        case "triggered": emailStatus == "waiting" || emailStatus == "unavailable"
        default: false
        }
    }

    var stateLabel: String {
        switch state {
        case "waitingMail": "Venter på en mail med en pris på annoncen"
        case "watching": source == .traderaMail ? "Følger priser fra Tradera-mails" : "Holder øje"
        case "triggered": source == .traderaMail ? "Tradera skrev en pris under din grænse" : "Prisen kom under din grænse"
        case "ended": "Annoncen er afsluttet"
        case "unavailable": "Annoncen er utilgængelig"
        case "currencyMismatch": "Valutaen skal tjekkes"
        case "cancelled": "Prisvagten er stoppet"
        default: "PC’en kunne ikke tjekke prisen"
        }
    }
}

private struct AgentTraderaList: Decodable { let watches: [AgentTraderaItem] }

extension View {
    @MainActor func traderaAlerts(using api: LiveAPI?) -> some View {
        task(id: "\(api?.queueTargetID ?? ""):\(AgentPriceAlerts.shared.revision)") {
            if let api { await AgentPriceAlerts.shared.observe(api) }
        }
    }
}

@MainActor @Observable final class AgentPriceAlerts {
    static let shared = AgentPriceAlerts()
    private(set) var revision = 0

    private func tracked(_ target: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: AppStorageKeys.notificationsActive("tradera", server: target)) as? [String: String] ?? [:]
    }

    func track(id: UUID, bot: UUID, target: String) {
        var values = tracked(target)
        guard values[id.uuidString] != bot.uuidString else { return }
        values[id.uuidString] = bot.uuidString
        UserDefaults.standard.set(values, forKey: AppStorageKeys.notificationsActive("tradera", server: target))
        revision += 1
    }

    func forget(id: UUID, target: String) {
        var values = tracked(target)
        guard values.removeValue(forKey: id.uuidString) != nil else { return }
        UserDefaults.standard.set(values, forKey: AppStorageKeys.notificationsActive("tradera", server: target))
    }

    func observe(_ api: LiveAPI) async {
        let target = api.queueTargetID
        while !Task.isCancelled {
            let pending = tracked(target)
            guard !pending.isEmpty else { return }
            for agent in Set(pending.values) {
                guard !Task.isCancelled else { return }
                guard let list: AgentTraderaList = try? await api.moduleJSON("tradera/watches", timeout: 15,
                    query: [.init(name: "bot_id", value: agent), .init(name: "include_web", value: "true")]) else { continue }
                guard !Task.isCancelled else { return }
                let existingIDs = Set(list.watches.map { $0.id.uuidString })
                for (id, owner) in pending where owner == agent && !existingIDs.contains(id) {
                    if let removed = UUID(uuidString: id) { forget(id: removed, target: target) }
                }
                for row in list.watches where pending[row.id.uuidString] == agent {
                    guard !Task.isCancelled else { return }
                    if row.state == "triggered" {
                        await JobNotifications.shared.completed(kind: "tradera", server: target,
                            id: agent + "/" + row.id.uuidString,
                            title: (row.source == .traderaMail ? "Pris i Tradera-mail under " : "Pris under ")
                                + AgentTraderaItem.money(row.threshold, row.currency) + " · " + String(row.title.prefix(80)))
                        forget(id: row.id, target: target)
                    } else if ["ended", "cancelled"].contains(row.state) {
                        forget(id: row.id, target: target)
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}

@MainActor struct AgentTraderaWatch: View {
    let api: LiveAPI?
    let bot: VillageBot
    let id: UUID
    let listOnly: Bool
    @State private var address: String
    @State private var amount: String
    @State private var currency: String
    @State private var email = false
    @State private var appID = ""
    @State private var appKey = ""
    @State private var savedKeys: [(id: UUID, title: String, values: [String: String])] = []
    @State private var access: AgentTraderaAccess?
    @State private var chosenSource: AgentTraderaSource?
    @State private var watches: [AgentTraderaItem] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var notice: String?
    @State private var cancelID: UUID?
    @State private var version = 0
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    init(api: LiveAPI?, bot: VillageBot, id: UUID, prompt: String, listOnly: Bool) {
        self.api = api
        self.bot = bot
        self.id = id
        self.listOnly = listOnly
        let limit = AgentTraderaIntent.limit(in: prompt)
        _address = State(initialValue: (AgentTraderaIntent.listingInPrompt(prompt) ?? AgentTraderaIntent.publicLink(in: prompt))?.absoluteString ?? "")
        _amount = State(initialValue: limit.amount)
        _currency = State(initialValue: AgentTraderaIntent.currency(for: limit.currency, wishes: AgentChatPreferences.entries(for: bot.id).map(\.value)))
    }

    private struct NewWatch: Encodable {
        let url: String
        let threshold: Double
        let currency: String
        let notifyByEmail: Bool
        let source: AgentTraderaSource
    }
    private var source: AgentTraderaSource {
        if let chosenSource { return chosenSource }
        if access?.publicPageAvailable == true, AgentTraderaIntent.publicLink(in: address) != nil,
           AgentTraderaIntent.listing(address) == nil { return .publicPage }
        return access?.suggested ?? .traderaMail
    }
    private var listingURL: URL? {
        if source == .publicPage, let url = AgentTraderaIntent.publicLink(in: address),
           url.absoluteString == address.trimmingCharacters(in: .whitespacesAndNewlines) { return url }
        return AgentTraderaIntent.listing(address)
    }
    private struct Cancelled: Decodable { let cancelled: Bool }
    private struct SingleWatch: Decodable { let watch: AgentTraderaItem? }
    private var scope: [URLQueryItem] { [.init(name: "bot_id", value: bot.id.uuidString), .init(name: "include_web", value: "true")] }
    private var visible: [AgentTraderaItem] { listOnly ? watches : watches.filter { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if api == nil {
                if let link = AgentTraderaIntent.listing(address) {
                    Link("Åbn annoncen på Tradera", destination: link)
                }
                FadedDetailText("Prisvagten bruger FadedAI på PC’en. Vend tilbage til denne samtale, når PC’en er forbundet.")
            } else {
                if loaded {
                    if listOnly && visible.isEmpty { Text("Ingen prisvagter hos " + bot.name + " endnu.") }
                    ForEach(visible) { row in item(row) }
                    if !listOnly && visible.isEmpty && access != nil { editor }
                }
                if busy || (!loaded && notice == nil) { ProgressView() }
                if let notice { Text(notice).font(.callout) }
                Button("Opdatér status", systemImage: "arrow.clockwise") { version += 1 }.disabled(busy)
            }
        }
        .privacySensitive()
        .task(id: "\(api?.queueTargetID ?? ""):\(version)") {
            await reload()
            while api != nil && phase == .active && visible.contains(where: \.awaitsUpdate) {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if !busy { await reload() }
            }
        }
        .onChange(of: phase) { _, value in if value == .active && !busy { version += 1 } }
        .confirmationDialog("Stop denne prisvagt?", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } })) {
            if let target = cancelID {
                Button("Stop prisvagt", role: .destructive) { run { try await stop(target) } }
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedDetailText("For at hente prisen direkte fra Tradera skal PC’en forbindes én gang. Alle dine agenter kan dele den forbindelse.")
            Link("Hent adgang hos Tradera", destination: URL(string: "https://api.tradera.com/register")!)
            if savedKeys.isEmpty {
                Button("Brug en gemt Tradera-nøgle fra Vault") {
                    do {
                        savedKeys = try PersonalVaultView.traderaCredentials()
                        if savedKeys.isEmpty { notice = "Vault har ingen gemt Tradera-nøgle. Du kan indtaste den nedenfor." }
                    } catch { notice = explanation(error) }
                }
            } else {
                ForEach(savedKeys, id: \.id) { key in
                    Button("Forbind PC’en med " + (key.title.isEmpty ? "Tradera-nøglen" : key.title)) {
                        run { try await connect(key.values) }
                    }.disabled(busy)
                }
            }
            TextField("App-ID fra Tradera", text: $appID).keyboardType(.numberPad)
            SecureField("App-nøgle fra Tradera", text: $appKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Forbind Tradera") { let credentials = ["appID": appID, "appKey": appKey]; run { try await connect(credentials) } }
                .disabled(busy || appID.isEmpty || appKey.isEmpty)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(source == .publicPage ? "Link til varesiden" : "Link til Tradera-annonce", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let listingURL { Link("Åbn varesiden", destination: listingURL) }
            TextField("Giv besked ved en pris under …", text: $amount).keyboardType(.decimalPad)
            Picker("Din prisgrænse er i", selection: $currency) {
                Text("Vælg valuta").tag("")
                Text("DKK · danske kroner").tag("DKK")
                Text("SEK · svenske kroner").tag("SEK")
            }
            if access?.mailAvailable != nil {
                Picker("Hvor skal prisen komme fra?", selection: Binding(get: { source }, set: { chosenSource = $0 })) {
                    if access?.publicPageAvailable == true {
                        Text("Læs varesiden uden login").tag(AgentTraderaSource.publicPage)
                    }
                    Text("Tradera-mails i Gmail").tag(AgentTraderaSource.traderaMail)
                    Text("Direkte fra Tradera").tag(AgentTraderaSource.api)
                }
            }
            if source == .traderaMail {
                FadedDetailText("Agenten følger nye Tradera-mails om netop denne annonce i din Gmail. Du får besked, hvis en mail angiver en pris under din grænse. Tradera sender kun mails om visse ændringer.")
                if access?.mailAvailable == false {
                    Button("Forbind min Gmail", systemImage: "envelope") { run { try await connectGmail() } }.disabled(busy)
                }
            } else if source == .publicPage {
                FadedDetailText("PC’en læser butikkens varepris hver halve time. Vælg den valuta, som butikken viser.")
            } else if access?.configured == false {
                setup
            }
            if access?.ready(source) == true {
                Toggle("Mail mig også ved en pris under grænsen", isOn: $email)
                FadedDetailText("PC’en følger prisen, mens FadedAI kører. Du kan lukke appen på telefonen.")
                Button(source == .traderaMail ? "Følg prisen via min Gmail" : "Start prisvagt", systemImage: "bell") { run { try await create() } }
                    .disabled(busy || listingURL == nil || AgentTraderaIntent.amount(amount) == nil || currency.isEmpty)
            }
        }
    }

    @ViewBuilder private func item(_ row: AgentTraderaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let link = row.source == .publicPage ? AgentTraderaIntent.publicLink(in: row.url) : AgentTraderaIntent.listing(row.url) {
                Link(row.title.isEmpty ? "Åbn annoncen" : row.title, destination: link)
            }
            Label(row.stateLabel, systemImage: row.state == "triggered" ? "bell.fill" : "tag")
            Text("Giv besked under " + AgentTraderaItem.money(row.threshold, row.currency))
            if let price = row.price, let code = row.priceCurrency {
                Text((row.source == .traderaMail ? "Pris i mailen: " : "Senest set til ") + AgentTraderaItem.money(price, code))
                if row.source == .traderaMail, let at = row.priceAt {
                    Text("Mail modtaget " + Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
            }
            if let checked = row.lastChecked {
                Text((row.source == .traderaMail ? "Gmail tjekket " : "Tjekket ") + Date(timeIntervalSince1970: checked).formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
            if let note = row.note, !note.isEmpty { FadedDetailText(note) }
            if row.emailStatus == "sent" { Label("Besked sendt til din Gmail", systemImage: "envelope") }
            if row.emailStatus == "unavailable" { FadedDetailText("Mailen kunne ikke sendes. Tjek din Gmail-forbindelse.") }
            if row.emailStatus == "uncertain" { FadedDetailText("Gmail har endnu ikke bekræftet afsendelsen.") }
            if row.state != "cancelled" {
                Button("Fjern prisvagt", systemImage: "trash", role: .destructive) { cancelID = row.id }.disabled(busy)
            }
        }
    }

    private func reload() async {
        guard let api else { return }
        do {
            let status: AgentTraderaAccess = try await api.moduleJSON("tradera/status", query: [.init(name: "include_web", value: "true")])
            let rows: [AgentTraderaItem]
            if listOnly {
                let result: AgentTraderaList = try await api.moduleJSON("tradera/watches", query: scope)
                rows = result.watches
            } else {
                let result: SingleWatch = try await api.moduleJSON("tradera/watches/" + id.uuidString, query: scope)
                rows = result.watch.map { [$0] } ?? []
            }
            try Task.checkCancellation()
            access = status
            if status.mailAvailable == nil { chosenSource = nil }
            watches = rows
            notice = nil
            loaded = true
        } catch { if !Task.isCancelled { notice = explanation(error) } }
    }

    private func connect(_ credentials: [String: String]) async throws {
        guard let api else { return }
        let status: AgentTraderaAccess = try await api.moduleJSON("tradera/settings", upload: JSONEncoder().encode(credentials), timeout: 25)
        guard status.configured else { throw APIError.malformed }
        appID = ""; appKey = ""; savedKeys = []
        chosenSource = .api
        version += 1
    }

    private func connectGmail() async throws {
        guard let api else { return }
        let link = try await api.composioLink("gmail")
        guard let url = link.loginURL else { throw APIError.malformed }
        openURL(url)
    }

    private func create() async throws {
        guard let api, let url = listingURL, let threshold = AgentTraderaIntent.amount(amount) else { return }
        guard access?.ready(source) == true else { return }
        let body = NewWatch(url: url.absoluteString, threshold: threshold, currency: currency, notifyByEmail: email, source: source)
        let watch: AgentTraderaItem = try await api.moduleJSON("tradera/watches/" + id.uuidString, upload: JSONEncoder().encode(body),
                                                              timeout: 40, query: scope)
        watches = [watch] + watches.filter { $0.id != watch.id }
        AgentPriceAlerts.shared.track(id: watch.id, bot: bot.id, target: api.queueTargetID)
        version += 1
    }

    private func stop(_ watch: UUID) async throws {
        guard let api else { return }
        let result: Cancelled = try await api.moduleJSON("tradera/watches/" + watch.uuidString + "/cancel",
                                                        upload: Data("{}".utf8), query: scope)
        guard result.cancelled else { throw APIError.malformed }
        watches.removeAll { $0.id == watch }
        AgentPriceAlerts.shared.forget(id: watch, target: api.queueTargetID)
        await reload()
        notice = "Prisvagten er stoppet."
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { notice = explanation(error) }
        }
    }

    private func explanation(_ error: Error) -> String {
        if case APIError.http(let status, let problem) = error {
            if let detail = problem?.message { return detail }
            if status == 404 { return "Opdatér FadedAI på PC’en for at bruge prisvagter." }
        }
        return AppErrorPresentation(error).title
    }
}
