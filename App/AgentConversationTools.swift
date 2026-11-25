import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

@MainActor enum ChatScreenWake {
    private static var active = Set<UUID>()
    private static var userPreference = false

    static func setUserPreference(_ value: Bool) {
        userPreference = value
        update()
    }

    static func hold(_ id: UUID, whileReplying replying: Bool) {
        if replying { active.insert(id) }
        else { active.remove(id) }
        update()
    }

    private static func update() {
        UIApplication.shared.isIdleTimerDisabled = userPreference || !active.isEmpty
    }
}

extension AgentPhoneChat {
    func shouldCheckGmail(_ message: String) -> Bool {
        keepHistory && !web && nextDocument == nil && (AgentGmailCheck.matches(message) || AgentGmailCheck.matchesLatest(message))
    }

    func startGmailCheck(_ message: String) {
        guard gmailCheck?.isChecking != true else { return }
        if handsFree { stopVoice() }
        composerFocused = false
        appleDictation.stop()
        if cleanDraft == message { draft = "" }
        notice = nil
        gmailCheck = .init(prompt: message, afterTurn: turns.last?.id)
    }

    func gmailCard(_ request: AgentGmailCheck.Request) -> some View {
        AgentGmailCheck(request: request, bot: bot, api: api).id(request.id)
    }
}

@MainActor struct AgentGmailCheck: View {
    @Observable @MainActor final class Request {
        let id = UUID()
        let prompt: String
        let afterTurn: UUID?
        private(set) var state: MailAppointmentState?
        private(set) var latestMail: BotMailMessages.Message?
        private(set) var latestContent: String?
        private(set) var latestThread: String?
        private(set) var messages: [BotMailMessages.Message] = []
        var isLatest: Bool { AgentGmailCheck.matchesLatest(prompt) }
        var isUnreadList: Bool { AgentGmailCheck.isUnreadList(prompt) }
        private(set) var status = "Tjekker Gmail…"
        private(set) var isChecking = false
        private(set) var usedPhone = false
        private(set) var failed = false
        private var started = false

        init(prompt: String, afterTurn: UUID?) {
            self.prompt = prompt
            self.afterTurn = afterTurn
        }

        func run(bot: VillageBot, api: LiveAPI?) async {
            guard !started else { return }
            started = true
            failed = false
            messages = []; latestMail = nil; latestContent = nil; latestThread = nil; state = nil
            status = "Tjekker Gmail…"
            isChecking = true
            defer { isChecking = false }
            do {
                if isLatest {
                    usedPhone = AgentInternetTools.phoneAvailable
                    let lower = prompt.lowercased()
                    let query = lower.contains("ulæst") || isUnreadList ? "in:inbox is:unread" : "in:inbox"
                    let result = try await AgentInternetTools.gmailMessages(query: query, api: api)
                    try Task.checkCancellation()
                    guard let mail = result.messages.first else {
                        status = query.contains("unread") ? "Du har ingen ulæste mails i indbakken." : "Din indbakke er tom."
                        return
                    }
                    if isUnreadList {
                        messages = Array(result.messages.prefix(12))
                        status = "Her er op til 12 ulæste mails. Tryk på en mail for at læse den."
                    } else {
                        try await load(mail, api: api)
                    }
                    return
                }
                guard let api else {
                    status = "Aftalesøgningen kører på PC’en. Du kan stadig bede om din seneste mail eller dine ulæste mails direkte på iPhone."
                    return
                }
                let initial = try await api.mailAppointments(bot.id)
                guard initial.enabled else {
                    status = initial.otherBot ? "En anden agent står for aftalesøgningen."
                        : "Slå aftalesøgning til for \(bot.name) i Gmail-aftaler."
                    return
                }
                _ = try await api.scanMailAppointments(bot.id)
                for _ in 0..<12 {
                    try await Task.sleep(for: .seconds(3))
                    let latest = try await api.mailAppointments(bot.id)
                    guard latest.enabled else {
                        status = "Aftalesøgningen er ikke længere slået til for \(bot.name)."
                        return
                    }
                    if let checked = latest.checked, checked > (initial.checked ?? 0) {
                        state = latest
                        status = latest.notice ?? (latest.appointments.isEmpty
                            ? "Ingen kommende aftaler i det seneste opslag." : "Seneste fund fra Gmail")
                        return
                    }
                }
                status = "Søgningen er sat i gang på PC’en. Se dens status i Gmail-aftaler."
            } catch is CancellationError {
                status = isLatest ? "Mailopslaget blev stoppet." : "Se status for aftalesøgningen i Gmail-aftaler."
            } catch {
                failed = true
                if case APIError.http(_, let problem) = error, let message = problem?.message { status = message }
                else { status = AppErrorPresentation(error).title }
            }
        }

