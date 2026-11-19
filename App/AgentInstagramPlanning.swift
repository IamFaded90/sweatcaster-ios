import SwiftUI

struct AgentInstagramTiming: Codable, Equatable {
    var publish: Date
    var followUp: Date?
    var notifyEmail = false

    static func requested(in text: String, now: Date = .now, calendar: Calendar = AgentCalendarAvailability.clock) -> Self? {
        let text = text.lowercased()
        guard text.range(of: #"^(?:(?:kan|vil) du (?:lige |godt )?)?(?:post(?:e)?|udgiv(?:e)?|planlæg(?:ge)?|del(?:e)?|læg(?:ge)?)\s"#,
                         options: .regularExpression) != nil else { return nil }
        let instruction = text.components(separatedBy: "med teksten").first ?? text
        let follow = instruction.range(of: #"\b(?:fortæl mig|giv mig (?:en )?(?:status|besked)|følg op|tjek (?:hvordan|resultatet)|send mig (?:en )?(?:rapport|e-?mail|mail)|mail mig)\b"#,
                                       options: .regularExpression)
        let first = String(instruction[..<(follow?.lowerBound ?? instruction.endIndex)])
        let when = date(in: first, after: now, calendar: calendar)
        let scheduled = when != nil || first.contains("planlæg") || first.contains("senere")
        guard scheduled else { return nil }
        let publish = when ?? defaultPublish(now: now)
        let followUp = follow.map { range in
            let tail = String(instruction[range.lowerBound...])
            // "I morgen" refers to the day the user is speaking. A weekday after publication
            // can wrap into the next week ("fredag ... mandag").
            let absolute = date(in: tail, after: now, calendar: calendar)
            if let absolute, absolute > publish { return absolute }
            return date(in: tail, after: publish, calendar: calendar) ?? defaultFollowUp(after: publish, calendar: calendar)
        }
        let email = follow.map {
            instruction[$0.lowerBound...].range(of: #"\b(?:på (?:e-?mail|mail)|send mig (?:en )?(?:e-?mail|mail)|mail mig)\b"#,
                                                options: .regularExpression) != nil
        } ?? false
        return Self(publish: publish, followUp: followUp, notifyEmail: email)
    }

    static func defaultPublish(now: Date = .now) -> Date {
        Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60 + 3600)
    }

    static func defaultFollowUp(after publish: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: 1, to: publish) ?? publish.addingTimeInterval(86400)
    }

    private static func date(in prompt: String, after now: Date, calendar: Calendar) -> Date? {
        let day = AgentPhoneLanguage.day(in: prompt, now: now, calendar: calendar)
        let clock = AgentPhoneLanguage.time(in: prompt, marker: #"\b(?:klokken|kl\.?)"#)
        guard day != nil || clock != nil else { return nil }
        let (hour, minute) = clock ?? (9, 0)
        guard let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day ?? now),
              calendar.isDate(time, inSameDayAs: day ?? now) else { return nil }
        if time > now { return time }
        if day == nil { return calendar.date(byAdding: .day, value: 1, to: time) }
        if prompt.range(of: #"\b(?:man|tirs|ons|tors|fre|lør|søn)dag\b"#, options: .regularExpression) != nil {
            return calendar.date(byAdding: .day, value: 7, to: time)
        }
        return time // The picker marks an explicit past date as invalid.
    }

    var isValid: Bool { publish > Date.now && (followUp.map { $0 > publish } ?? true) }
}

struct AgentInstagramJob: Codable, Equatable, Identifiable {
    let id: UUID
    let state: String
    let publishAt, followUpAt, publishedAt: TimeInterval?
    let username, caption, note: String?
    let report: Report?
    let emailState: String?

    struct Report: Codable, Equatable {
        let state: String
        let checkedAt: TimeInterval?
        let metrics: [String: Int]?
        let note: String?
    }

    static func date(_ seconds: TimeInterval?) -> String {
        seconds.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "ukendt tidspunkt"
    }

    var statusText: String {
        let account = username.map { " på @" + $0 } ?? ""
        switch state {
        case "scheduled": return "Planlagt" + account + " til " + Self.date(publishAt) + "."
        case "publishing": return "PC’en er ved at udgive opslaget" + account + "."
        case "published": return "Udgivet" + account + " · " + Self.date(publishedAt)
        case "cancelled": return "Udgivelsen er annulleret."
        case "failed": return note ?? "Udgivelsen mislykkedes."
        case "unconfirmed": return note ?? "Instagram har endnu ikke bekræftet udgivelsen. Tjek kontoen."
        default: return "Kladde"
        }
    }

    var reportText: String? {
        guard let report else { return nil }
        if report.state == "unavailable" { return report.note ?? "Instagram gav ingen tal for opslaget." }
        guard report.state == "ready" else { return nil }
        let labels = [("reach", "Nåede konti"), ("views", "Visninger"), ("likes", "Likes"),
                      ("comments", "Kommentarer"), ("saved", "Gemt"), ("shares", "Delinger")]
        let counts = labels.compactMap { key, name in report.metrics?[key].map { "\(name): \($0)" } }
        guard !counts.isEmpty else { return "Instagram gav ingen tal for opslaget." }
        return (["Opfølgning · " + Self.date(report.checkedAt)] + counts).joined(separator: "\n")
    }

