import SwiftUI

@MainActor struct AgentGmailCleanup: View {
    let api: LiveAPI?
    let bot: VillageBot
    let prompt: String
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    @State private var customQuery = ""
    @State private var mode = "archive"
    @State private var job: AgentGmailCleanupJob?
    @State private var history: [AgentGmailCleanupJob] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var notice: String?
    @State private var approvalOpen = false
    @State private var undoOpen = false
    @State private var previewID = UUID()
    @State private var lastReportedReceipt = ""

    init(api: LiveAPI?, bot: VillageBot, prompt: String = "", onResult: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.bot = bot
        self.prompt = prompt
        self.onResult = onResult
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    requestCard
                    if let job {
                        summary(job)
                        if job.messages.isEmpty {
                            FadedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Her er allerede ryddeligt", systemImage: "checkmark.circle")
                                        .font(.headline)
                                    Text("Ingen mails matchede denne søgning. Prøv en anden alder eller søgning.")
                                }
                            }
                        }
                        ForEach(job.messages) { mail in message(mail, in: job) }
                        if job.hasMore {
                            Text("Gmail har flere resultater. Her vises højst 12 ad gangen, så du kan overskue dem.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        actions(job)
                    }
                    if !history.isEmpty { historyCard }
                    if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("gmailCleanupNotice") }
                    if busy { ProgressView("Kontrollerer Gmail… Du kan følge resultatet her.") }
                    if api == nil {
                        Text("Forbind din PC, så \(bot.name) kan bruge din Gmail gennem Composio.")
                    }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .standard) }
            .navigationTitle("Ryd op i Gmail").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kontrollér status", systemImage: "arrow.clockwise") { refresh() }
                        .labelStyle(.iconOnly).disabled(busy || api == nil)
                }
            }
            .confirmationDialog(approvalTitle, isPresented: $approvalOpen, titleVisibility: .visible) {
                Button(approvalTitle, role: job?.mode == "trash" ? .destructive : nil) { change("apply") }
                Button("Behold dem", role: .cancel) { }
            } message: {
                Text(job?.mode == "trash" ?
                     "De valgte mails flyttes til papirkurven. Gmail sletter normalt papirkurven automatisk efter 30 dage. Du kan fortryde her, så længe mailene stadig findes." :
                     "De valgte mails forlader indbakken og ligger stadig i Alle mails. Du kan hente dem tilbage med Fortryd.")
            }
            .confirmationDialog("Hent mails tilbage i indbakken?", isPresented: $undoOpen, titleVisibility: .visible) {
                Button("Gendan i indbakken") { change("undo") }
                Button("Annuller", role: .cancel) { }
            }
            .task {
                brief = prompt.isEmpty ? "Ryd op i gamle reklamer og nyhedsbreve" : prompt
                await loadHistory()
            }
            .onChange(of: brief) { _, _ in previewID = UUID() }
            .onChange(of: customQuery) { _, _ in previewID = UUID() }
            .onChange(of: mode) { _, _ in previewID = UUID() }
            .interactiveDismissDisabled(busy)
        }
    }

    private var requestCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Lad \(bot.name) rydde op", systemImage: "tray.and.arrow.down")
                    .font(.title3.bold())
                Text("Se først, hvad der bliver ryddet op. Ulæste, personlige og vigtige mails bevares.")
                    .foregroundStyle(.secondary)
                TextField("Fx nyhedsbreve ældre end 3 måneder", text: $brief, axis: .vertical)
                    .lineLimit(2...4).disabled(busy)
                Picker("Handling", selection: $mode) {
                    Text("Arkivér").tag("archive")
                    Text("Papirkurv").tag("trash")
                }.pickerStyle(.segmented).disabled(busy)
                if mode == "trash" {
                    Text("Papirkurven tømmes normalt af Gmail efter 30 dage. Arkivering gemmer mailene.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                DisclosureGroup("Tilpas Gmail-søgningen") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Fx category:promotions older_than:3m", text: $customQuery, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...4)
                        Text("Tomt felt bruger din beskrivelse til at finde ældre reklamer. Agenten viser kun mails fra indbakken.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.disabled(busy)
                FadedPrimaryButton("Vis mails før oprydning", icon: "list.bullet.rectangle") { preview() }
                    .disabled(api == nil || busy || brief.count > 1200 || customQuery.count > 240)
            }
        }
    }

    private func summary(_ job: AgentGmailCleanupJob) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(job.title).font(.headline)
                Text(job.receipt)
                Text("\(job.messages.count) fundet · \(job.counts["protected", default: 0]) beskyttet")
                    .font(.subheadline).foregroundStyle(.secondary)
                DisclosureGroup("Vis den præcise søgning") {
                    Text(job.query).font(.footnote).textSelection(.enabled).padding(.top, 6)
                }
                if job.state == "preview" {
                    Button(selected.isEmpty ? "Vælg alle, der må ryddes op" : "Fravælg alle") {
                        selected = selected.isEmpty ? Set(job.messages.filter { $0.state == "ready" }.map(\.id)) : []
                    }.frame(minHeight: 44).disabled(busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func message(_ mail: AgentGmailCleanupJob.Message, in job: AgentGmailCleanupJob) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    if job.state == "preview" && !mail.protected {
                        Button {
                            if selected.contains(mail.id) { selected.remove(mail.id) } else { selected.insert(mail.id) }
                        } label: {
                            Image(systemName: selected.contains(mail.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).frame(width: 44, height: 44)
                        }.disabled(busy).accessibilityLabel("Vælg mail: " + mail.subject)
                            .accessibilityValue(selected.contains(mail.id) ? "Valgt" : "Ikke valgt")
                    } else {
                        Image(systemName: mail.protected ? "lock.shield" : "envelope")
                            .frame(width: 28, height: 30).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mail.subject).font(.headline)
                        Text(mail.sender).font(.subheadline).foregroundStyle(.secondary)
                        Text(mail.stateTitle).font(.caption.bold())
                    }
                }
                if !mail.reasons.isEmpty {
                    Text(mail.reasons.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                }
                if !mail.note.isEmpty { Text(mail.note).font(.footnote).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func actions(_ job: AgentGmailCleanupJob) -> some View {
        if job.state == "preview" {
            FadedPrimaryButton(approvalTitle, icon: job.mode == "trash" ? "trash" : "archivebox") { approvalOpen = true }
                .disabled(busy || selected.isEmpty)
        } else {
            if job.needsAttention {
                FadedSecondaryButton("Kontrollér status hos Gmail", icon: "arrow.clockwise") { change("verify") }
                    .disabled(busy)
                FadedPrimaryButton(job.undoRequested == true ? "Fortsæt gendannelse" : "Prøv resten igen", icon: "arrow.triangle.2.circlepath") {
                    change(job.undoRequested == true ? "undo" : "apply")
                }.disabled(busy)
            }
            if job.canUndo && job.undoRequested != true {
                FadedSecondaryButton("Fortryd · tilbage i indbakken", icon: "arrow.uturn.backward") { undoOpen = true }
                    .disabled(busy)
            }
        }
    }

    private var historyCard: some View {
        FadedCard {
            DisclosureGroup("Tidligere oprydninger") {
                ForEach(history) { previous in
                    Button {
                        job = previous
                        selected = Set(previous.selected)
                        refresh()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(previous.createdDate, style: .date).font(.subheadline.bold())
                            Text(previous.receipt).font(.footnote).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }.disabled(busy)
                }
            }
        }
    }

    private var approvalTitle: String {
        (job?.mode == "trash" ? "Flyt \(selected.count) mails til papirkurven" : "Arkivér \(selected.count) mails")
    }

    private var query: [URLQueryItem] { [.init(name: "bot_id", value: bot.id.uuidString)] }

    private func loadHistory() async {
        guard let api else { return }
        do {
            struct History: Decodable { let items: [AgentGmailCleanupJob] }
            let value: History = try await api.moduleJSON("gmail-cleanup", query: query)
            history = value.items
        } catch { notice = (error as? APIError)?.title ?? "Gmail-oprydning kunne ikke hentes fra PC’en." }
    }

    private func preview() {
        guard let api, !busy else { return }
        busy = true
        notice = nil
        let body: [String: Any] = ["id": previewID.uuidString, "prompt": brief,
                                   "query": customQuery, "mode": mode, "limit": 12]
        Task { @MainActor in
            defer { busy = false }
            do {
                let value: AgentGmailCleanupJob = try await api.moduleJSON("gmail-cleanup/preview",
                    upload: JSONSerialization.data(withJSONObject: body), timeout: 190, query: query)
                job = value
                previewID = UUID()
                selected = Set(value.selected.isEmpty ? value.messages.filter { $0.state == "ready" }.map(\.id) : value.selected)
                await loadHistory()
            } catch { notice = (error as? APIError)?.title ?? "Forhåndsvisningen kunne ikke laves. Ingen mails er godkendt til ændring." }
        }
    }

    private func refresh() {
        guard let api, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            if let current = job {
                do {
                    let value: AgentGmailCleanupJob = try await api.moduleJSON("gmail-cleanup/" + current.id.uuidString, query: query)
                    job = value
                    if !value.selected.isEmpty { selected = Set(value.selected) }
                } catch { notice = (error as? APIError)?.title ?? "Oprydningens gemte status kunne ikke hentes." }
            }
            await loadHistory()
        }
    }

    private func change(_ action: String) {
        guard let api, let current = job, !busy else { return }
        busy = true
        notice = nil
        let body: [String: Any] = ["action": action, "approved": true, "revision": current.revision,
                                   "selected": Array(selected).sorted(), "confirmTrash": current.mode == "trash"]
        Task { @MainActor in
            defer { busy = false }
            do {
                let value: AgentGmailCleanupJob = try await api.moduleJSON("gmail-cleanup/" + current.id.uuidString,
                    upload: JSONSerialization.data(withJSONObject: body), timeout: 240, query: query)
                job = value
                selected = Set(value.selected)
                if value.verifiedCount > 0 && value.receipt != lastReportedReceipt {
                    lastReportedReceipt = value.receipt
                    onResult(value.receipt)
                }
                await loadHistory()
            } catch {
                notice = (error as? APIError)?.title ?? "Forbindelsen blev afbrudt. Brug Kontrollér status før du prøver igen."
                // The durable job contains any completed work even if this response was lost.
                if let value: AgentGmailCleanupJob = try? await api.moduleJSON("gmail-cleanup/" + current.id.uuidString, query: query) {
                    job = value
                    selected = Set(value.selected)
                }
            }
        }
    }
}

private extension AgentGmailCleanupJob {
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}