        func open(_ mail: BotMailMessages.Message, api: LiveAPI?) async {
            guard !isChecking else { return }
            isChecking = true
            failed = false
            status = "Læser mailen…"
            latestMail = nil
            latestContent = nil
            latestThread = nil
            defer { isChecking = false }
            do { try await load(mail, api: api) }
            catch {
                failed = true
                if case APIError.http(_, let problem) = error, let message = problem?.message { status = message }
                else { status = AppErrorPresentation(error).title }
            }
        }

        private func load(_ mail: BotMailMessages.Message, api: LiveAPI?) async throws {
            usedPhone = AgentInternetTools.phoneAvailable
            let content = try await AgentInternetTools.gmailMessage(id: mail.id, api: api)
            try Task.checkCancellation()
            if let id = content.messageID, id != mail.id { throw APIError.malformed }
            latestThread = content.messageID == mail.id ? content.threadID : nil
            latestMail = mail
            latestContent = content.text.isEmpty ? "Mailen indeholder ingen læsbar tekst." : content.text
            status = isUnreadList ? "Her er den valgte mail:" : "Her er din seneste mail:"
        }

        func retry(bot: VillageBot, api: LiveAPI?) async {
            guard !isChecking else { return }
            started = false
            await run(bot: bot, api: api)
        }
    }

    let request: Request
    let bot: VillageBot
    let api: LiveAPI?
    @State private var showReview = false

    nonisolated static func matches(_ message: String) -> Bool {
        let words = message.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let pattern = #"^(?:har jeg (?:nye |kommende |nogle )*aftaler|(?:tjek|søg efter|find) (?:mine |efter |nye |kommende )*aftaler) (?:i|fra) (?:min )?gmail[?.!]*$"#
        return words.range(of: pattern, options: .regularExpression) != nil
    }

