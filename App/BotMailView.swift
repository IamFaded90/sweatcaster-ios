import SwiftUI

enum AgentEmailRequest: String, Codable {
    case address, signup, inbox, mailbox

    var title: String {
        switch self {
        case .address: "Agentens e-mail"
        case .signup: "Tilmeld agenten"
        case .inbox: "Agentens indbakke"
        case .mailbox: "Agentens egen postkasse"
        }
    }

    static func match(_ text: String) -> Self? {
        let lead = #"^(?:(?:kan|vil) du (?:lige |godt )?|please |can you )?"#
        func matches(_ pattern: String) -> Bool {
            text.range(of: lead + pattern, options: .regularExpression) != nil
        }
        if matches(#"(?:tilmeld(?:e)? dig|skriv(?:e)? dig op|registr(?:ér|er|ere) dig|sign (?:yourself )?up|opret(?:te)? en konto (?:til dig selv|med din (?:egen )?(?:e-?mail|mail)))\b"#) {
            return .signup
        }
        if matches(#"(?:tjek(?:ke)?|vis(?:e)?|åbn(?:e)?|læs(?:e)?|check|read|open) (?:din(?:e)? (?:egen |egne )?(?:indbakke|(?:e-?)?mails?|post)|your (?:own )?inbox)$"#) { return .inbox }
        if matches(#"(?:opret(?:te)?|lav(?:e)?|få|åbn(?:e)?) (?:dig )?(?:din (?:egen |selvstændige )?|en (?:egen |selvstændig )?|egen )postkasse(?: til dig selv)?$"#)
            || matches(#"(?:create|get|open) your (?:own |separate )?mailbox$"#) { return .mailbox }
        let address = #"(?:(?:e-?)?mail(?:adresse)?|postkasse)"#
        if matches(#"(?:opret(?:te)?|lav(?:e)?|få) (?:dig )?(?:(?:din(?: egen)?|en egen|egen) "# + address + #"|en (?:e-?mailadresse|mailadresse|postkasse)|en "# + address + #" til dig selv)$"#)
            || matches(#"(?:vis(?: mig)?|hvad er) din (?:egen )?"# + address + "$")
            || matches(#"(?:create|get) your own (?:email(?: address)?|mailbox)$"#) { return .address }
        return nil
    }
}

private struct AgentEmailIdentity: Decodable {
    enum Kind: String, Decodable { case gmailAlias, mailbox }
    let address: String
    let kind: Kind
}

struct AgentEmailCard: View {
    let api: LiveAPI
    let bot: VillageBot
    let request: AgentEmailRequest
    let prompt: String
    private let selectionKey: String
    @State private var dedicated: Bool

    init(api: LiveAPI, bot: VillageBot, request: AgentEmailRequest, prompt: String) {
        self.api = api
        self.bot = bot
        self.request = request
        self.prompt = prompt
        let key = "fadedai.agent-email.dedicated." + api.queueTargetID + "." + bot.id.uuidString
        selectionKey = key
        _dedicated = State(initialValue: request == .mailbox || UserDefaults.standard.bool(forKey: key))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Brug adresse", selection: $dedicated) {
                Text("Via Gmail").tag(false)
                Text("Egen postkasse").tag(true)
            }.pickerStyle(.segmented)
            AgentEmailContent(api: api, bot: bot, request: request, prompt: prompt, dedicated: dedicated) {
                UserDefaults.standard.set(dedicated, forKey: selectionKey)
            }
                .id(dedicated)
        }
        .onChange(of: dedicated) { _, value in
            UserDefaults.standard.set(value, forKey: selectionKey)
        }
    }
}

private struct AgentEmailContent: View {
    let api: LiveAPI
    let bot: VillageBot
    let request: AgentEmailRequest
    let prompt: String
    let dedicated: Bool
    let rememberAddress: () -> Void

    @State private var identity: AgentEmailIdentity?
    @State private var inbox: [BotMailMessages.Message]?
    @State private var message: BotMailContent?
    @State private var selectedID: String?
    @State private var loading = false
    @State private var notice: String?
    @State private var site = ""
    @State private var showSite = false
    @State private var revision = 0
    @State private var showInbox = false
    @State private var signupInbox = false
    @State private var verificationURL: URL?
    @State private var setupState: BotMailboxState?

    private var path: String { "agent-email/" + bot.id.uuidString.lowercased() }
    private var gmailQuery: [URLQueryItem] { [.init(name: "gmail", value: "true")] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dedicated, identity == nil, let setupState {
                AgentMailboxSetup(api: api, bot: bot, state: setupState) { updated in
                    self.setupState = updated
                    if updated.active {
                        rememberAddress()
                        revision += 1
                    }
                }
            }
            if let identity {
                Text(identity.address).font(.headline).textSelection(.enabled)
                FadedDetailText(identity.kind == .gmailAlias
                                ? "Post til denne agentadresse kommer i din tilsluttede Gmail."
                                : "\(bot.name) har sin egen postkasse.")
                Button("Kopiér adresse", systemImage: "doc.on.doc") {
                    rememberAddress()
                    UIPasteboard.general.string = identity.address
                }
                if request == .signup { siteControls }
                Button("Tjek agentens post", systemImage: "envelope.open") {
                    rememberAddress()
                    showInbox = true
                    revision += 1
                }.disabled(loading)
                messagesView
                if request != .signup {
                    DisclosureGroup("Tilmeld med denne adresse") { siteControls }
                }
            }
            if loading { ProgressView("Henter fra PC’en…") }
            if let notice {
                Text(notice).font(.callout)
                Button("Prøv igen") { selectedID = nil; revision += 1 }
            }
        }
        .privacySensitive()
        .onAppear {
            if site.isEmpty, request == .signup, let url = AgentSignupPage.link(in: prompt) { site = url.absoluteString }
        }
        .task(id: revision) { await refresh() }
        .task(id: selectedID) {
            guard let selectedID else { return }
            do {
                let item: BotMailContent
                if dedicated {
                    item = try await api.botMailMessage(bot.id, id: selectedID)
                } else {
                    item = try await api.moduleJSON(path + "/message", timeout: 40,
                        query: gmailQuery + [.init(name: "message_id", value: selectedID)])
                }
                if !Task.isCancelled { message = item }
            } catch { if !Task.isCancelled { notice = explanation(error) } }
        }
        .sheet(isPresented: $showSite) {
            if let url = AgentSignupPage.siteURL(site), let identity {
                AgentSignupPage(url: url, address: identity.address, name: bot.name, verificationURL: $verificationURL) {
                    showInbox = true
                    signupInbox = true
                    revision += 1
                }
                .sheet(isPresented: $signupInbox) {
                    NavigationStack {
                        List {
                            if loading { ProgressView() }
                            messagesView
                            if let notice { Text(notice) }
                            Button("Tjek igen") { revision += 1 }.disabled(loading)
                        }
                        .navigationTitle("Post til " + bot.name)
                        .toolbar { Button("Luk") { signupInbox = false } }
                    }
                }
            }
        }
    }

    private var siteControls: some View {
        VStack(alignment: .leading) {
            TextField("Link til tilmeldingssiden", text: $site)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Åbn tilmelding", systemImage: "person.badge.plus") {
                rememberAddress()
                showSite = true
            }
                .disabled(AgentSignupPage.siteURL(site) == nil)
        }
    }

    @ViewBuilder private var messagesView: some View {
        if let inbox {
            if inbox.isEmpty { FadedDetailText("Der er ingen mails til denne agent endnu.") }
            ForEach(inbox) { row in
                Button {
                    message = nil
                    selectedID = selectedID == row.id ? nil : row.id
                } label: {
                    VStack(alignment: .leading) {
                        Text(row.subject.isEmpty ? "Uden emne" : row.subject)
                        Text(row.sender).font(.caption)
                    }
                }
                if selectedID == row.id, let message {
                    Text(message.text).textSelection(.enabled)
                    ForEach(AgentSignupPage.links(in: message.text), id: \.self) { url in
                        let label = "Åbn link hos " + (url.host ?? "afsenderen")
                        if signupInbox {
                            Button(label) { verificationURL = url; signupInbox = false }
                        } else {
                            Link(label, destination: url)
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        notice = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            if dedicated {
                let state = try await api.botMailbox(bot.id)
                try Task.checkCancellation()
                setupState = state
                guard state.active, let address = state.address else { identity = nil; return }
                identity = AgentEmailIdentity(address: address, kind: .mailbox)
            } else {
                let body = try JSONEncoder().encode(["name": bot.name])
                let agent: AgentEmailIdentity = try await api.moduleJSON(path, upload: body, timeout: 48, query: gmailQuery)
                try Task.checkCancellation()
                guard agent.kind == .gmailAlias else {
                    identity = nil
                    notice = "Opdatér FadedAI på PC’en for at vælge Gmail og egen postkasse hver for sig."
                    return
                }
                identity = agent
            }
            if request == .inbox || showInbox {
                selectedID = nil
                message = nil
                let list: BotMailMessages
                if dedicated { list = try await api.botMailMessages(bot.id) }
                else { list = try await api.moduleJSON(path + "/messages", timeout: 90, query: gmailQuery) }
                if !Task.isCancelled { inbox = list.messages }
            }
        } catch {
            if !Task.isCancelled { notice = explanation(error) }
        }
    }

    private func explanation(_ error: Error) -> String {
        if case APIError.http(let status, let problem) = error {
            if status == 404 && identity == nil { return "Opdatér FadedAI på din PC for at bruge agentens e-mail." }
            if let detail = problem?.message, !detail.isEmpty { return detail }
        }
        return AppErrorPresentation(error).title
    }
}


struct BotMailboxState: Decodable, Sendable {
    let configured: Bool
    let address: String?
    let active: Bool
    let verificationRequired: Bool?
    let verificationElsewhere: Bool?
}

struct BotMailMessages: Decodable, Sendable {
    struct Message: Decodable, Identifiable, Sendable {
        let id, sender, subject, timestamp: String
        let threadID: String?
    }

    let messages: [Message]
}

struct BotMailContent: Decodable, Sendable {
    let text: String
    let messageID, threadID: String?
}

struct MailAppointmentState: Decodable, Sendable {
    struct Appointment: Decodable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let location: String
        let start: TimeInterval?
        let end: TimeInterval?
        let gmailThread: String?
        let revisionStatus: String?
        let hasSource: Bool?

        var date: Date? { start.map { Date(timeIntervalSince1970: $0) } }
        var canApply: Bool { revisionStatus == nil || revisionStatus == "active" }
    }

    let enabled: Bool
    let otherBot: Bool
    let hasProject: Bool
    let checked: TimeInterval?
    let notice: String?
    let appointments: [Appointment]
}

@MainActor struct MailAppointmentsView: View {
    private struct Review: Identifiable {
        let id: UUID
        let source: MailAppointmentState.Appointment
        let action: BotPhoneAction
    }

    let api: LiveAPI
    let bot: VillageBot
    var appointmentID: UUID? = nil
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var state: MailAppointmentState?
    @State private var reviewing: Review?
    @State private var busy = false
    @State private var notice: String?
    @State private var showingAll = false
    @AppStorage("fadedai.phone-job.applied") private var applied = ""

    var body: some View {
        List {
            Section("Din Gmail") {
                Text("Når aftalesøgning er slået til, finder \(bot.name) mulige aftaler via PC’en. Du godkender hver handling her.")
                if let state {
                    setup(state)
                } else if notice == nil {
                    ProgressView()
                }
                if busy { ProgressView() }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            if let state, state.enabled {
                Section("Forslag") {
                    let selected = showingAll ? nil : appointmentID
                    let suggestions = state.appointments.filter { selected == nil || selected == $0.id }
                    if suggestions.isEmpty {
                        Text(selected == nil ? "Ingen kommende aftaler fundet." : "Forslaget er ikke længere tilgængeligt.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(suggestions) { appointment in
                        appointmentRow(appointment)
                    }
                    if selected != nil {
                        Button("Vis alle forslag", systemImage: "list.bullet") { showingAll = true }.frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle("Gmail-aftaler")
        .privacySensitive()
        .refreshable { await refresh() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
        .onChange(of: state?.appointments) { _, appointments in
            if let reviewing, appointments?.contains(reviewing.source) != true {
                self.reviewing = nil
                notice = "Mailen er opdateret. Åbn det seneste forslag."
            }
        }
        .sheet(item: $reviewing) { review in
            BotPhoneActionReview(action: review.action, jobID: review.id, botName: bot.name) {
                var IDs = applied.split(separator: ",").map(String.init)
                if !IDs.contains(review.id.uuidString) { IDs.append(review.id.uuidString) }
                applied = IDs.suffix(500).joined(separator: ",")
            }
        }
    }

    @ViewBuilder private func setup(_ state: MailAppointmentState) -> some View {
        if state.enabled {
            Label("Aftalesøgning er slået til", systemImage: "checkmark.circle")
            if let checked = state.checked {
                Text("Sidst tjekket \(Date(timeIntervalSince1970: checked).formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Søg efter aftaler nu", systemImage: "arrow.clockwise") {
                update { try await api.scanMailAppointments(bot.id) }
            }
            Button("Slå aftalesøgning fra") {
                update { try await api.mailAppointments(bot.id, enabled: false) }
            }
            if let problem = state.notice { Text(problem).font(.footnote).foregroundStyle(.secondary) }
            if state.notice != nil && state.hasProject {
                Button("Forbind Gmail igen", systemImage: "envelope") { connect() }
            }
        } else if state.hasProject {
            Button("Log ind på Gmail", systemImage: "envelope") { connect() }
            Button(state.otherBot ? "Flyt aftalesøgning til \(bot.name)" : "Slå aftalesøgning til") {
                update { try await api.mailAppointments(bot.id, enabled: true) }
            }
        } else {
            Text("Gem din Composio-projektnøgle på PC’en for at forbinde Gmail.").foregroundStyle(.secondary)
        }
    }

    private func appointmentRow(_ appointment: MailAppointmentState.Appointment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appointment.title).font(.headline)
            if appointment.revisionStatus == "cancelled" {
                Label("Aflyst ifølge Gmail", systemImage: "calendar.badge.minus")
                    .font(.subheadline.weight(.semibold))
            } else if appointment.revisionStatus == "superseded" {
                Label("Flyttet ifølge Gmail", systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.semibold))
            }
            if let date = appointment.date {
                if !appointment.canApply { Text("Tidligere tidspunkt").font(.caption) }
                Text(date.formatted(date: .abbreviated, time: .shortened))
            } else if appointment.canApply {
                Text("Hvornår er aftalen? Mailen mangler et sikkert tidspunkt.")
                    .foregroundStyle(.secondary)
            }
            if !appointment.location.isEmpty { Text(appointment.location).foregroundStyle(.secondary) }
            AgentMailEvidenceLink(api: api, botID: bot.id, appointment: appointment)
            ForEach(BotPhoneActionKind.allCases, id: \.self) { kind in
                if kind != .alarm || BotPhoneActionReview.supportsAlarms {
                    let review = review(appointment, kind)
                    if applied.split(separator: ",").contains(Substring(review.id.uuidString)) {
                        Label("\(kind.title) oprettet", systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if appointment.canApply {
                        Button(kind.title, systemImage: icon(kind)) { reviewing = review }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                    }
                }
            }
            if !appointment.canApply && BotPhoneActionKind.allCases.contains(where: {
                applied.split(separator: ",").contains(Substring(review(appointment, $0).id.uuidString))
            }) {
                Text("Tjek også de handlinger, du tidligere oprettede på iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Skjul forslag") { update { try await api.hideMailAppointment(bot.id, id: appointment.id) } }
                .buttonStyle(.borderless)
        }
    }

    private func icon(_ kind: BotPhoneActionKind) -> String {
        switch kind {
        case .calendar: "calendar.badge.plus"
        case .reminder: "checklist"
        case .alarm: "alarm"
        }
    }

    static func actionID(_ sourceID: UUID, _ kind: BotPhoneActionKind) -> UUID {
        var bytes = sourceID.uuid
        switch kind {
        case .calendar: bytes.15 ^= 1
        case .reminder: bytes.15 ^= 2
        case .alarm: bytes.15 ^= 3
        }
        return UUID(uuid: bytes)
    }

    private func review(_ appointment: MailAppointmentState.Appointment, _ kind: BotPhoneActionKind) -> Review {
        let desired = appointment.date.map { date in
            let earlier = date.addingTimeInterval(-1800)
            return kind == .calendar || earlier <= .now ? date : earlier
        }
        let formatter = BotPhoneAction.localFormatter()
        return Review(id: Self.actionID(appointment.id, kind), source: appointment, action: BotPhoneAction(
            kind: kind, title: appointment.title, localDate: desired.map { formatter.string(from: $0) },
            location: appointment.location, endDate: appointment.end.map {
                formatter.string(from: Date(timeIntervalSince1970: $0))
            }, needsDate: appointment.date == nil
        ))
    }

    private func connect() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let link = try await api.composioLink("gmail")
                guard link.url.scheme == "https", link.url.user == nil, link.url.password == nil,
                      let host = link.url.host,
                      ["composio.dev", "composio.com"].contains(host) ||
                        host.hasSuffix(".composio.dev") || host.hasSuffix(".composio.com") else {
                    throw APIError.malformed
                }
                openURL(link.url)
                notice = "Når Gmail er forbundet, kan du slå aftalesøgning til."
            } catch { show(error) }
        }
    }

    private func update(_ operation: @escaping () async throws -> MailAppointmentState) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do { state = try await operation() } catch { show(error) }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        do {
            let value = try await api.mailAppointments(bot.id)
            if !Task.isCancelled && !busy { state = value }
        } catch {
            if !Task.isCancelled && !busy && state == nil { show(error) }
        }
    }

    private func show(_ error: Error) {
        if case APIError.http(_, let failure) = error, let message = failure?.message {
            notice = message
        } else {
            notice = "Gmail-aftaler kunne ikke læses. Tjek FadedAI på PC’en."
        }
    }
}

@MainActor struct BotMailView: View {
    let api: LiveAPI?
    let bot: VillageBot
    var onUse: ((String) -> Bool)? = nil

    var body: some View {
        if let api, let onUse {
            GmailReadView(api: api, onUse: onUse)
        } else {
            List {
                if let api {
                    NavigationLink {
                        MailAppointmentsView(api: api, bot: bot)
                    } label: {
                        Label("Find aftaler i Gmail", systemImage: "calendar.badge.envelope")
                    }
                    NavigationLink {
                        GmailReadView(api: api, onUse: nil)
                    } label: {
                        Label("Søg, læs og skriv mail", systemImage: "envelope")
                    }
                } else {
                    Text("Forbind FadedAI med din PC for at bruge Gmail.")
                }
            }
            .navigationTitle("Gmail · \(bot.name)")
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
        }
    }
}
