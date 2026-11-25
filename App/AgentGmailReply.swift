import Foundation
import LocalAuthentication
import SwiftUI

@MainActor struct AgentGmailReply: View {
    struct StoredDraft: Codable, Equatable {
        let pcID, messageID, threadID, recipient, body: String
    }

    private struct Target: Decodable {
        let threadID, recipient, subject: String
    }

    private struct Reply: Encodable {
        let id: UUID
        let messageID, threadID, recipient, body: String
    }

    private struct Receipt: Decodable {
        let sent: Bool
        let threadID: String?
    }

    struct Intent {
        let query, draft: String
        var booking = false

        static func parse(_ prompt: String, botID: UUID? = nil) -> Self? {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = #"(?i)^(?:(?:kan|vil)\s+du\s+)?svar(?:e)?\s+(?:på\s+(?:mail(?:en)?|e-mail(?:en)?)\s+fra\s+|til\s+)?([^,\n]{1,100}?)(?:\s*,\s*|\s+)(?:at\s+)([\s\S]+)$"#
            if let (contact, body) = capture(reply, in: text) {
                let lower = contact.lowercased()
                guard !body.isEmpty, contact.split(whereSeparator: \.isWhitespace).count <= 7,
                      !["på ", "kort ", "kun ", "med "].contains(where: { lower.hasPrefix($0) }) else { return nil }
                return replyDraft(contact, body)
            }
            let findAndReply = #"(?i)^find\s+(?:lige\s+)?(?:den\s+)?(?:mail|mailen|e-mailen)\s+fra\s+([^,\n]{1,100}?)\s+og\s+(?:sig|skriv|svar)\s*,?\s+at\s+([\s\S]+)$"#
            if let (contact, body) = capture(findAndReply, in: text) {
                guard !body.isEmpty else { return nil }
                return replyDraft(contact, body)
            }
            let booking = #"(?i)^(?:få|book|bestil|find)\s+(?:mig\s+)?(?:en\s+)?tid\s+(?:på|hos)\s+(?:et\s+|mit\s+)?(værksted(?:et)?)(?:\s+([^\n]+))?[.!?]?$"#
            if let (contact, date) = capture(booking, in: text) {
                let when = date.trimmingCharacters(in: .punctuationCharacters)
                let suffix = when.isEmpty ? "" : " \(when)"
                let specifiedTime = #"(?i)\b(?:kl|klokken|formiddag|middag|eftermiddag|aften)\b|\b\d{1,2}:\d{2}\b|\b(?:før|efter|omkring|ved)\s+\d{1,2}\b"#
                let preference = when.range(of: specifiedTime, options: .regularExpression) == nil
                    ? AgentChatPreferences.preferredStartHour(for: botID).map { " Helst efter kl. \($0)." } ?? "" : ""
                return .init(query: query(contact),
                             draft: "Hej,\n\nJeg vil gerne bestille en tid til min bil\(suffix).\(preference) Har I en ledig tid?\n\nVenlig hilsen",
                             booking: true)
            }
            return nil
        }

        private static func replyDraft(_ contact: String, _ body: String) -> Self {
            let sentence = String(body.prefix(1)).uppercased() + String(body.dropFirst())
            let punctuation = sentence.last?.isPunctuation == true ? "" : "."
            return .init(query: query(contact), draft: "Hej,\n\n\(sentence)\(punctuation)\n\nVenlig hilsen")
        }

        private static func capture(_ pattern: String, in text: String) -> (String, String)? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let first = Range(match.range(at: 1), in: text) else { return nil }
            let second = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            return (String(text[first]).trimmingCharacters(in: .whitespacesAndNewlines),
                    second.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func query(_ contact: String) -> String {
            let words = contact.lowercased().filter { $0.isLetter || $0.isNumber || "@. -_".contains($0) }
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let names = ["tandlægen": "{tandlæge tandlægen tandklinik}", "værkstedet": "{værksted værkstedet autoværksted}",
                         "værksted": "{værksted autoværksted}", "lægen": "{læge lægen lægehus}",
                         "ham med bilen": "{værksted autoværksted bil service}", "hende med bilen": "{værksted autoværksted bil service}"]
            return names[words] ?? words
        }
    }

    let api: LiveAPI
    let requestID: UUID
    let onSent: (String) -> Void
    let storedDraft: StoredDraft?
    let onDraftChanged: (StoredDraft?) -> Void
    private let suggestedDraft: String
    private enum ReadRecovery { case connect, pc }
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var query: String
    @State private var draft: String
    @State private var messages: [BotMailMessages.Message] = []
    @State private var selectedID: String?
    @State private var target: Target?
    @State private var notice: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var sending = false
    @State private var needsReceiptCheck = false
    @State private var delivered: URL?
    @State private var confirmation = false
    @State private var recovery: ReadRecovery?
    @State private var waitingForPC = false
    @State private var openingLogin = false
    @State private var reconnecting = false
    @FocusState private var editing: Bool