    nonisolated static func matchesLatest(_ message: String) -> Bool {
        let words = message.lowercased()
        if words.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("hvordan ") { return false }
        let mail = words.contains("mail") || words.contains("indbakke")
        let recent = ["seneste", "nyeste", "sidste", "ulæst", "latest", "newest"].contains { words.contains($0) }
        let action = words.range(of: #"(?:^|\s)(?:se|vis|læs|læse|tjek|find|hent|hvad|read|show|check)(?:\s|[?.!]|$)"#, options: .regularExpression) != nil
        return mail && ((recent && action) || isUnreadList(message))
    }

    nonisolated static func isUnreadList(_ message: String) -> Bool {
        let words = message.lowercased()
        let pluralMail = words.range(of: #"\b(?:e-?mails|mails|emails|indbakken)\b"#, options: .regularExpression) != nil
        let unread = words.contains("ulæst") || words.range(of: #"\b(?:nye|ny)\b"#, options: .regularExpression) != nil
        let action = words.range(of: #"\b(?:har|er|se|vis|læs|tjek|find|hent|hvad)\b"#, options: .regularExpression) != nil
        return pluralMail && unread && action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentChatBubble(user: true, title: "Dig", pc: false) {
                Text(request.prompt).textSelection(.enabled)
            }
            AgentChatBubble(user: false, title: "\(bot.name) · Gmail" + (request.usedPhone ? " · iPhone" : ""), pc: !request.usedPhone) {
                if request.isChecking { ProgressView(request.status) }
                else { Text(request.status) }
                if request.isLatest && !request.isChecking {
                    if request.failed { ComposioCloudSetup(api: api) }
                    Button("Tjek Gmail igen") { Task { await request.retry(bot: bot, api: api) } }
                }
                if !request.messages.isEmpty {
                    ForEach(request.messages) { mail in
                        Button {
                            Task { await request.open(mail, api: api) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mail.subject.isEmpty ? "Uden emne" : mail.subject).font(.subheadline.weight(.semibold))
                                Text(mail.sender).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(request.isChecking)
                    }
                }
                if let mail = request.latestMail, let content = request.latestContent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mail.subject.isEmpty ? "Uden emne" : mail.subject).font(.headline)
                        Text("Fra: \(mail.sender)").font(.subheadline)
                        if let value = Double(mail.timestamp), value.isFinite, (1...4_200_000_000_000).contains(value) {
                            Text(Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value),
                                 format: .dateTime.day().month(.abbreviated).hour().minute()).font(.caption)
                        }
                        Text(content).textSelection(.enabled)
                        if let link = AgentMailEvidenceLink.gmail(request.latestThread) {
                            Link("Åbn samtalen i Gmail", destination: link).frame(minHeight: 44)
                        }
                    }
                }
                if let state = request.state, state.notice == nil {
                    ForEach(Array(state.appointments.prefix(5))) { appointment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appointment.title).font(.headline)
                            if let date = appointment.date {
                                if !appointment.canApply { Text("Tidligere tidspunkt").font(.caption) }
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            }
                            if !appointment.canApply {
                                Text(appointment.revisionStatus == "cancelled" ? "Aflyst" : "Flyttet").font(.caption)
                            } else if appointment.date == nil {
                                Text("Tidspunktet skal tjekkes i mailen.").font(.caption)
                            }
                            if let api {
                                AgentMailEvidenceLink(api: api, botID: bot.id, appointment: appointment)
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                if api != nil && !request.isLatest {
                    Button("Åbn Gmail-aftaler", systemImage: "calendar.badge.envelope") { showReview = true }
                        .frame(minHeight: 44)
                }
            }
        }
        .privacySensitive()
        .sheet(isPresented: $showReview) {
            if let api { AgentGmailReview(api: api, bot: bot) }
        }
    }
}

@MainActor struct AgentMailEvidenceLink: View {
    struct Source: Decodable {
        let before, quote, after, messageID: String
        let threadID: String?
    }

    let api: LiveAPI
    let botID: UUID
    let appointment: MailAppointmentState.Appointment
    @State private var open = false
    @State private var source: Source?
    @State private var notice: String?

    nonisolated static func gmail(_ thread: String?) -> URL? {
        guard let thread, (1...128).contains(thread.utf8.count),
              thread.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/0/#all/" + thread)
    }

    @ViewBuilder var body: some View {
        if appointment.hasSource == true {
            Button("Vis kildemail", systemImage: "text.quote") {
                source = nil
                notice = nil
                open = true
            }.frame(minHeight: 44)
                .sheet(isPresented: $open, onDismiss: { source = nil; notice = nil }) {
                    NavigationStack {
                        Group {
                            if let source {
                                message(source)
                            } else if let notice {
                                Text(notice).padding()
                            } else {
                                ProgressView("Åbner kildemailen…")
                            }
                        }
                        .navigationTitle("Kildemail")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { open = false } } }
                    }.task {
                        do {
                            let result: Source = try await api.moduleJSON("mail-appointments/\(botID.uuidString)/\(appointment.id.uuidString)/source", timeout: 75)
                            try Task.checkCancellation()
                            source = result
                        } catch {
                            if Task.isCancelled { return }
                            if case APIError.http(_, let problem) = error, let detail = problem?.message { notice = detail }
                            else { notice = "Kildemailen kunne ikke hentes. Tjek forbindelsen til PC’en og Gmail." }
                        }
                    }.privacySensitive()
                }
        } else {
            Text("Dette forslag mangler en kontrolleret kildelinje.").font(.caption)
            if let link = Self.gmail(appointment.gmailThread) {
                Link("Åbn samtalen i Gmail", destination: link).frame(minHeight: 44)
            }
        }
    }

