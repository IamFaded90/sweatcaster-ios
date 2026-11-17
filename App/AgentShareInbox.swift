import SwiftUI

struct AgentShareAttachment {
    let document: AgentDocument
    let onUse: () -> Void

    static func starterPassages(in document: AgentDocument) -> [AgentDocumentMatch] {
        document.passages.prefix(2).enumerated().map { offset, passage in
            AgentDocumentMatch(source: .init(id: offset + 1, name: document.name, page: passage.page),
                               text: String(passage.text.unicodeScalars.prefix(440)))
        }
    }
}

enum AgentSharedCalendar {
    static func matches(_ prompt: String) -> Bool {
        let text = AgentChatIntent.normalize(prompt)
        let pattern = #"^(?:læg|skriv|sæt|tilføj)(?: lige)? (?:(?:den|denne|den dér|det) )?(?:dato(?:en)?|aftale(?:n)?) i (?:min kalender|kalenderen)(?:[: ]+\s*(?:20\d\d-\d{2}-\d{2}|\d{1,2}[./]\d{1,2}[./]20\d\d))?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func dates(in text: String) -> [String] {
        let pattern = #"(?<!\d)(?:(20\d\d)-(\d{2})-(\d{2})|(\d{1,2})[./](\d{1,2})[./](20\d\d))(?!\d)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Array(Set(matches.compactMap { match -> String? in
            let parts = (1...6).map { index in Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } }
            guard let year = parts[0] ?? parts[5], let month = parts[1] ?? parts[4], let day = parts[2] ?? parts[3],
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, day)
        })).sorted()
    }
}

extension AgentPhoneChat {
    func canAskAboutSharedCalendar(_ prompt: String) -> Bool {
        guard keepHistory, let sharedAttachment, nextDocument?.id == sharedAttachment.document.id else { return false }
        return AgentSharedCalendar.matches(prompt)
    }

    func handleSharedCalendar(_ prompt: String) -> Bool {
        guard canAskAboutSharedCalendar(prompt), let document = nextDocument else { return false }
        let chosenDates = AgentSharedCalendar.dates(in: prompt)
        if prompt.contains(where: \.isNumber), chosenDates.isEmpty {
            notice = "Datoen kunne ikke læses. Skriv den med dag, måned og år."
            return true
        }
        let dates = chosenDates.isEmpty ? AgentSharedCalendar.dates(in: document.passages.map(\.text).joined(separator: "\n")) : chosenDates
        guard dates.count == 1, let day = dates.first else {
            let hint = "Skriv ‘Læg datoen i min kalender’ efterfulgt af datoen med årstal."
            notice = dates.isEmpty ? "Jeg fandt ingen entydig dato. " + hint
                : "Jeg fandt flere datoer (\(dates.prefix(4).joined(separator: ", "))). " + hint
            return true
        }
        let request = AgentPhoneActionCard.Request.phone(.calendar, prompt: "Opret en aftale om Delt aftale \(day)")
        startAgentAction(.action(.phone(request)), prompt: prompt)
        return true
    }
}

extension View {
    func assistantShareInbox(api: LiveAPI?, enabled: Bool) -> some View {
        modifier(AgentSharePresentation(api: api, enabled: enabled))
    }
}

@MainActor private struct AgentSharePresentation: ViewModifier {
    let api: LiveAPI?
    let enabled: Bool
    @Environment(\.scenePhase) private var phase
    @State private var offered = Set<UUID>()
    @State private var item: SharedAssistantInput?

    func body(content: Content) -> some View {
        content
            .onChange(of: phase == .active && enabled, initial: true) { _, available in
                guard available, item == nil, let pending = try? SharedAssistantInput.pending(),
                      let next = pending.first(where: { !offered.contains($0.id) }) else { return }
                offered.insert(next.id)
                item = next
            }
            .sheet(item: $item) { AgentShareReview(item: $0, api: api) }
    }
}

@MainActor struct AgentSharedInboxButton: View {
    let api: LiveAPI?
    @Environment(\.scenePhase) private var phase
    @State private var items: [SharedAssistantInput] = []
    @State private var selected: SharedAssistantInput?

    var body: some View {
        Group {
            if !items.isEmpty {
                Menu("Delt indhold", systemImage: "square.and.arrow.down") {
                    ForEach(items) { item in Button(item.title) { selected = item } }
                }
                .frame(minHeight: 44)
            }
        }
        .onChange(of: phase, initial: true) { _, phase in if phase == .active { reload() } }
        .sheet(item: $selected, onDismiss: reload) { AgentShareReview(item: $0, api: api) }
    }