    init(api: LiveAPI, prompt: String, requestID: UUID, botID: UUID? = nil, storedDraft: StoredDraft? = nil,
         onDraftChanged: @escaping (StoredDraft?) -> Void = { _ in }, onSent: @escaping (String) -> Void) {
        self.api = api
        self.requestID = requestID
        self.onSent = onSent
        self.storedDraft = storedDraft
        self.onDraftChanged = onDraftChanged
        let intent = Intent.parse(prompt, botID: botID)
        suggestedDraft = intent?.draft ?? ""
        _query = State(initialValue: intent?.query ?? "")
        _draft = State(initialValue: intent?.draft ?? "")
    }

    static func matches(_ prompt: String) -> Bool { Intent.parse(prompt) != nil }
    static func isBooking(_ prompt: String) -> Bool { Intent.parse(prompt)?.booking == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let delivered {
                Label("Svar sendt i Gmail", systemImage: "checkmark.circle.fill")
                Link("Åbn Gmail-tråden", destination: delivered).frame(minHeight: 44)
            } else {
                if let target { draftFields(target) }
                else { searchFields }
                if loading { ProgressView(selectedID == nil ? "Søger i Gmail…" : "Åbner mailen…") }
                if sending { ProgressView("Sender via Gmail…") }
                if let notice { Text(notice).foregroundStyle(.secondary) }
                recoveryControls
            }
        }
        .privacySensitive()
        .task {
            guard !loaded else { return }
            if let receipt: Receipt = try? await api.moduleJSON(
                "composio/gmail/reply/receipts/\(requestID.uuidString)", timeout: 12
            ), accept(receipt) { return }
            guard !Task.isCancelled else { return }
            if let storedDraft { await restore(storedDraft) }
            else { await search() }
        }
        .task(id: draft) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            saveDraft()
        }
        .onChange(of: storedDraft) { _, value in
            guard let value, value.pcID == api.queueTargetID,
                  selectedID == nil || selectedID == value.messageID else { return }
            draft = value.body
        }
        .onChange(of: editing) { _, value in
            if !value { saveDraft() }
        }
        .task(id: waitingForPC && phase == .active) {
            guard waitingForPC, phase == .active else { return }
            await waitForPC()
        }
        .onChange(of: phase) { _, value in
            if reconnecting, value == .active {
                reconnecting = false
                Task { await retryRead() }
            }
        }
        .onDisappear { saveDraft() }
        .confirmationDialog("Send svaret via Gmail?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Bekræft og send") { Task { await send() } }
            Button("Behold kladden", role: .cancel) {}
        } message: {
            if let target { Text("Til \(target.recipient)\n\(target.subject)") }
        }
    }

    @ViewBuilder private var recoveryControls: some View {
        if waitingForPC {
            ProgressView("Venter på din PC…")
            Button("Stop ventetid") { waitingForPC = false }.frame(minHeight: 44)
        } else if recovery != nil || reconnecting {
            HStack {
                if recovery == .connect {
                    Button("Forbind Gmail", systemImage: "envelope") { Task { await connect() } }
                        .disabled(openingLogin)
                } else if recovery == .pc {
                    Button("Fortsæt, når PC’en er klar", systemImage: "desktopcomputer") { waitingForPC = true }
                }
                Button("Prøv igen") { Task { await retryRead() } }.disabled(loading || openingLogin)
            }
            .frame(minHeight: 44)
        }
    }

    private func connect() async {
        guard !openingLogin else { return }
        openingLogin = true
        defer { openingLogin = false }
        do {
            let link = try await api.composioLink("gmail")
            let validDomains = ["composio.dev", "composio.com"]
            guard link.url.scheme == "https", link.url.user == nil, link.url.password == nil,
                  let host = link.url.host?.lowercased(),
                  validDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw APIError.malformed }
            reconnecting = true
            openURL(link.url)
            notice = "Godkend Gmail i browseren. Vend tilbage hertil for at fortsætte."
        } catch {
            showReadFailure(error, fallback: "Gmail-login kunne ikke åbnes. Prøv igen.")
        }
    }

    private func waitForPC() async {
        while waitingForPC, !Task.isCancelled {
            if (try? await api.health()) != nil {
                // Keep this task alive through the retry. Resetting its ID here would cancel the request.
                await retryRead()
                if !Task.isCancelled { waitingForPC = false }
                return
            }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
        }
    }

    private func retryRead() async {
        guard !loading, !sending, delivered == nil else { return }
        if let receipt: Receipt = try? await api.moduleJSON(
            "composio/gmail/reply/receipts/\(requestID.uuidString)", timeout: 12
        ), accept(receipt) { return }
        guard !Task.isCancelled else { return }
        if let storedDraft { await restore(storedDraft) }
        else { await search() }
    }

    private var searchFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Navn, mailadresse eller emne", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button("Søg", systemImage: "magnifyingglass") { Task { await search() } }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(loading)
            }
            if messages.count > 1 { Text("Vælg den mail, du vil svare på.").font(.subheadline) }
            if !draft.isEmpty {
                DisclosureGroup("Se og ret det foreslåede svar") {
                    TextField("Dit svar", text: $draft, axis: .vertical)
                        .lineLimit(3...9)
                        .textFieldStyle(.roundedBorder)
                        .focused($editing)
                }
            }
            ForEach(messages) { item in
                Button { Task { await select(item) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.subject.isEmpty ? "Uden emne" : item.subject).font(.headline)
                        Text(item.sender).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        }
    }

    private func draftFields(_ target: Target) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(target.subject).font(.headline)
            Text("Til \(target.recipient)").foregroundStyle(.secondary)
            TextField("Dit svar", text: $draft, axis: .vertical)
                .lineLimit(3...9)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .disabled(sending)
            HStack {
                Button("Vælg anden mail") {
                    self.target = nil
                    selectedID = nil
                    needsReceiptCheck = false
                    draft = suggestedDraft
                    onDraftChanged(nil)
                    notice = nil
                }
                .disabled(sending || loading)
                Spacer()
                Button("Send via Gmail", systemImage: "paperplane") {
                    editing = false
                    confirmation = true
                }
                .disabled(sending || loading || !validDraft)
            }
            .frame(minHeight: 44)
            if needsReceiptCheck {
                Button("Tjek om svaret blev sendt", systemImage: "envelope.badge") {
                    Task { await checkSent(thread: target.threadID) }
                }.disabled(loading || sending).frame(minHeight: 44)
            }
        }
    }

    private var validDraft: Bool {
        (1...8_000).contains(draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
    }

    private func search() async {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loading, !terms.isEmpty else { return }
        loading = true
        loaded = true
        selectedID = nil
        messages = []
        notice = nil
        recovery = nil
        defer { loading = false }
        do {
            let response: BotMailMessages = try await api.moduleJSON("composio/gmail/messages", timeout: 75, query: [
                .init(name: "q", value: "in:inbox \(terms.prefix(130))")
            ])
            try Task.checkCancellation()
            var seen = Set<String>()
            messages = Array(response.messages.filter { seen.insert($0.threadID ?? $0.id).inserted }.prefix(8))
            if messages.count == 1, let first = messages.first { await loadTarget(first.id) }
            else if messages.isEmpty { notice = "Ingen mails fundet. Prøv et navn, en mailadresse eller et emne." }
        } catch {
            guard !Task.isCancelled else { return }
            showReadFailure(error, fallback: "Kunne ikke søge i Gmail. Tjek forbindelsen til PC’en.")
        }
    }

    private func select(_ item: BotMailMessages.Message) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await loadTarget(item.id)
    }

    private func restore(_ saved: StoredDraft) async {
        loaded = true
        guard saved.pcID == api.queueTargetID else {
            notice = "Kladden hører til en anden PC-forbindelse. Søg igen for at vælge en modtager her."
            return
        }
        loading = true
        defer { loading = false }
        await loadTarget(saved.messageID, restoring: saved)
    }

    private func loadTarget(_ id: String, restoring saved: StoredDraft? = nil) async {
        selectedID = id
        notice = nil
        recovery = nil
        do {
            let value: Target = try await api.moduleJSON("composio/gmail/reply/\(Server.segment(id))", timeout: 75)
            try Task.checkCancellation()
            if let saved {
                guard saved.recipient == value.recipient, saved.threadID == value.threadID else {
                    selectedID = nil
                    notice = "Gmail-tråden eller modtageren er ændret. Vælg en mail igen."
                    return
                }
                draft = saved.body
            }
            target = value
            saveDraft()
        } catch {
            guard !Task.isCancelled else { return }
            selectedID = nil
            showReadFailure(error, fallback: "Kunne ikke læse modtageren. Vælg en mail igen.")
        }
    }

    private func showReadFailure(_ error: Error, fallback: String) {
        let failure = error as? APIError
        if PCChatOutbox.confirmedOffline(failure) {
            recovery = .pc
            notice = "PC’en kan ikke nås lige nu. Opgaven er stadig i chatten."
        } else if case .http(409, let problem) = failure, problem?.code == "NOT_READY" {
            recovery = .connect
            notice = "Forbind Gmail for at fortsætte med den samme opgave."
        } else {
            notice = errorText(error, fallback: fallback)
        }
    }

    private func saveDraft() {
        guard delivered == nil, let target, let selectedID, draft.unicodeScalars.count <= 8_000 else { return }
        let value = StoredDraft(pcID: api.queueTargetID, messageID: selectedID, threadID: target.threadID,
                                recipient: target.recipient, body: draft)
        if value != storedDraft { onDraftChanged(value) }
    }

    private func send() async {
        guard !sending, delivered == nil, validDraft, let target, let selectedID else { return }
        sending = true
        notice = nil
        defer { sending = false }
        let context = LAContext()
        defer { context.invalidate() }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: "Godkend dit svar i Gmail.") else { return }
        } catch {
            notice = "Svaret er stadig en kladde."
            return
        }
        do {
            let reply = Reply(id: requestID, messageID: selectedID, threadID: target.threadID,
                              recipient: target.recipient, body: draft)
            let receipt: Receipt = try await api.moduleJSON("composio/gmail/reply", upload: JSONEncoder().encode(reply), timeout: 150)
            guard receipt.threadID == target.threadID, accept(receipt) else {
                throw APIError.malformed
            }
        } catch {
            needsReceiptCheck = true
            guard !Task.isCancelled else { return }
            await checkSent(thread: target.threadID, failureNotice: errorText(error,
                fallback: "Afsendelsen kunne ikke bekræftes. Tjek Sendt i Gmail før et nyt forsøg."))
        }
    }

    private func checkSent(thread: String, failureNotice: String = "Ingen kvittering endnu. Tjek Sendt i Gmail.") async {
        guard !loading, delivered == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let receipt: Receipt = try await api.moduleJSON("composio/gmail/reply/receipts/" + requestID.uuidString, timeout: 12)
            try Task.checkCancellation()
            guard receipt.threadID == thread, accept(receipt) else { notice = failureNotice; return }
            needsReceiptCheck = false
            notice = nil
        } catch {
            if !Task.isCancelled { notice = failureNotice }
        }
    }

    private func accept(_ receipt: Receipt) -> Bool {
        guard receipt.sent, let thread = receipt.threadID,
              thread.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
              let link = URL(string: "https://mail.google.com/mail/#all/\(thread)") else { return false }
        delivered = link
        loaded = true
        onSent(link.absoluteString)
        return true
    }

    private func errorText(_ error: Error, fallback: String) -> String {
        if case APIError.http(_, let problem) = error, let message = problem?.message { return message }
        return fallback
    }
}