    private func message(_ source: Source) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if source.quote.isEmpty {
                        Text("Agenten kunne ikke bekræfte tidspunktet i en bestemt linje.").font(.callout)
                    }
                    if !source.before.isEmpty { Text(verbatim: source.before) }
                    if !source.quote.isEmpty {
                        Text(verbatim: source.quote)
                            .fontWeight(.semibold)
                            .padding(10)
                            .background(Color.accentColor.opacity(0.17), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Kildested. " + source.quote)
                            .id("evidence")
                    }
                    if !source.after.isEmpty { Text(verbatim: source.after) }
                    if let url = Self.gmail(source.threadID) {
                        Link("Åbn samtalen i Gmail", destination: url).frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
            }.onAppear { if !source.quote.isEmpty { reader.scrollTo("evidence", anchor: .center) } }
        }
    }
}

@MainActor private struct AgentGmailReview: View {
    let api: LiveAPI
    let bot: VillageBot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MailAppointmentsView(api: api, bot: bot)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}

struct AgentReplyCard: Codable, Sendable {
    let title: String
    let items: [String]

    static func decode(_ reply: String) -> Self? {
        let data = ModelJSON.payload(reply)
        guard data.count <= 8_000,
              let card = try? JSONDecoder().decode(Self.self, from: data),
              (1...120).contains(card.title.count), (1...8).contains(card.items.count),
              card.items.allSatisfy({ (1...450).contains($0.count) }) else { return nil }
        return card
    }

    var plainText: String { ([title] + items.map { "• " + $0 }).joined(separator: "\n") }
}

enum AgentLocalTool {
    static let instructions = """
        Du kan regne med calculator og finde datoen med date. Når et spørgsmål kræver dem,
        kan du først svare med kun JSON, f.eks. {"tool":"calculator","input":"859*0.17"}
        eller {"tool":"date","input":"14"} for dato om 14 dage, og 0 for dato og klokkeslæt nu.
        Brug et fortegn for dage før i dag. Du kan bede om ét opslag ad gangen, hvis næste opslag afhænger af svaret.
        Afslut med et almindeligt svar, når du har de oplysninger, brugeren bad om.
        """

    static let calendarInstructions = """
        calendar læser antal aftaler og deres tider på én dag. Brug {"tool":"calendar","input":"0"} for i dag,
        1 for i morgen eller et andet helt antal dage fra i dag.
        """

    static func asksAboutOwnCalendar(_ text: String) -> Bool {
        let pattern = #"\b(?:min kalender|mine (?:aftaler|møder)|(?:aftaler|møder) har jeg|my (?:calendar|appointments|meetings|schedule)|(?:meetings|appointments) do I have)\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func answer(_ reply: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let calls = requests(reply), calls.count == 1 else { return nil }
        return answer(calls[0], now: now, calendar: calendar)
    }

    static func answer(_ request: Request, now: Date, calendar: Calendar) -> String? {
        switch request.tool {
        case "calculator":
            guard let value = calculate(request.input) else { return "Regnestykket kunne ikke beregnes." }
            return "Lommeregnerens resultat: " + value.formatted(.number.precision(.fractionLength(0...10)))
        case "date":
            guard let days = Int(request.input), (-3_650...3_650).contains(days),
                  let date = calendar.date(byAdding: .day, value: days, to: now) else { return "Datoen kunne ikke beregnes." }
            let style = Date.FormatStyle(date: .complete, time: days == 0 ? .shortened : .omitted,
                                         locale: Locale(identifier: "da_DK"), calendar: calendar, timeZone: calendar.timeZone)
            return "Dato og klokkeslæt på iPhone: " + date.formatted(style)
        default:
            return nil
        }
    }

