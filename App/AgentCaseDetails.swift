import PhotosUI
import SwiftUI
import UIKit

@MainActor struct AgentCaseDetails: View {
    let api: LiveAPI
    let bot: VillageBot
    let onResult: (String) -> Void
    @State private var record: AgentCaseRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var busy = false
    @State private var notice: String?
    @State private var query = ""
    @State private var recipient = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var note = ""
    @State private var reviewing = false
    @State private var closeOpen = false
    @State private var closeReason = ""
    @State private var removing = false
    @State private var editingFacts = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var lastReported: String

    init(api: LiveAPI, bot: VillageBot, record: AgentCaseRecord, onResult: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.bot = bot
        self.onResult = onResult
        _record = State(initialValue: record)
        _lastReported = State(initialValue: Self.resultToken(record))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    facts
                    receipt
                    photoCard
                    draftCard
                    followup
                    if !record.incoming.isEmpty { incoming }
                    notes
                    timeline
                    closing
                    if busy { ProgressView("Opdaterer sagen…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .standard) }
            .navigationTitle("Din sag").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hent seneste status", systemImage: "arrow.clockwise") { change("refresh") }
                        .labelStyle(.iconOnly).disabled(busy)
                }
            }
            .sheet(isPresented: $reviewing) { sendReview }
            .sheet(isPresented: $closeOpen) { closeReview }
            .sheet(isPresented: $editingFacts) {
                AgentCaseEditFacts(record: record) { fields in
                    editingFacts = false
                    change("edit", extra: fields)
                }
            }
            .confirmationDialog("Fjern sagen og dens lokale fotos?", isPresented: $removing, titleVisibility: .visible) {
                Button("Fjern sagen", role: .destructive) { change("remove", extra: ["approved": true]) }
                Button("Behold sagen", role: .cancel) { }
            } message: {
                Text("Agenten stopper med at følge sagen. Mailene i Gmail bliver liggende.")
            }
            .task { syncDraft(); await loadLatest(checkMail: record.watch) }
            .onChange(of: phase) { _, phase in
                if phase == .active && !busy { Task { await loadLatest(checkMail: record.watch) } }
            }
            .onChange(of: photos) { _, value in if !value.isEmpty { upload(value) } }
            .interactiveDismissDisabled(busy)
        }
    }

    private var status: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.title).font(.title3.bold())
                Label(record.stateTitle, systemImage: record.state == "closed" ? "checkmark.seal" : "folder")
                    .font(.headline)
                Text(record.note)
                Text("\(bot.name) holder dokumentation og opfølgning samlet her.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var facts: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dine oplysninger").font(.headline)
                if !record.merchant.isEmpty { Text("Firma · " + record.merchant) }
                Text(record.problem)
                if !record.desired.isEmpty { Text("Ønsket løsning · " + record.desired) }
                if !record.reference.isEmpty { Text("Ordre-/købsreference · " + record.reference) }
                if record.editable {
                    Button("Ret oplysninger", systemImage: "pencil") { editingFacts = true }.frame(minHeight: 44).disabled(busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var receipt: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Kvittering og købsbevis", systemImage: "doc.text.magnifyingglass").font(.headline)
                if let chosen = record.receipt {
                    Text(chosen.subject).font(.subheadline.bold())
                    Text(chosen.sender).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Læs den valgte mail") {
                        Text(chosen.text.isEmpty ? "Mailen har ingen læsbar tekst." : chosen.text)
                            .font(.callout).textSelection(.enabled).padding(.top, 8)
                    }
                    Text("Mailen bruges som kildehenvisning. De fotos, du vælger nedenfor, vedhæftes selve reklamationen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if record.editable {
                    TextField("Søg i Gmail · fx butikkens navn", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    FadedSecondaryButton("Find kvitteringen i Gmail", icon: "magnifyingglass") {
                        change("searchReceipt", extra: ["query": query.isEmpty ? "{kvittering faktura receipt invoice}" : query])
                    }.disabled(busy || query.count > 160)
                    ForEach(record.candidates) { candidate in
                        Button { change("selectReceipt", extra: ["messageID": candidate.id]) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.subject).font(.subheadline.bold())
                                Text(candidate.sender).font(.footnote).foregroundStyle(.secondary)
                                Text(record.receipt?.id == candidate.id ? "Valgt til sagen" : "Vælg denne mail").font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        }.disabled(busy)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var photoCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Fotos der følger med", systemImage: "photo.on.rectangle.angled").font(.headline)
                if record.photos.isEmpty { Text("Tilføj fx et foto af fejlen, varen eller dit købsbevis.").foregroundStyle(.secondary) }
                ForEach(record.photos) { photo in
                    AgentCasePhotoRow(api: api, record: record, photo: photo) {
                        if record.editable {
                            Button("Slet foto", systemImage: "trash", role: .destructive) {
                                change("removePhoto", extra: ["photoID": photo.id.uuidString])
                            }.disabled(busy || unsavedDraft)
                        }
                    }
                }
                if record.editable && record.photos.count < 4 {
                    PhotosPicker(selection: $photos, maxSelectionCount: 4 - record.photos.count, matching: .images) {
                        Label("Tilføj fotos fra iPhone", systemImage: "photo.badge.plus").frame(minHeight: 44)
                    }.disabled(busy || unsavedDraft)
                }
                if unsavedDraft { Text("Gem først dine tekstændringer til kladden, før du ændrer fotos.").font(.footnote).foregroundStyle(.secondary) }
                Text("Højst fire fotos. De tilpasses i størrelse og gemmes i sagen på din PC.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var draftCard: some View {
        if record.editable {
            FadedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Mailforslag", systemImage: "square.and.pencil").font(.headline)
                    if let draft = record.draft {
                        Text("Fra · " + draft.sender).font(.footnote).foregroundStyle(.secondary)
                        TextField("Kundeservices e-mailadresse", text: $recipient)
                            .keyboardType(.emailAddress).textContentType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let suggested = record.receipt?.suggestedRecipient, !suggested.isEmpty, recipient != suggested {
                            Button("Brug mailens svaradresse · " + suggested) { recipient = suggested }
                                .font(.footnote).frame(minHeight: 44)
                        }
                        TextField("Emne", text: $subject)
                        TextEditor(text: $message).scrollContentBackground(.hidden).frame(minHeight: 210)
                            .accessibilityLabel("Reklamationens tekst")
                        if unsavedDraft {
                            FadedSecondaryButton("Gem mine ændringer til kladden", icon: "checkmark") {
                                change("draft", extra: ["recipient": recipient, "subject": subject, "body": message])
                            }.disabled(busy || recipient.isEmpty || subject.isEmpty || message.isEmpty)
                        }
                        Text("Tjek at adressen tilhører kundeservice. En kvittering kan komme fra en adresse, der ikke læser svar.")
                            .font(.footnote).foregroundStyle(.secondary)
                        FadedPrimaryButton("Gennemse mail og fotos", icon: "paperplane") { reviewing = true }
                            .disabled(busy || unsavedDraft || draft.recipient.isEmpty)
                    } else {
                        Text("Forslaget bygger på det, du har fortalt, og den kvitteringsmail, du selv vælger.")
                        FadedPrimaryButton("Lav et mailforslag", icon: "square.and.pencil") { change("draft") }
                            .disabled(busy)
                    }
                }.disabled(busy)
            }
        } else if let outgoing = record.outgoing {
            FadedCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label(outgoing.verified ? "Kontrolleret i Sendt hos Gmail" : "Afsendelsen mangler bekræftelse",
                          systemImage: outgoing.verified ? "checkmark.circle" : "clock.badge.exclamationmark")
                        .font(.headline)
                    Text("Til · " + outgoing.recipient)
                    Text(outgoing.subject).font(.subheadline.bold())
                    DisclosureGroup("Læs den godkendte mail") { Text(outgoing.body).textSelection(.enabled).padding(.top, 8) }
                    Text("\(outgoing.photos.count) fotos var med i godkendelsen.").font(.footnote).foregroundStyle(.secondary)
                    if !outgoing.verified {
                        Text("Vi sender ikke en kopi. Tjek status her eller Sendt i Gmail.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var followup: some View {
        if record.outgoing != nil && record.state != "closed" {
            FadedCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Opfølgning i den samme Gmail-tråd").font(.headline)
                    Toggle("Lad agenten holde øje med svar", isOn: Binding(get: { record.watch }, set: {
                        change("watch", extra: ["enabled": $0])
                    })).disabled(busy)
                    Text("PC’en tjekker cirka hvert femte minut, når den er tændt. Agenten sender ikke rykkere af sig selv.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let stamp = record.lastChecked {
                        HStack {
                            Text("Sidst tjekket")
                            Text(Date(timeIntervalSince1970: stamp), style: .relative)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    FadedSecondaryButton("Tjek status og nye svar", icon: "arrow.clockwise") { change("refresh") }
                        .disabled(busy)
                    if let url = record.gmailURL {
                        Link(destination: url) { Label("Åbn og svar i Gmail-tråden", systemImage: "arrow.up.right.square") }
                            .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var incoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Svar i sagen").font(.headline)
            ForEach(record.incoming.reversed()) { reply in
                FadedCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reply.subject).font(.headline)
                        Text(reply.sender).font(.subheadline).foregroundStyle(.secondary)
                        Text(reply.text).textSelection(.enabled)
                        Text(Date(timeIntervalSince1970: reply.created), style: .date).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var notes: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tilføj en oplysning til sagen").font(.headline)
                TextField("Fx hvem du talte med, eller hvad I aftalte", text: $note, axis: .vertical).lineLimit(2...5)
                FadedSecondaryButton("Gem note", icon: "note.text.badge.plus") { change("note", extra: ["text": note]) }
                    .disabled(busy || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.count > 3000)
            }
        }
    }

    private var timeline: some View {
        FadedCard {
            DisclosureGroup("Sagsforløb · \(record.events.count) hændelser") {
                ForEach(record.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.text).font(.callout)
                        Text(Date(timeIntervalSince1970: event.created), style: .date).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
        }
    }

    private var closing: some View {
        VStack(spacing: 12) {
            if record.state == "closed" {
                FadedSecondaryButton("Genåbn sagen", icon: "arrow.uturn.backward") { change("reopen") }.disabled(busy)
            } else {
                FadedSecondaryButton("Jeg vil afslutte sagen", icon: "checkmark.seal") { closeOpen = true }.disabled(busy)
            }
            Button("Fjern sag og lokale fotos", role: .destructive) { removing = true }.frame(minHeight: 44).disabled(busy)
        }
    }

    private var sendReview: some View {
        NavigationStack {
            ScrollView {
                if let draft = record.draft {
                    VStack(alignment: .leading, spacing: 16) {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Fra · " + draft.sender).font(.footnote)
                                Text("Til · " + draft.recipient).font(.headline)
                                Text(draft.subject).font(.headline)
                                Divider()
                                Text(draft.body).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(draft.photos) { photo in
                            AgentCasePhotoRow(api: api, record: record, photo: photo) { EmptyView() }
                        }
                        FadedPrimaryButton("Send denne mail med \(draft.photos.count) fotos", icon: "paperplane.fill") {
                            reviewing = false
                            change("send", extra: ["approved": true, "draftDigest": draft.digest])
                        }.disabled(busy || unsavedDraft)
                    }.padding(FadedSpacing.edge)
                }
            }
            .background { FadedBackground() }
            .navigationTitle("Gennemse og send").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Tilbage til kladden") { reviewing = false } } }
        }
    }

    private var closeReview: some View {
        NavigationStack {
            ScrollView {
                FadedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Er sagen løst, eller vil du stoppe den?").font(.headline)
                        Text("Du vælger selv. Agenten afslutter ikke en sag, bare fordi en mail siger, at alt er ordnet.")
                        TextField("Hvorfor afslutter du sagen?", text: $closeReason, axis: .vertical).lineLimit(3...6)
                        FadedPrimaryButton("Afslut sagen", icon: "checkmark.seal") {
                            closeOpen = false
                            change("close", extra: ["approved": true, "reason": closeReason])
                        }.disabled(closeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || closeReason.count > 1000)
                    }
                }.padding(FadedSpacing.edge)
            }.background { FadedBackground() }.navigationTitle("Afslut sag")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Behold sagen åben") { closeOpen = false } } }
        }
    }

    private var unsavedDraft: Bool {
        guard let saved = record.draft else { return false }
        return saved.recipient != recipient || saved.subject != subject || saved.body != message
    }

    private func syncDraft() {
        recipient = record.draft?.recipient ?? ""
        subject = record.draft?.subject ?? ""
        message = record.draft?.body ?? ""
        if query.isEmpty { query = record.merchant }
    }

    private static func resultToken(_ record: AgentCaseRecord) -> String {
        "\(record.state)|\(record.outgoing?.verified ?? false)|\(record.incoming.count)"
    }

    private func report() {
        let key = Self.resultToken(record)
        guard key != lastReported else { return }
        lastReported = key
        if record.state == "closed" { onResult("Sagen “\(record.title)” er afsluttet efter dit valg.") }
        else if !record.incoming.isEmpty { onResult("Der er \(record.incoming.count) svar i Gmail-tråden for “\(record.title)”. Sagen er stadig åben.") }
        else if record.outgoing?.verified == true {
            onResult("Reklamationen “\(record.title)” er sendt til \(record.outgoing?.recipient ?? "") og genlæst i Gmail med \(record.photos.count) fotos. Agenten følger sagen, hvis Hold øje med svar er slået til.")
        }
    }

    private func loadLatest(checkMail: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let preserveDraft = unsavedDraft
        do {
            record = try await api.moduleJSON("agent-cases/" + record.id.uuidString,
                                             query: [.init(name: "bot_id", value: bot.id.uuidString)])
            if checkMail && record.outgoing != nil && record.state != "closed" {
                record = try await api.caseAction(record.id.uuidString, body: ["action": "refresh"], bot: bot.id)
                report()
            }
            if !preserveDraft { syncDraft() }
        } catch { notice = (error as? APIError)?.title ?? "PC’en kunne ikke hente sagen lige nu. Den gemte sag bliver liggende." }
    }

    private func change(_ action: String, extra: [String: Any] = [:]) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let body = extra.merging(["action": action, "revision": record.revision]) { _, current in current }
                if action == "remove" {
                    struct Removed: Decodable { let removed: Bool }
                    let _: Removed = try await api.caseAction(record.id.uuidString, body: body, bot: bot.id)
                    dismiss()
                } else {
                    record = try await api.caseAction(record.id.uuidString, body: body, bot: bot.id)
                    if action == "note" { note = "" }
                    if ["edit", "draft", "selectReceipt", "removePhoto"].contains(action) { syncDraft() }
                    report()
                }
            } catch {
                notice = (error as? APIError)?.title ?? "Sagen kunne ikke opdateres. Hent seneste status før et nyt forsøg."
                if action == "send", let latest: AgentCaseRecord = try? await api.moduleJSON("agent-cases/" + record.id.uuidString,
                    query: [.init(name: "bot_id", value: bot.id.uuidString)]) { record = latest; report() }
            }
        }
    }

    private func upload(_ selected: [PhotosPickerItem]) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false; photos = [] }
            do {
                for selection in selected {
                    guard let photo = try await selection.loadTransferable(type: AgentSalePhoto.self) else { throw CocoaError(.fileReadCorruptFile) }
                    let body: [String: Any] = ["id": UUID().uuidString, "data": photo.jpeg.base64EncodedString(), "revision": record.revision]
                    record = try await api.caseAction(record.id.uuidString + "/photos", body: body, bot: bot.id)
                }
                syncDraft()
            } catch {
                notice = (error as? APIError)?.title ?? "Et foto kunne ikke gemmes. Tjek sagen før du vælger billedet igen."
                if let latest: AgentCaseRecord = try? await api.moduleJSON("agent-cases/" + record.id.uuidString,
                    query: [.init(name: "bot_id", value: bot.id.uuidString)]) { record = latest; syncDraft() }
            }
        }
    }
}

