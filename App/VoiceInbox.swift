import EventKit
import SwiftUI

enum VoiceInboxParser {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case reminder = "Påmindelse", shopping = "Indkøb", note = "Note"
        var id: Self { self }
        var icon: String {
            switch self {
            case .reminder: "checklist"
            case .shopping: "cart"
            case .note: "note.text"
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        var kind: Kind
        var text: String
        let original: String
        var include = true
        var saved = false
        var manualDue: Date? = nil
    }

    static func suggestions(from raw: String) -> [Item] {
        let command = #"(?:ring|køb|husk|mind mig|gem|notér|noter|tilføj|aflever|hent|book|betal|send|idéen med)\b"#
        let punctuation = #"[;\n]+|[!?](?=\s|$)\s*|(?<!\bkl)(?<!\bca)(?<!\bnr)(?<!\bfx)(?<!\d)\.(?=\s|$)\s*"#
        let boundary = punctuation + #"|\.\s+(?="# + command + #")|,\s*(?:og\s+)?(?="# + command + #")|\s+og\s+(?="# + command + ")"
        let parts = String(raw.prefix(4_000)).replacingOccurrences(of: boundary, with: "\n", options: [.regularExpression, .caseInsensitive])
        return parts.split(whereSeparator: \.isNewline).compactMap { part in
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !text.isEmpty else { return nil }
            let type: Kind
            if text.range(of: #"^(?:køb |tilføj .+ til (?:indkøb|min indkøbsliste))"#, options: [.regularExpression, .caseInsensitive]) != nil {
                type = .shopping
            } else if text.range(of: #"^(?:ring|mind mig|husk|aflever|hent|book|betal|send)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                type = .reminder
            } else { type = .note }
            let title = text.replacingOccurrences(of: #"^(?:gem(?: lige)? (?:en note om |en idé om )?|not[ée]r(?: lige)? |mind mig om (?:at )?|husk at )"#,
                                                   with: "", options: [.caseInsensitive, .regularExpression])
            return Item(kind: type, text: String((title.isEmpty ? text : title).prefix(240)), original: text)
        }
    }
}

@MainActor struct VoiceInboxEntry: View {
    @State private var showing = false

    var body: some View {
        FadedSecondaryButton("Tøm hovedet", icon: "waveform") { showing = true }
            .sheet(isPresented: $showing) { VoiceInboxView() }
    }
}

struct AssistantCaptureStrip: View {
    var body: some View {
        FadedCard(size: .compact, accent: FadedBrand.mint) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { VoiceInboxEntry(); AssistantPDFEntry() }
                VStack(alignment: .leading, spacing: 8) { VoiceInboxEntry(); AssistantPDFEntry() }
            }
        }
    }
}