    static func calculate(_ raw: String) -> Double? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard (1...120).contains(normalized.utf8.count) else { return nil }
        var parser = Expression(chars: Array(normalized.filter { !$0.isWhitespace }))
        guard let result = parser.expression(), parser.index == parser.chars.count, result.isFinite else { return nil }
        return result
    }

    private struct Expression {
        let chars: [Character]
        var index = 0
        var next: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var result = term() else { return nil }
            while let op = next, op == "+" || op == "-" {
                index += 1
                guard let value = term() else { return nil }
                result = op == "+" ? result + value : result - value
            }
            return result
        }

        mutating func term() -> Double? {
            guard var result = factor() else { return nil }
            while let op = next, op == "*" || op == "/" {
                index += 1
                guard let value = factor(), op != "/" || value != 0 else { return nil }
                result = op == "*" ? result * value : result / value
            }
            return result
        }

        mutating func factor() -> Double? {
            let sign = next == "-" ? -1.0 : 1.0
            if sign < 0 { index += 1 }
            let value: Double
            if next == "(" {
                index += 1
                guard let contained = expression(), next == ")" else { return nil }
                index += 1
                value = contained
            } else {
                let start = index
                while let char = next, char.isASCII && (char.isNumber || char == ".") { index += 1 }
                guard start < index, let number = Double(String(chars[start..<index])) else { return nil }
                value = number
            }
            if next == "%" { index += 1; return sign * value / 100 }
            return sign * value
        }
    }
}

struct AgentWebSources: Decodable, Sendable {
    struct Source: Codable, Sendable, Identifiable {
        let title: String
        let url: URL
        let readPage: Bool
        var id: URL { url }

        var isWeb: Bool {
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
        }
    }
    let context: String
    let sources: [Source]
}

@MainActor struct AgentPCToolsView: View {
    let api: LiveAPI
    let botID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AgentBuiltTools(api: api)
                } label: { Label("Byg og brug værktøjer", systemImage: "hammer") }
                NavigationLink {
                    AgentPCImageView(api: api, botID: botID)
                } label: { Label("Lav billede", systemImage: "photo") }
                NavigationLink {
                    PCVideoGenerationView(api: api, initialPrompt: "")
                } label: { Label("Lav video", systemImage: "film") }
                NavigationLink {
                    BatchReviewView(api: api)
                } label: { Label("Kodeforslag", systemImage: "curlybraces") }
            }
            .navigationTitle("Agentens PC-værktøjer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}

@MainActor private struct AgentPCImageView: View {
    let api: LiveAPI
    let botID: UUID
    @State private var useStyle = true
    @State private var prompt = ""
    @State private var image: UIImage?
    @State private var running: Task<Void, Never>?
    @State private var notice: String?
    private var description: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var style: AgentImageTasteStyle? { AgentImageTasteStyle.selected(for: botID) }
    private var generatedPrompt: String { useStyle ? style?.applying(to: description) ?? description : description }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedDetailText("Din beskrivelse sendes til den parrede PC, når du trykker Lav billede.")
                TextField("Beskriv billedet", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .disabled(running != nil)
                if let style {
                    Toggle("Brug min billedstil · " + style.title, isOn: $useStyle).disabled(running != nil)
                    if useStyle && generatedPrompt.unicodeScalars.count > 1_000 {
                        FadedDetailText("Forkort beskrivelsen, eller slå billedstilen fra.")
                    }
                }
                FadedPrimaryButton("Lav billede", icon: "wand.and.stars", action: generate)
                    .disabled(running != nil || !(1...1_000).contains(generatedPrompt.unicodeScalars.count))
                if running != nil { ProgressView("PC’en genererer billedet…") }
                if let notice { FadedDetailText(notice) }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: FadedRadius.medium))
                        .accessibilityLabel("Genereret billede")
                    Button("Slet billedvisning", systemImage: "trash", role: .destructive) {
                        self.image = nil
                    }
                    .frame(minHeight: 44)
                    .disabled(running != nil)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Lav billede på PC")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { running?.cancel() }
    }

    private func generate() {
        let input = generatedPrompt
        guard running == nil, (1...1_000).contains(input.unicodeScalars.count) else { return }
        notice = nil
        running = Task {
            defer { running = nil }
            do {
                let data = try await api.v2GenerateImage(prompt: input)
                try Task.checkCancellation()
                guard let generated = UIImage(data: data) else { throw APIError.malformed }
                image = generated
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
                else { notice = "Billedet kunne ikke laves. Tjek PC-forbindelsen og billedmodellen." }
            }
        }
    }
}
