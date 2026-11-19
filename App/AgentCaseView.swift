import SwiftUI

@MainActor struct AgentCaseView: View {
    let api: LiveAPI?
    let bot: VillageBot
    let prompt: String
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cases: [AgentCaseRecord] = []
    @State private var selected: AgentCaseRecord?
    @State private var title = ""
    @State private var merchant = ""
    @State private var problem = ""
    @State private var desired = ""
    @State private var reference = ""
    @State private var formOpen = true
    @State private var busy = false
    @State private var notice: String?
    @State private var creation = AgentCaseCreationAttempt()
    @State private var initialized = false

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
                    FadedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Få det ordnet med \(bot.name)", systemImage: "checkmark.bubble")
                                .font(.title3.bold())
                            Text("Fra kvittering og fotos til en reklamation, du gennemser. Agenten holder sagen samlet og tjekker for svar.")
                            Text("Der sendes først, når du vælger Send denne mail.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    FadedCard {
                        DisclosureGroup("Opret en sag", isExpanded: $formOpen) {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Kort titel · fx Skærmen virker ikke", text: $title)
                                TextField("Butik eller firma", text: $merchant)
                                TextField("Hvad er der sket?", text: $problem, axis: .vertical).lineLimit(3...7)
                                TextField("Hvilken løsning ønsker du?", text: $desired, axis: .vertical).lineLimit(2...4)
                                TextField("Ordre-/købsreference, hvis du har den", text: $reference)
                                FadedPrimaryButton("Gem sagen og find dokumentationen", icon: "folder.badge.plus") { create() }
                                    .disabled(api == nil || busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                              problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                              title.count > 160 || merchant.count > 160 || problem.count > 3000 || desired.count > 1000 || reference.count > 200)
                            }.padding(.top, 12)
                        }
                    }.disabled(busy)
                    if !cases.isEmpty { Text("Dine sager").font(.headline) }
                    ForEach(cases) { record in
                        Button { selected = record } label: {
                            FadedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: record.state == "closed" ? "checkmark.seal" : record.state == "reply" ? "envelope.badge" : "folder")
                                        Text(record.title).font(.headline)
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                    Text(record.stateTitle).font(.subheadline)
                                    if !record.merchant.isEmpty { Text(record.merchant).font(.caption).foregroundStyle(.secondary) }
                                    Text(record.note).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                    }
                    if api == nil { Text("Forbind din PC, så agenten kan gemme sagen og bruge din Gmail gennem Composio.") }
                    if busy { ProgressView("Gemmer sagen…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .standard) }
            .navigationTitle("Få det ordnet").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Opdatér sager", systemImage: "arrow.clockwise") { Task { await load() } }
                        .labelStyle(.iconOnly).disabled(busy || api == nil)
                }
            }
            .sheet(item: $selected, onDismiss: { Task { await load() } }) { record in
                if let api { AgentCaseDetails(api: api, bot: bot, record: record, onResult: onResult) }
            }
            .task {
                if !initialized {
                    initialized = true
                    let overview = prompt.lowercased().range(of: #"^(?:vis|åbn) (?:mine )?sager\b"#, options: .regularExpression) != nil
                    problem = overview ? "" : String(prompt.prefix(3000))
                    title = overview ? "" : String(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                    await load()
                    if overview || (!cases.isEmpty && prompt.isEmpty) { formOpen = false }
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func load() async {
        guard let api else { return }
        do {
            struct Library: Decodable { let cases: [AgentCaseRecord] }
            let result: Library = try await api.moduleJSON("agent-cases", query: [.init(name: "bot_id", value: bot.id.uuidString)])
            cases = result.cases
        } catch { notice = (error as? APIError)?.title ?? "Dine sager kunne ikke hentes fra PC’en." }
    }

    private func create() {
        guard let api, !busy else { return }
        busy = true
        notice = nil
        let requestID = creation.requestID(for: [title, merchant, problem, desired, reference])
        let body: [String: Any] = ["action": "create", "title": title, "merchant": merchant,
                                   "problem": problem, "desired": desired, "reference": reference]
        Task { @MainActor in
            defer { busy = false }
            do {
                let record: AgentCaseRecord = try await api.caseAction(requestID.uuidString, body: body, bot: bot.id)
                creation.confirmed()
                selected = record
                formOpen = false
                await load()
            } catch { notice = (error as? APIError)?.title ?? "Sagen kunne ikke gemmes. Dine oplysninger bliver stående her." }
        }
    }
}
