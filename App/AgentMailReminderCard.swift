import Foundation
import SwiftUI

/// FadedAI's native version of the Google Workspace Email to Task workflow.
enum AgentMailReminderIntent {
    struct Search {
        let value: String
        let isParcel: Bool
    }

    static func search(for prompt: String) -> Search? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = #"^(?:(?:kan du|vil du|gider du)\s+)?(?:lige\s+)?(?:mind(?:e)? mig\b|(?:opret(?:te)?|lav(?:e)?|sæt(?:te)?)\s+(?:lige\s+)?(?:en\s+)?påmindelse\b|gør(?:e)?\b.+\btil en påmindelse\b)"#
        guard text.range(of: command, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let parcel = #"\b(?:hente|afhente)\s+(?:(?:den|min|en)\s+)?pakke(?:n)?\b"#
        if text.range(of: parcel, options: [.regularExpression, .caseInsensitive]) != nil {
            return Search(value: #"{"klar til afhentning" "pakken kan hentes" "sidste afhentningsdag" pakkeshop}"#,
                          isParcel: true)
        }
        let reference = #"\b(?:e-mail(?:en)?|mail(?:en)?|gmail|beskeden fra gmail)\b"#
        guard let range = text.range(of: reference, options: [.regularExpression, .caseInsensitive]) else { return nil }
        var terms = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        terms = terms.replacingOccurrences(of: #"(?i)^(?:fra|om|vedrørende|med emnet)\s+"#, with: "", options: .regularExpression)
        terms = terms.replacingOccurrences(of: #"(?i)\s+(?:til|på) en påmindelse\b.*$"#, with: "", options: .regularExpression)
        terms = terms.replacingOccurrences(of: #"(?i)\s+(?:i (?:dag|morgen|overmorgen)\b|kl(?:okken|\.)?\s*\d|om\s+\d+\s+(?:minutter?|timer?|dage?)\b).*$"#,
                                           with: "", options: .regularExpression)
        terms = terms.filter { $0.isLetter || $0.isNumber || "@. -_".contains($0) }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
        let related = ["tandlægen": "{tandlæge tandlægen tandklinik}", "lægen": "{læge lægen lægehus}",
                       "værkstedet": "{værksted værkstedet autoværksted}"]
        return Search(value: String((related[terms.lowercased()] ?? terms).prefix(100)), isParcel: false)
    }

    static func evidence(from body: String) -> [String] {
        let deadline = #"\b(?:afhentningsfrist|sidste afhentningsdag|sidste frist|afhent(?:es)? senest|hent(?:es)? senest|betal(?:es)? senest|forfaldsdato)\b"#
        let place = #"\b(?:afhentningssted|udleveringssted|pakkeshop|pakkeautomat|afhentes (?:hos|på|ved))\b"#
        let lines = body.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let matches = [deadline, place].compactMap { pattern in
            lines.first { !$0.hasPrefix(">") && $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
                .map { String($0.prefix(220)) }
        }
        return matches.count == 2 && matches[0] == matches[1] ? [matches[0]] : matches
    }
}

@MainActor struct AgentMailReminderCard: View {
    private struct Lookup: Hashable {
        enum Operation: Hashable { case search(String), read(String) }
        let operation: Operation
        let attempt = UUID()
    }

    private struct Request: Hashable {
        let target: String?
        let lookup: Lookup
    }

    private struct Mail {
        let message: BotMailMessages.Message
        let text: String

        var title: String { message.subject.isEmpty ? "Mail uden emne" : message.subject }
        var source: URL? {
            guard let threadID = message.threadID,
                  threadID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://mail.google.com/mail/#all/\(threadID)")
        }

        var notes: String {
            let lines = AgentMailReminderIntent.evidence(from: text)
            let detail = lines.isEmpty ? String(text.prefix(420)) : lines.joined(separator: "\n")
            return (["Fra Gmail · \(String(title.prefix(120)))", detail] + [source?.absoluteString].compactMap { $0 })
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    private struct Review: Identifiable {
        let id: UUID
        let action: BotPhoneAction
        let notes: String
    }

    let api: LiveAPI?
    let prompt: String
    let requestID: UUID
    let botName: String
    let onApplied: (String) -> Void
    private let isParcel: Bool
    @State private var query: String
    @State private var lookup: Lookup
    @State private var messages: [BotMailMessages.Message] = []
    @State private var messagesTarget: String?
    @State private var mail: Mail?
    @State private var loading = false
    @State private var notice: String?
    @State private var review: Review?

    init(api: LiveAPI?, prompt: String, requestID: UUID, botName: String, onApplied: @escaping (String) -> Void) {
        self.api = api
        self.prompt = prompt
        self.requestID = requestID
        self.botName = botName
        self.onApplied = onApplied
        let search = AgentMailReminderIntent.search(for: prompt)
        let query = search?.value ?? ""
        isParcel = search?.isParcel == true
        _query = State(initialValue: query)
        _lookup = State(initialValue: Lookup(operation: .search(query)))
    }

    static func matches(_ prompt: String) -> Bool { AgentMailReminderIntent.search(for: prompt) != nil }

    var body: some View {
        let request = Request(target: api?.queueTargetID, lookup: lookup)
        VStack(alignment: .leading, spacing: 8) {
            if api == nil {
                FadedDetailText("Forbind FadedAI med PC’en for at finde mailen i Gmail.")
            } else if let mail, messagesTarget == request.target {
                verifiedMail(mail)
            } else {
                searchControls
            }
            if loading { ProgressView("Henter fra Gmail…") }
            if let notice { FadedDetailText(notice) }
        }
        .privacySensitive()
        .task(id: request) { await load(request) }
        .sheet(item: $review) { selection in
            BotPhoneActionReview(action: selection.action, jobID: selection.id, botName: botName,
                                 reminderNotes: selection.notes, onSaved: onApplied) {}
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Søg i Gmail", text: $query).textInputAutocapitalization(.never)
                    .submitLabel(.search).onSubmit(search)
                Button("Søg", systemImage: "magnifyingglass", action: search)
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            .disabled(loading)
            let currentMessages = messagesTarget == api?.queueTargetID ? messages : []
            if !currentMessages.isEmpty { FadedDetailText("Vælg mailen til påmindelsen.") }
            ForEach(currentMessages) { message in
                Button {
                    lookup = Lookup(operation: .read(message.id))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: message.subject.isEmpty ? "Uden emne" : message.subject).font(.headline)
                        Text(verbatim: message.sender).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        }
    }

    private func verifiedMail(_ mail: Mail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: mail.title).font(.headline)
            Text(verbatim: mail.message.sender).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(AgentMailReminderIntent.evidence(from: mail.text).enumerated()), id: \.offset) { entry in
                Text(verbatim: entry.element).font(.subheadline).textSelection(.enabled)
            }
            if !mail.text.isEmpty {
                DisclosureGroup("Læs uddraget fra mailen") {
                    Text(verbatim: String(mail.text.prefix(4_000))).textSelection(.enabled)
                }
            }
            if let source = mail.source { Link("Åbn kildemailen i Gmail", destination: source).frame(minHeight: 44) }
            Button("Gennemgå påmindelsen", systemImage: "checklist") {
                let timing = AgentPhoneLanguage.action(.reminder, prompt: prompt, now: .now)
                let title = isParcel ? "Hent pakken · \(mail.title)" : mail.title
                review = Review(id: requestID, action: BotPhoneAction(kind: .reminder, title: String(title.prefix(120)),
                                localDate: timing.localDate, needsDate: timing.needsDate), notes: mail.notes)
            }
            .frame(minHeight: 44)
            Button("Vælg en anden mail", systemImage: "arrow.uturn.backward") {
                self.mail = nil
            }
            .frame(minHeight: 44)
        }
    }

    private func search() {
        guard !loading else { return }
        lookup = Lookup(operation: .search(query))
    }

    private func load(_ request: Request) async {
        guard let api, let expected = request.target, expected == api.queueTargetID else {
            messages = []
            messagesTarget = nil
            mail = nil
            notice = nil
            loading = false
            return
        }
        loading = true
        mail = nil
        notice = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            switch request.lookup.operation {
            case .search(let query):
                messages = []
                let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let date = isParcel ? "newer_than:30d" : "newer_than:180d"
                let filter = "in:inbox \(date) \(String(terms.prefix(125)))"
                let result: BotMailMessages = try await api.moduleJSON("composio/gmail/messages", timeout: 75,
                    query: [.init(name: "q", value: filter)])
                try Task.checkCancellation()
                messages = Array(result.messages.prefix(8))
                messagesTarget = expected
                if messages.isEmpty { notice = "Jeg fandt ingen mails. Prøv afsenderens navn eller et ord fra emnet." }
            case .read(let id):
                guard messagesTarget == expected else {
                    lookup = Lookup(operation: .search(query))
                    return
                }
                guard let message = messages.first(where: { $0.id == id }) else { return }
                let content: BotMailContent = try await api.moduleJSON("composio/gmail/message/\(Server.segment(id))", timeout: 75)
                try Task.checkCancellation()
                mail = Mail(message: message, text: content.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            guard !Task.isCancelled else { return }
            if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
            else { notice = "Jeg kunne ikke hente mailen. Tjek forbindelsen til PC’en og prøv igen." }
        }
    }
}