@MainActor struct AgentGmailThreadStatus: View {
    private struct Followup: Decodable {
        let state: String
        let subject: String?
        let sender: String?
        let timestamp: TimeInterval?
    }

    let api: LiveAPI
    let requestID: UUID
    var automaticallyChecks = false
    @State private var loading = false
    @State private var notice: String?
    @State private var followup: Followup?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Tjek om der er kommet svar", systemImage: "envelope.badge") { Task { await refresh() } }
                .frame(minHeight: 44).disabled(loading)
            if loading { ProgressView("Tjekker Gmail-tråden…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if let followup, followup.state == "received" {
                Label(followup.subject ?? "Nyt svar", systemImage: "envelope.fill").font(.subheadline.weight(.semibold))
                if let sender = followup.sender, !sender.isEmpty { Text(sender).font(.caption) }
                if let timestamp = followup.timestamp {
                    Text(Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
            }
        }
        .task { if automaticallyChecks { await refresh() } }
        .privacySensitive()
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        notice = nil
        followup = nil
        defer { loading = false }
        do {
            let status: Followup = try await api.moduleJSON("composio/gmail/reply/followup/\(requestID.uuidString)", timeout: 75)
            followup = status
            switch status.state {
            case "received": notice = "Der er kommet svar i Gmail-tråden."
            case "waiting": notice = "Jeg fandt endnu ikke et svar i Gmail-tråden."
            default: notice = "Jeg kunne ikke afgøre status. Åbn Gmail-tråden for at se svarene."
            }
        } catch {
            if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
            else { notice = "Kunne ikke tjekke Gmail-tråden lige nu." }
        }
    }
}