@MainActor private struct AgentCaseEditFacts: View {
    let onSave: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var merchant: String
    @State private var problem: String
    @State private var desired: String
    @State private var reference: String

    init(record: AgentCaseRecord, onSave: @escaping ([String: Any]) -> Void) {
        self.onSave = onSave
        _title = State(initialValue: record.title)
        _merchant = State(initialValue: record.merchant)
        _problem = State(initialValue: record.problem)
        _desired = State(initialValue: record.desired)
        _reference = State(initialValue: record.reference)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                FadedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Kort titel", text: $title)
                        TextField("Butik eller firma", text: $merchant)
                        TextField("Hvad er der sket?", text: $problem, axis: .vertical).lineLimit(3...7)
                        TextField("Ønsket løsning", text: $desired, axis: .vertical).lineLimit(2...4)
                        TextField("Ordre-/købsreference", text: $reference)
                        Text("Lav et nyt mailforslag bagefter, så det bruger dine opdaterede oplysninger.")
                            .font(.footnote).foregroundStyle(.secondary)
                        FadedPrimaryButton("Gem oplysninger", icon: "checkmark") {
                            onSave(["title": title, "merchant": merchant, "problem": problem, "desired": desired, "reference": reference])
                        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                   problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                   title.count > 160 || merchant.count > 160 || problem.count > 3000 || desired.count > 1000 || reference.count > 200)
                    }
                }.padding(FadedSpacing.edge)
            }.background { FadedBackground() }.navigationTitle("Ret sagen")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuller") { dismiss() } } }
        }
    }
}

@MainActor private struct AgentCasePhotoRow<Controls: View>: View {
    let api: LiveAPI
    let record: AgentCaseRecord
    let photo: AgentCaseRecord.Photo
    @ViewBuilder let controls: () -> Controls
    @State private var data: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200).clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Sagens foto: " + photo.name)
            }
            HStack {
                VStack(alignment: .leading) {
                    Text(photo.name).font(.footnote)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(photo.bytes), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                controls().labelStyle(.iconOnly).frame(minHeight: 44)
            }
        }.task(id: photo.id) {
            struct Photo: Decodable { let data: Data }
            let result: Photo? = try? await api.moduleJSON("agent-cases/\(record.id.uuidString)/photos/\(photo.id.uuidString)",
                query: [.init(name: "bot_id", value: record.botID.uuidString)], maximumBytes: 400_000)
            if !Task.isCancelled { data = result?.data }
        }
    }
}