@MainActor private struct VoiceInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @AppStorage("fadedai.voiceInbox.draft.v1") private var transcript = ""
    @State private var dictation = ChatDictation()
    @State private var recordingPrefix = ""
    @State private var items: [VoiceInboxParser.Item] = []
    @State private var store = EKEventStore()
    @State private var saving = false
    @State private var status: String?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    captureCard
                    if !items.isEmpty { reviewCard }
                    if let status { FadedDetailText(status).accessibilityAddTraits(.updatesFrequently) }
                }
                .padding(FadedSpacing.edge)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { FadedBackground() }
            .navigationTitle("Tøm hovedet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() }.disabled(saving) } }
            .confirmationDialog("Gem de valgte forslag?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Gem valgte") { Task { await save() } }
                Button("Annullér", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: phase) { _, value in if value != .active { dictation.stop() } }
        .onDisappear { dictation.stop() }
        .privacySensitive()
    }

    private var captureCard: some View {
        FadedCard(accent: FadedBrand.phone) {
            VStack(alignment: .leading, spacing: 10) {
                FadedDetailText("Sig eller skriv, hvad du har i hovedet. Gennemgå forslagene, før du gemmer dem.")
                FadedSecondaryButton(dictation.active ? "Stop optagelse" : "Tal til FadedAI",
                                     icon: dictation.active ? "stop.fill" : "mic.fill", action: toggleRecording)
                    .disabled(saving || !items.isEmpty)
                if let problem = dictation.problem { FadedDetailText(problem) }
                TextField("Det, du vil huske", text: $transcript, axis: .vertical).lineLimit(4...9)
                    .textFieldStyle(.roundedBorder).disabled(dictation.active || saving || !items.isEmpty)
                if items.isEmpty {
                    FadedPrimaryButton("Vis forslag", icon: "list.bullet") {
                        dictation.stop()
                        guard transcript.count <= 4_000 else { status = "Del teksten op i kortere bidder på højst 4.000 tegn."; return }
                        let suggestions = VoiceInboxParser.suggestions(from: transcript)
                        guard suggestions.count <= 24 else { status = "Del teksten op, så du gennemgår højst 24 forslag ad gangen."; return }
                        items = suggestions
                        status = items.isEmpty ? "Skriv eller dikter en idé først." : nil
                    }
                    .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var reviewCard: some View {
        FadedCard(accent: FadedBrand.mint) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($items) { $item in
                    if item.saved { Label(item.text, systemImage: "checkmark.circle").font(.subheadline) }
                    else {
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle("Medtag forslag", isOn: $item.include)
                            HStack {
                                Picker("Type", selection: $item.kind) {
                                    ForEach(VoiceInboxParser.Kind.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                                }
                                TextField("Forslag", text: $item.text).textFieldStyle(.roundedBorder)
                            }
                            if item.kind != .note {
                                if let chosen = item.manualDue {
                                    DatePicker("Tidspunkt", selection: Binding(get: { item.manualDue ?? chosen }, set: { item.manualDue = $0 }),
                                               in: Date.now...)
                                    Button("Fjern valgt tid") { item.manualDue = nil }
                                } else if let due = proposedTime(item.text) {
                                    Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                } else if phonePlan(item.text).needsDate == true {
                                    FadedSecondaryButton("Vælg tidspunkt", icon: "clock") { item.manualDue = suggestedDay(item.text) }
                                }
                            }
                        }
                        .disabled(saving)
                    }
                }
                FadedPrimaryButton(saving ? "Gemmer…" : "Gem valgte", icon: "checkmark") { confirm = true }
                    .disabled(saving || !items.contains(where: { $0.include && !$0.saved && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }))
                FadedSecondaryButton("Tilbage til teksten", icon: "chevron.left") {
                    if items.contains(where: \.saved) { transcript = remainingText }
                    items = []
                }.disabled(saving)
            }
        }
    }

    private var remainingText: String { items.filter { !$0.saved }.map(\.original).joined(separator: "\n") }

    private func phonePlan(_ text: String) -> BotPhoneAction { AgentPhoneLanguage.action(.reminder, prompt: text, now: .now) }

    private func proposedTime(_ text: String) -> Date? {
        phonePlan(text).localDate.flatMap { BotPhoneAction.localFormatter().date(from: $0) }
    }

    private func suggestedDay(_ text: String) -> Date {
        let calendar = AgentCalendarAvailability.clock
        let fallback = Date.now.addingTimeInterval(3_600)
        guard let day = AgentPhoneLanguage.day(in: text, now: .now, calendar: calendar),
              let proposed = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day), proposed > .now else { return fallback }
        return proposed
    }

    private func toggleRecording() {
        if dictation.active { dictation.stop(); return }
        recordingPrefix = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await dictation.start(contextualStrings: ["påmindelse", "indkøb", "note"]) { spoken in
                transcript = String([recordingPrefix, spoken].filter { !$0.isEmpty }.joined(separator: "\n").prefix(4_000))
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        var complete = 0
        var failed = 0
        var problem: String?
        for index in items.indices where items[index].include && !items[index].saved {
            let row = items[index]
            let value = String(row.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            guard !value.isEmpty else { continue }
            do {
                if row.kind == .note {
                    let notes = MigratedAppData.shared.notes
                    let line = "• " + value
                    if !notes.components(separatedBy: "\n").contains(line) {
                        try MigratedAppData.shared.saveNotes(notes.isEmpty ? line : notes + "\n" + line)
                    }
                } else {
                    let due = row.manualDue ?? proposedTime(value)
                    if due == nil && phonePlan(value).needsDate == true {
                        failed += 1
                        problem = "Vælg tidspunktet for de forslag, der mangler det."
                        continue
                    }
                    let title = row.kind == .shopping && !value.lowercased().hasPrefix("køb ") ? "Køb " + value : value
                    try await PhoneActions.saveReminder(title: title, due: due, jobID: row.id, store: store,
                                                       preferredLists: row.kind == .shopping ? ["Indkøb", "Indkøbsliste"] : [])
                }
                items[index].saved = true
                transcript = remainingText
                complete += 1
            } catch {
                failed += 1
                problem = (error as? PhoneActions.Failure)?.message ?? "Forslaget kunne ikke gemmes."
            }
        }
        status = failed == 0 ? "Gemt · \(complete)" : "Gemt · \(complete). Mangler · \(failed). " + (problem ?? "")
        if failed == 0 && items.allSatisfy({ $0.saved || !$0.include }) { transcript = "" }
    }
}
