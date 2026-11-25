import PhotosUI
import SwiftUI

@MainActor struct CaptureReviewView: View {
    let bot: VillageBot
    let model: String
    var initial = ""
    var initialSource = "Din tekst"
    var onResult: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var text = ""
    @State private var sourceTitle = "Din tekst"
    @State private var proposals: [CapturedInsight.Proposal] = []
    @State private var stored: [CapturedInsight.Entry] = []
    @State private var pending: [CapturedInsight.Pending] = []
    @State private var receipts: [UUID: String] = [:]
    @State private var photo: PhotosPickerItem?
    @State private var capture = AgentWhisperCapture()
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var notice: String?
    @State private var review: CapturedInsight.Proposal?
    private var store: CapturedInsight.Store { .init(botID: bot.id) }
    var body: some View {
        NavigationStack {
            List {
                Section("Fang én gang · gennemgå bagefter") {
                    Text("Skriv, dikter eller læs teksten i et foto. Forslagene knyttes til dine egne ord. Der gemmes eller oprettes først noget, når du vælger det.").foregroundStyle(.secondary)
                    TextEditor(text: $text).frame(minHeight: 130).accessibilityLabel("Kildetekst")
                        .disabled(busy || capture.active || !proposals.isEmpty)
                    HStack {
                        PhotosPicker(selection: $photo, matching: .images) { Label("Læs foto", systemImage: "photo") }
                            .disabled(busy || capture.active || !proposals.isEmpty)
                        Spacer()
                        Button(capture.active ? "Stop og skriv tekst" : "Diktér dansk", systemImage: capture.active ? "stop.fill" : "mic") { record() }
                            .disabled(busy || capture.processing || !proposals.isEmpty || AgentWhisper.availableModels(for: "da-DK").isEmpty)
                    }.frame(minHeight: 44)
                    if AgentWhisper.availableModels(for: "da-DK").isEmpty { Text("Hent den danske dikteringsmodel i Offline-indstillinger for at diktere her.").font(.caption) }
                    if proposals.isEmpty {
                        Button("Find konkrete forslag", systemImage: "sparkles") { suggest() }
                            .frame(minHeight: 44).disabled(busy || capture.active || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !PhoneModels.isReady(model))
                        Button("Opret en note selv", systemImage: "square.and.pencil") {
                            guard !text.isEmpty, text.count <= 900 else { notice = "Vælg et kortere uddrag på højst 900 tegn til noten."; return }
                            proposals = [.init(kind: .note, text: String(text.prefix(240)), quote: text)]
                        }.frame(minHeight: 44).disabled(busy || capture.active)
                    } else { Button("Tilbage til kildeteksten") { proposals = []; receipts = [:] }.frame(minHeight: 44) }
                    if busy || capture.processing { ProgressView("Arbejder på iPhone…") }
                    if busy || capture.active || capture.processing { Button("Stop", role: .cancel) { operation?.cancel(); capture.cancel() }.frame(minHeight: 44) }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                }
                if !proposals.isEmpty {
                    Section("Vælg det, du vil bruge") {
                        ForEach($proposals) { $proposal in
                            VStack(alignment: .leading, spacing: 8) {
                                if let receipt = receipts[proposal.id] ?? pending.first(where: { $0.id == proposal.id })?.receipt {
                                    Label(receipt, systemImage: "checkmark.circle")
                                } else if pending.contains(where: { $0.id == proposal.id }) {
                                    Text("Resultatet er ikke bekræftet. Kontrollér, om handlingen allerede er udført.").font(.caption)
                                }
                                else {
                                    Picker("Type", selection: $proposal.kind) { ForEach(CapturedInsight.Kind.allCases) { Text($0.title).tag($0) } }
                                    TextField("Forslag", text: $proposal.text, axis: .vertical).lineLimit(1...4)
                                }
                                Text("“\(proposal.quote)”").font(.subheadline).textSelection(.enabled)
                                Text(sourceTitle).font(.caption).foregroundStyle(.secondary)
                                if let item = pending.first(where: { $0.id == proposal.id }) {
                                    pendingControls(item)
                                } else if receipts[proposal.id] == nil {
                                    Button(proposal.kind == .reminder || proposal.kind == .calendar ? "Gennemgå på telefonen" : "Gem som agentens note", systemImage: "checkmark") {
                                        guard prepare(proposal) else { return }
                                        if proposal.kind == .reminder || proposal.kind == .calendar { review = proposal } else { save(proposal, receipt: nil) }
                                    }.frame(minHeight: 44).disabled(proposal.text.count > 240 || proposal.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                let otherPending = pending.filter { item in !proposals.contains(where: { $0.id == item.id }) }
                if !otherPending.isEmpty {
                    Section("Kilder, der mangler at blive gemt") {
                        ForEach(otherPending) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.proposal.text).font(.headline)
                                Text("“\(item.proposal.quote)”").textSelection(.enabled)
                                Text(item.source).font(.caption).foregroundStyle(.secondary)
                                if let receipt = item.receipt { Label(receipt, systemImage: "checkmark.circle") }
                                pendingControls(item)
                            }.padding(.vertical, 6)
                        }
                    }
                }
                if !stored.isEmpty {
                    Section {
                        ForEach(stored) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.proposal.text).font(.headline)
                                Text(entry.proposal.quote).textSelection(.enabled)
                                Text("\(entry.source) · \(entry.captured.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                if let receipt = entry.receipt { Text(receipt).font(.caption) }
                            }.swipeActions { Button("Fjern uddrag", role: .destructive) { do { try store.remove(entry.id); stored = try store.load() } catch { notice = error.localizedDescription } } }
                        }
                    } header: { Text("Gemte kilder") } footer: { Text("Fjern uddrag sletter denne kildekopi. Gemte noter fjernes i agentens hukommelse; kalenderaftaler og påmindelser i deres egne apps.") }
                }
            }.scrollContentBackground(.hidden).background { FadedBackground() }
                .navigationTitle("Fang og følg op").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear {
                    if text.isEmpty { text = initial; sourceTitle = initialSource }
                    do { stored = try store.load() }
                    catch { notice = error.localizedDescription }
                    do { pending = try store.loadPending() }
                    catch { notice = error.localizedDescription }
                }
                .onChange(of: photo) { _, item in read(item) }
                .onChange(of: phase) { _, value in if value != .active { capture.cancel() } }
                .onDisappear { operation?.cancel(); capture.cancel() }
                .sheet(item: $review) { proposal in
                    BotPhoneActionReview(action: AgentPhoneLanguage.action(proposal.kind == .calendar ? .calendar : .reminder, prompt: proposal.text, now: .now), jobID: proposal.id, botName: bot.name,
                        reminderNotes: sourceTitle + "\n“" + proposal.quote + "”", onSaved: { save(proposal, receipt: $0) }, onApplied: {})
                }
        }
    }
    private func read(_ item: PhotosPickerItem?) {
        guard let item, !busy else { return }; busy = true; notice = nil
        operation = Task {
            defer { busy = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CapturedInsight.Failure.source }
                let normalized = try CameraGuideImage.normalize(data), anchors = try await CameraGuideImage.anchors(normalized)
                try Task.checkCancellation()
                let recognized = anchors.map(\.text).joined(separator: "\n")
                guard !recognized.isEmpty, recognized.count + text.count <= 6_000 else { throw CapturedInsight.Failure.source }
                text += (text.isEmpty ? "" : "\n") + recognized; sourceTitle = "Dit foto · genkendt tekst"; photo = nil
                notice = "Læs teksten igennem; bogstaver og beløb kan være genkendt forkert."
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func record() {
        operation = Task {
            do {
                if capture.active {
                    let spoken = try await capture.finish(language: "da-DK"); try Task.checkCancellation()
                    guard spoken.count + text.count <= 6_000 else { throw CapturedInsight.Failure.format }
                    text += (text.isEmpty ? "" : "\n") + spoken; sourceTitle = "Din optagelse · gennemgået transskription"
                } else { try await capture.start(language: "da-DK", whenFull: { record() }) }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func suggest() {
        guard !busy, text.count <= 6_000 else { notice = "Brug højst 6.000 tegn ad gangen."; return }
        busy = true; notice = nil; let source = text
        operation = Task {
            defer { busy = false }
            do {
                var reply = ""
                try await PhoneModels.reply(modelID: model, prompt: "Kildetekst:\n" + source, instructions: CapturedInsight.instructions) { reply = $0 }
                try Task.checkCancellation(); proposals = try CapturedInsight.decode(reply, source: source)
                if proposals.isEmpty { notice = "Ingen konkrete forslag. Du kan oprette en note selv." }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func save(_ proposal: CapturedInsight.Proposal, receipt: String?) {
        if let receipt {
            // Preserve a known native result in the view even if the journal
            // cannot be read or written immediately after the action.
            receipts[proposal.id] = receipt
            archive(proposal.id, receipt: receipt)
            return
        }
        do {
            try proposal.validate(source: text)
            guard try store.loadPending().contains(where: { $0.id == proposal.id }) else { throw CapturedInsight.Failure.format }
            _ = try AgentMemory.Store(botID: bot.id).remember(proposal.kind.title + ": " + proposal.text + "\nKilde: “" + proposal.quote + "”", sourceTurnID: nil)
            let result = "Gemt i \(bot.name)s hukommelse"
            receipts[proposal.id] = result
            archive(proposal.id, receipt: result)
        } catch { notice = error.localizedDescription }
    }
    private func prepare(_ proposal: CapturedInsight.Proposal) -> Bool {
        do {
            try store.prepare(proposal, sourceText: text, sourceTitle: sourceTitle)
            pending = try store.loadPending()
            return true
        } catch { notice = "Handlingen blev ikke startet. " + error.localizedDescription; return false }
    }
    @ViewBuilder private func pendingControls(_ item: CapturedInsight.Pending) -> some View {
        if let receipt = receipts[item.id] ?? item.receipt {
            Button("Gem kilde og kvittering igen", systemImage: "arrow.clockwise") { archive(item.id, receipt: receipt) }.frame(minHeight: 44)
            Text("Prøver kun at gemme kilden igen. Påmindelsen, aftalen eller noten oprettes ikke igen.").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Kontrollér først i Påmindelser, Kalender eller agentens hukommelse, om handlingen allerede blev udført. Ingen handling gentages automatisk.").font(.caption).foregroundStyle(.secondary)
            Button("Gem kilden som ubekræftet", systemImage: "tray.and.arrow.down") {
                archive(item.id, receipt: "Ubekræftet – kontrollér selv, om handlingen blev udført.")
            }.frame(minHeight: 44)
            Button("Fjern klargøringen", role: .destructive) {
                do { try store.removePending(item.id); pending = try store.loadPending(); notice = "Klargøringen er fjernet. En eventuel oprettet handling er ikke ændret." }
                catch { notice = error.localizedDescription }
            }.frame(minHeight: 44)
        }
    }
    private func archive(_ id: UUID, receipt: String) {
        receipts[id] = receipt
        do {
            guard let item = try store.loadPending().first(where: { $0.id == id }) else { throw CapturedInsight.Failure.format }
            if let existing = item.receipt {
                guard existing == receipt else { throw CapturedInsight.Failure.format }
            } else { try store.recordReceipt(receipt, for: id) }
            try store.archivePending(id)
            pending = try store.loadPending(); stored = try store.load()
            notice = "Kilden og kvitteringen er gemt."
            onResult(receipt + "\n“" + item.proposal.quote + "”\n" + item.source)
        } catch {
            pending = (try? store.loadPending()) ?? pending
            notice = "Svaret er modtaget, men kilden kunne ikke gemmes endnu. Prøv Gem kilde og kvittering igen. " + error.localizedDescription
        }
    }
}

@MainActor struct CaptureReviewEntry: View {
    @State private var showing = false
    @AppStorage(AppStorageKeys.phoneModel) private var model = "apple"
    var body: some View {
        FadedSecondaryButton("Fang og følg op", icon: "square.and.pencil") { showing = true }
            .sheet(isPresented: $showing) {
                let bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                if let bot = bots.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? bots.first { CaptureReviewView(bot: bot, model: model) }
                else { Text("Opret en agent i Landsbyen først.").padding() }
            }
    }
}