    private func reload() { items = (try? SharedAssistantInput.pending()) ?? [] }
}

@MainActor private struct AgentShareReview: View {
    private struct Chat: Identifiable {
        let id = UUID()
        let bot: VillageBot
        let document: AgentDocument
    }

    let item: SharedAssistantInput
    let api: LiveAPI?
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: SharedAssistantInput.Prepared?
    @State private var webDocument: AgentDocument?
    @State private var notice: String?
    @State private var readingLink = false
    @State private var used = false
    @State private var chat: Chat?
    @State private var form: Data?
    @State private var showingForm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.title).font(.headline)
                    if let prepared {
                        if let address = prepared.url {
                            Link(address.host ?? "Åbn linket", destination: address)
                            if api != nil, webDocument == nil {
                                Button("Hent tekst fra siden", systemImage: "doc.text.magnifyingglass") { Task { await readLink(address) } }
                                    .disabled(readingLink)
                            }
                            if readingLink { ProgressView("Henter sidens tekst…") }
                        }
                        if let webDocument, let text = webDocument.passages.first?.text { Text(String(text.prefix(350))) }
                        else if !prepared.excerpt.isEmpty { Text(String(prepared.excerpt.prefix(350))) }
                        if let explanation = prepared.notice, webDocument == nil { Text(explanation).foregroundStyle(.secondary) }
                    } else if notice == nil { ProgressView("Gør indholdet klar…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                if let document = chatDocument {
                    Section {
                        Button("Spørg assistenten", systemImage: "bubble.left.and.bubble.right") {
                            let bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                            if let bot = bots.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? bots.first {
                                chat = Chat(bot: bot, document: document)
                            } else { notice = "Opret en agent i Landsbyen, så kan du bruge det delte indhold." }
                        }
                    }
                }
                if item.kind == .pdf {
                    Button("Udfyld formular", systemImage: "square.and.pencil") {
                        do { form = try item.pdfCopy(); showingForm = true }
                        catch { notice = "Den delte PDF kunne ikke åbnes til udfyldning." }
                    }
                }
                Button("Fjern fra FadedAI", role: .destructive) { remove(dismissAfter: true) }
            }
            .navigationTitle("Delt med FadedAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task { await prepare() }
            .sheet(item: $chat, onDismiss: { if used { dismiss() } }) { destination in
                AgentPhoneChat(bot: destination.bot, api: api, startsOnPhone: true,
                               sharedAttachment: .init(document: destination.document, onUse: { remove(dismissAfter: false) }))
            }
            .sheet(isPresented: $showingForm, onDismiss: { form = nil }) {
                if let form { AssistantPDFForm(initial: form, title: item.title) }
            }
        }
        .privacySensitive()
    }

    private var chatDocument: AgentDocument? {
        if let stored = webDocument ?? prepared?.document { return stored }
        guard let address = prepared?.url else { return nil }
        return AgentDocument(id: item.id, name: item.title, model: nil, passages: [
            .init(page: nil, text: "Delt link: \(address.absoluteString)\nSidens tekst er ikke vedhæftet.", vector: nil)
        ])
    }

    private func prepare() async {
        do {
            let result = try await item.prepare()
            try Task.checkCancellation()
            prepared = result
        } catch is CancellationError {
        } catch { notice = (error as? LocalizedError)?.errorDescription ?? "Det delte indhold kunne ikke læses." }
    }

    private func readLink(_ url: URL) async {
        guard let api, !readingLink else { return }
        notice = nil
        readingLink = true
        defer { readingLink = false }
        do {
            let result = try await api.chatResearch(query: url.absoluteString)
            try Task.checkCancellation()
            guard !result.context.isEmpty, result.sources.contains(where: { $0.readPage && $0.url == url }) else {
                notice = "FadedAI fandt ingen læsbar tekst på siden. Del gerne den markerede tekst fra Safari."
                return
            }
            webDocument = AgentDocument(id: item.id, name: item.title, model: nil,
                                        passages: [.init(page: nil, text: String(result.context.unicodeScalars.prefix(1_400)), vector: nil)])
        } catch is CancellationError {
        } catch { notice = "Siden kunne ikke læses. Du kan åbne linket eller dele tekst fra siden." }
    }

    private func remove(dismissAfter: Bool) {
        do {
            try item.remove()
            used = true
            if dismissAfter { dismiss() }
        } catch { notice = "FadedAI kunne ikke fjerne det delte indhold." }
    }
}
