import SwiftUI

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
                Text(date.formatted(date: .abbreviated, time: .shortened))
            } else if appointment.canApply {
                Text("Hvornår er aftalen? Mailen mangler et sikkert tidspunkt.")
                    .foregroundStyle(.secondary)
            }
            if !appointment.location.isEmpty { Text(appointment.location).foregroundStyle(.secondary) }
            if let thread = appointment.gmailThread,
               thread.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
               let link = URL(string: "https://mail.google.com/mail/u/0/#all/\(thread)") {
                Link("Se kildemailen i Gmail", destination: link).frame(minHeight: 44)
            }
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