    var summary: String {
        var lines = [statusText]
        if let reportText { lines.append(reportText) }
        else if let followUpAt, ["scheduled", "publishing", "published"].contains(state) {
            lines.append("Opfølgning " + Self.date(followUpAt) + ".")
        }
        switch emailState {
        case "sent": lines.append("Rapporten er sendt til din mail.")
        case "failed": lines.append("Rapporten kunne ikke sendes til din mail.")
        case "unconfirmed": lines.append("Gmail har ikke bekræftet afsendelsen af rapporten.")
        default: break
        }
        return lines.joined(separator: "\n")
    }

    var completed: Bool {
        if ["cancelled", "failed"].contains(state) { return true }
        return state == "published" && (followUpAt == nil || (reportText != nil && emailState != "pending"))
    }
}

struct AgentInstagramJobList: Decodable { let items: [AgentInstagramJob] }

struct InstagramTimingFields: View {
    @Binding var timing: AgentInstagramTiming?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Udgiv senere", isOn: Binding(get: { timing != nil }, set: { enabled in
                timing = enabled ? .init(publish: AgentInstagramTiming.defaultPublish()) : nil
            }))
            if let current = timing {
                DatePicker("Udgivelse", selection: Binding(get: { timing?.publish ?? current.publish },
                    set: { timing?.publish = $0 }))
                Toggle("Følg op på opslaget", isOn: Binding(get: { timing?.followUp != nil }, set: { enabled in
                    timing?.followUp = enabled ? AgentInstagramTiming.defaultFollowUp(after: current.publish) : nil
                    if !enabled { timing?.notifyEmail = false }
                }))
                if let date = current.followUp {
                    DatePicker("Hent tal fra Instagram", selection: Binding(get: { timing?.followUp ?? date },
                        set: { timing?.followUp = $0 }))
                    Toggle("Send også rapporten til min mail", isOn: Binding(get: { timing?.notifyEmail == true },
                        set: { timing?.notifyEmail = $0 }))
                }
                if !current.isValid { FadedDetailText("Vælg en fremtidig udgivelse og en opfølgning efter opslaget.") }
                FadedDetailText("PC’en udfører planen. Hvis den er slukket, fortsætter opgaven, når FadedAI kører igen.")
            }
        }
    }
}

struct AgentInstagramPlanner: View {
    let api: LiveAPI?
    let bot: VillageBot
    @State private var jobs: [AgentInstagramJob]?
    @State private var notice: String?
    @State private var cancelling: AgentInstagramJob?
    @State private var busy = false
    @State private var refresh = 0
    @Environment(\.scenePhase) private var phase
    private var query: [URLQueryItem] { [.init(name: "bot_id", value: bot.id.uuidString)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if api == nil { FadedDetailText("Forbind PC’en for at se planlagte opslag og opfølgninger.") }
            if let jobs {
                if jobs.isEmpty { Text("Ingen planlagte Instagram-opslag endnu.") }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        if let caption = job.caption, !caption.isEmpty { Text(caption).lineLimit(2).font(.headline) }
                        Text(job.summary).textSelection(.enabled)
                        if job.state == "scheduled" {
                            Button("Annuller udgivelse", role: .destructive) { cancelling = job }
                        }
                    }
                    Divider()
                }
            }
            if busy { ProgressView() }
            if let notice { FadedDetailText(notice) }
            if api != nil { Button("Opdatér opslag og tal") { refresh += 1 }.disabled(busy) }
        }
        .privacySensitive()
        .task(id: "\(api?.queueTargetID ?? "")/\(phase == .active)/\(refresh)") {
            guard phase == .active, let api else { return }
            busy = true
            defer { if !Task.isCancelled { busy = false } }
            do {
                let list: AgentInstagramJobList = try await api.moduleJSON("composio/instagram/schedule", query: query)
                try Task.checkCancellation()
                jobs = list.items
                notice = nil
            } catch { if !Task.isCancelled { notice = AppErrorPresentation(error).title } }
        }
        .confirmationDialog("Annuller det planlagte opslag?", isPresented: Binding(
            get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }
        ), presenting: cancelling) { job in
            Button("Annuller udgivelse", role: .destructive) { cancel(job) }
            Button("Behold opslaget", role: .cancel) {}
        }
    }

    private func cancel(_ job: AgentInstagramJob) {
        guard let api, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let updated: AgentInstagramJob = try await api.moduleJSON("composio/instagram/schedule/\(job.id.uuidString)/cancel",
                                                                          upload: Data("{}".utf8), query: query)
                if let index = jobs?.firstIndex(where: { $0.id == job.id }) { jobs?[index] = updated }
                notice = nil
            } catch { notice = AppErrorPresentation(error).title }
        }
    }
}
