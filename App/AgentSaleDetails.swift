import SwiftUI
import UIKit

@MainActor struct AgentSaleDetails: View {
    let api: LiveAPI
    let bot: VillageBot
    @State private var sale: AgentSale
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmPublish = false
    @State private var confirmRemove = false
    @State private var editing = false
    @State private var operatorGoal: String?
    @State private var operatorOpen = false
    @State private var buyer = ""
    @State private var message = ""
    @State private var amount = ""
    @State private var kind = "buyer"
    @State private var agreement = ""
    @State private var offerID = ""
    @State private var linkedURL = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    init(api: LiveAPI, bot: VillageBot, sale: AgentSale) {
        self.api = api
        self.bot = bot
        _sale = State(initialValue: sale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sale.title).font(.title3.bold())
                            Text(sale.stateTitle).font(.headline)
                            Text(sale.description)
                            Text("Annoncepris · " + AgentTraderaItem.money(sale.asking, sale.currency))
                            Text("Mindst · " + AgentTraderaItem.money(sale.minimum, sale.currency)).font(.subheadline)
                            Text(sale.shipping).foregroundStyle(.secondary)
                            if let note = sale.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                            Text("\(sale.photoCount) fotos · " + ByteCountFormatter.string(fromByteCount: Int64(sale.bytes), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if sale.photoCount > 0 { AgentSalePhotoPreview(api: api, sale: sale) }
                    if sale.state == "draft" {
                        FadedSecondaryButton("Ret kladde", icon: "pencil") { editing = true }
                        FadedPrimaryButton("Gør klar hos Tradera", icon: "shippingbox") { change("prepare") }
                    }
                    if sale.state == "ready" {
                        Text("Den viste annonce udgives til \(sale.priceSEK ?? 0) svenske kroner.").font(.headline)
                        FadedPrimaryButton("Udgiv annoncen", icon: "paperplane") { confirmPublish = true }
                    }
                    if let url = sale.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("Se annoncen på Tradera", systemImage: "arrow.up.right.square") }
                            .frame(minHeight: 44)
                    }
                    if sale.url == nil {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Har du oprettet annoncen i PC-vinduet?").font(.headline)
                                TextField("Indsæt annoncens Tradera-link", text: $linkedURL)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                FadedSecondaryButton("Knyt annoncen til sagen", icon: "link") {
                                    change("attach", extra: ["url": linkedURL])
                                }.disabled(linkedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    FadedSecondaryButton("Opdatér salgsstatus", icon: "arrow.clockwise") { change("refresh") }
                    FadedSecondaryButton("Arbejd i Tradera på PC’en", icon: "desktopcomputer") {
                        change("browser")
                    }
                    conversations
                    if !offers.isEmpty { agreementCard }
                    if sale.transactionID != nil {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Tradera har bekræftet salget").font(.headline)
                                if sale.paid != true {
                                    FadedSecondaryButton("Betalingen er modtaget", icon: "checkmark.seal") {
                                        change("fulfillment", extra: ["kind": "paid"])
                                    }
                                }
                                if sale.state != "shipped" {
                                    FadedSecondaryButton("Varen er sendt eller afhentet", icon: "shippingbox") {
                                        change("fulfillment", extra: ["kind": "shipped"])
                                    }
                                }
                            }
                        }
                    }
                    if busy { ProgressView("Arbejder på salgssagen…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    Button("Slet sagen og dens fotos fra FadedAI", systemImage: "trash", role: .destructive) {
                        confirmRemove = true
                    }.frame(minHeight: 44)
                }.disabled(busy).padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .navigationTitle("Salgssag").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .sheet(isPresented: $editing, onDismiss: { reload() }) {
                AgentSaleComposer(api: api, bot: bot, prompt: sale.description, existing: sale)
            }
            .sheet(isPresented: $operatorOpen) {
                AgentWindowHelp(api: api, botName: bot.name, prompt: operatorGoal ?? "Hjælp mig med denne Tradera-annonce.")
            }
            .confirmationDialog("Udgiv \(sale.title) til \(sale.priceSEK ?? 0) SEK?", isPresented: $confirmPublish,
                                titleVisibility: .visible) {
                Button("Ja, udgiv på Tradera") { change("publish") }
                Button("Annuller", role: .cancel) {}
            }
            .confirmationDialog("Slet den lokale sag og dens fotos? En udgivet annonce administreres på Tradera.",
                                isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Slet fra FadedAI", role: .destructive) { change("remove") }
                Button("Annuller", role: .cancel) {}
            }
            .task(id: sale.id) {
                repeat {
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    if !busy { await loadLatest() }
                } while !Task.isCancelled && phase == .active
            }
        }
    }

    private var offers: [AgentSale.Message] { sale.messages.filter { $0.kind == "offer" && $0.withinLimit == true } }

    private var conversations: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Køberdialog og tilbud").font(.headline)
                Text("Indsæt en køberbesked fra Tradera, eller brug agenten i PC-vinduet.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sale.messages) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.kind == "replyDraft" ? "Agentens svarkladde" :
                                (entry.buyer.isEmpty ? "Din note" : entry.buyer)).font(.subheadline.bold())
                        Text(entry.text).textSelection(.enabled)
                        if let amount = entry.amount {
                            Text(AgentTraderaItem.money(amount, sale.currency))
                            if entry.withinLimit == false { Text("Under din mindstepris").foregroundStyle(.orange) }
                        }
                        if entry.kind == "buyer" {
                            Button("Lav en svarkladde", systemImage: "text.bubble") {
                                change("reply", extra: ["messageID": entry.id.uuidString.lowercased()])
                            }.frame(minHeight: 44)
                        }
                        if entry.kind == "replyDraft" {
                            Button("Svar i Tradera-vinduet", systemImage: "desktopcomputer") {
                                change("browserReply", extra: ["messageID": entry.id.uuidString.lowercased()])
                            }.frame(minHeight: 44)
                        }
                        Text(entry.kind == "replyDraft" ? "Kladde klar til at sende." :
                                (entry.source == "gmail" ? "Bekræftet Tradera-mail via din Gmail." : "Indsat af dig fra køberdialogen."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                TextField("Køberens navn", text: $buyer)
                Picker("Type", selection: $kind) {
                    Text("Køberbesked").tag("buyer")
                    Text("Tilbud").tag("offer")
                    Text("Min note").tag("note")
                }
                TextField("Besked", text: $message, axis: .vertical).lineLimit(2...5)
                if kind == "offer" {
                    TextField("Tilbud i \(sale.currency)", text: $amount).keyboardType(.decimalPad)
                }
                FadedSecondaryButton("Gem i sagen", icon: "plus.bubble") {
                    var body: [String: Any] = ["kind": kind, "buyer": buyer, "text": message]
                    if kind == "offer" { body["amount"] = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0 }
                    change("message", extra: body)
                }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var agreementCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Aftal salget").font(.headline)
                Picker("Vælg et tilbud", selection: $offerID) {
                    Text("Vælg køber").tag("")
                    ForEach(offers) { entry in
                        Text(entry.buyer + " · " + AgentTraderaItem.money(entry.amount ?? 0, sale.currency))
                            .tag(entry.id.uuidString.lowercased())
                    }
                }
                TextField("Hvornår og hvordan overtages varen?", text: $agreement, axis: .vertical)
                FadedSecondaryButton("Gem aftalen", icon: "checkmark.bubble") {
                    change("agreement", extra: ["offerID": offerID, "agreement": agreement])
                }.disabled(offerID.isEmpty || agreement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let saved = sale.agreement { Text(saved).foregroundStyle(.secondary) }
            }
        }
    }

    private func openOperator(_ goal: String) {
        operatorGoal = goal
        operatorOpen = true
    }

    private func change(_ action: String, extra: [String: Any] = [:]) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let body = extra.merging(["action": action, "revision": sale.revision]) { _, new in new }
                if action == "remove" {
                    struct Removed: Decodable { let removed: Bool }
                    let _: Removed = try await api.saleAction("sales/" + sale.id.uuidString, body: body, bot: bot.id)
                    dismiss()
                } else {
                    sale = try await api.saleAction("sales/" + sale.id.uuidString, body: body, bot: bot.id)
                    if action == "message" { message = ""; amount = "" }
                    if ["browser", "browserReply"].contains(action), let goal = sale.browserGoal { openOperator(goal) }
                }
            } catch { notice = (error as? APIError)?.title ?? "Sagen kunne ikke opdateres. Prøv Opdatér salgsstatus." }
        }
    }

    private func reload() {
        Task { @MainActor in await loadLatest() }
    }

    private func loadLatest() async {
        struct Library: Decodable { let cases: [AgentSale] }
        if let result: Library = try? await api.moduleJSON("sales", query: [.init(name: "bot_id", value: bot.id.uuidString)]),
           !Task.isCancelled, let latest = result.cases.first(where: { $0.id == sale.id }) { sale = latest }
    }
}

@MainActor private struct AgentSalePhotoPreview: View {
    let api: LiveAPI
    let sale: AgentSale
    @State private var index = 0
    @State private var data: Data?

    var body: some View {
        VStack {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                    .accessibilityLabel("Salgsfoto \(index + 1)")
            }
            HStack {
                Button("Forrige foto", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                Spacer()
                Text("\(index + 1) / \(sale.photoCount)").font(.caption.monospacedDigit())
                Spacer()
                Button("Næste foto", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 >= sale.photoCount)
            }.labelStyle(.iconOnly).frame(minHeight: 44)
        }
        .task(id: index) {
            data = nil
            struct Photo: Decodable { let data: Data }
            let result: Photo? = try? await api.moduleJSON("sales/\(sale.id.uuidString)/photos/\(index)",
                query: [.init(name: "bot_id", value: sale.botID.uuidString)], maximumBytes: 4_000_000)
            if !Task.isCancelled { data = result?.data }
        }
    }
}
