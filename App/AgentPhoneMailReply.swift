import SwiftUI

@MainActor struct AgentPhoneMailReply: View {
    let requestID: UUID
    let botID: UUID
    let botName: String
    let onSent: (String) -> Void
    @State private var query: String
    @State private var bodyText: String
    @State private var messages: [AgentInternetPayload.Mail] = []
    @State private var record: AgentPhoneMail.Record?
    @State private var client: AgentPhoneMailClient?
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmation = false

    init(prompt: String, requestID: UUID, botID: UUID, botName: String, onSent: @escaping (String) -> Void) {
        self.requestID = requestID; self.botID = botID; self.botName = botName; self.onSent = onSent
        let intent = AgentGmailReply.Intent.parse(prompt, botID: botID)
        _query = State(initialValue: intent?.query ?? "in:inbox")
        _bodyText = State(initialValue: intent?.draft ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Gmail på iPhone", systemImage: "envelope").font(.headline)
            if let record {
                Text(record.target.subject).font(.headline)
                Text("Til: \(record.target.recipient)").textSelection(.enabled)
                if record.state == .review {
                    TextField("Dit svar", text: $bodyText, axis: .vertical).lineLimit(4...12).textFieldStyle(.roundedBorder)
                    Button("Send svaret", systemImage: "paperplane") { saveDraft(); confirmation = self.record?.body == bodyText }
                        .buttonStyle(.borderedProminent).disabled(busy || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 12_000)
                    Button("Vælg en anden mail") { self.record = nil; Task { await search() } }.disabled(busy)
                } else if record.state == .sent {
                    Label("Gmail har bekræftet afsendelsen", systemImage: "checkmark.circle")
                } else {
                    Text("Svaret kan allerede være sendt. Kontrollér det her — der bliver ikke sendt igen.")
                    Button("Kontrollér afsendelsen", systemImage: "arrow.clockwise") { Task { await check() } }.disabled(busy || record.sentID == nil)
                    Link("Åbn Sendt i Gmail", destination: URL(string: "https://mail.google.com/mail/u/0/#sent")!)
                }
            } else {
                TextField("Afsender eller emne", text: $query).textFieldStyle(.roundedBorder)
                Button("Find mailen", systemImage: "magnifyingglass") { Task { await search() } }.disabled(busy || query.count > 500)
                ForEach(messages, id: \.id) { mail in
                    Button { Task { await select(mail) } } label: {
                        VStack(alignment: .leading) { Text(mail.subject.isEmpty ? "Uden emne" : mail.subject); Text(mail.sender).font(.caption).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.disabled(busy)
                }
            }
            if busy { ProgressView("Kontakter Gmail…") }
            if let notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
        }
        .task {
            do {
                record = try AgentPhoneMail.Store().load(requestID)
                if let record { bodyText = record.body }
                if record == nil { await search() }
                else if record?.state == .sent { finish() }
            } catch { notice = "Den gemte mailopgave kunne ikke læses. Ingen mail er sendt." }
        }
        .onChange(of: bodyText) { _, _ in saveDraft() }
        .confirmationDialog("Send dette svar?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Bekræft og send") { Task { await send() } }
            Button("Behold kladden", role: .cancel) {}
        } message: { Text("Til \(record?.target.recipient ?? "")\n\(bodyText)") }
    }
    private func connected() async throws -> AgentPhoneMailClient {
        if let client { return client }
        let value = try await AgentPhoneMailClient.connect(); client = value; return value
    }
    private func search() async {
        guard !busy else { return }; busy = true; notice = nil
        defer { busy = false }
        do {
            let client = try await connected()
            let output = try await client.call("GMAIL_FETCH_EMAILS", ["user_id": "me", "query": query,
                "max_results": 12, "verbose": false, "include_payload": false, "include_spam_trash": false])
            messages = try AgentInternetPayload.mails(output)
            notice = messages.isEmpty ? "Ingen match. Prøv et navn, en mailadresse eller et andet emne." : "Vælg den mail, du vil svare på. Viser op til 12 match."
        } catch { notice = error.localizedDescription }
    }
    private func select(_ mail: AgentInternetPayload.Mail) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let client = try await connected()
            let target = try AgentPhoneMail.target(try await client.message(mail.id), messageID: mail.id)
            if let old = try AgentPhoneMail.Store().load(requestID), old.state != .review { record = old; throw AgentPhoneMail.Failure.uncertain }
            let draft = AgentPhoneMail.Record(id: requestID, accountID: client.accountID, target: target, body: bodyText)
            try AgentPhoneMail.Store().save(draft); record = draft; notice = nil
        } catch { notice = error.localizedDescription }
    }
    private func saveDraft() {
        guard var draft = record, draft.state == .review, !busy else { return }
        draft.body = bodyText
        do { try AgentPhoneMail.Store().save(draft); record = draft }
        catch { notice = "Kladden kunne ikke gemmes. Prøv igen før afsendelse." }
    }
    private func send() async {
        guard !busy, let record, record.state == .review else { return }
        busy = true; defer { busy = false }
        do { self.record = try await connected().send(record); finish() }
        catch { self.record = (try? AgentPhoneMail.Store().load(requestID)) ?? record; notice = error.localizedDescription }
    }
    private func check() async {
        guard !busy, let record else { return }; busy = true; defer { busy = false }
        do { self.record = try await connected().verify(record); finish() }
        catch { notice = error.localizedDescription }
    }
    private func finish() {
        guard let record, record.state == .sent else { return }
        onSent("https://mail.google.com/mail/u/0/#all/" + record.target.threadID)
    }
}
