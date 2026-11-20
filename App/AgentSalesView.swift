import PhotosUI
import SwiftUI
import UIKit

@MainActor struct AgentSalesView: View {
    let api: LiveAPI?
    let bot: VillageBot
    let prompt: String
    @Environment(\.dismiss) private var dismiss
    @State private var cases: [AgentSale] = []
    @State private var access: AgentSaleAccess?
    @State private var notice: String?
    @State private var refresh = 0
    @State private var creating = false
    @State private var connecting = false
    @State private var selected: AgentSale?

    init(api: LiveAPI?, bot: VillageBot, prompt: String = "") {
        self.api = api
        self.bot = bot
        self.prompt = prompt
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        VillageBotAvatar(bot: bot, size: 52, radius: 14)
                        VStack(alignment: .leading) {
                            Text(bot.name + " sælger for dig").font(.title3.bold())
                            Text("Annoncer, tilbud og aftaler samlet.").foregroundStyle(.secondary)
                        }
                    }
                    if let api {
                        FadedPrimaryButton("Nyt salg", icon: "plus") { creating = true }
                        FadedSecondaryButton(access?.authorized == true ? "Tradera · Forbundet" : "Forbind Tradera",
                                             icon: "link") { connecting = true }
                        ForEach(cases) { sale in
                            Button { selected = sale } label: {
                                FadedCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(sale.title).font(.headline)
                                        Text(sale.stateTitle).font(.subheadline)
                                        Text(AgentTraderaItem.money(sale.asking, sale.currency))
                                            .foregroundStyle(.secondary)
                                        if let note = sale.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                        if cases.isEmpty { Text("Tag billeder, skriv din mindstepris, og lad os gøre salget klar.") }
                        FadedSecondaryButton("Brug Tradera på PC’en", icon: "desktopcomputer") {
                            selected = nil
                            operatorOpen = true
                        }
                        .sheet(isPresented: $operatorOpen) {
                            AgentWindowHelp(api: api, botName: bot.name,
                                            prompt: "Hjælp mig med at oprette min annonce på Tradera i mit valgte vindue.")
                        }
                    } else {
                        Text("Forbind til FadedAI på din PC for at bruge salgsagenten.")
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .navigationTitle("Salgsagent").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Opdatér", systemImage: "arrow.clockwise") { refresh += 1 }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $creating, onDismiss: { refresh += 1 }) {
                if let api { AgentSaleComposer(api: api, bot: bot, prompt: prompt) }
            }
            .sheet(isPresented: $connecting, onDismiss: { refresh += 1 }) {
                if let api { AgentSaleConnection(api: api, access: access) }
            }
            .sheet(item: $selected, onDismiss: { refresh += 1 }) { sale in
                if let api { AgentSaleDetails(api: api, bot: bot, sale: sale) }
            }
            .task(id: refresh) { await load() }
        }
    }

    @State private var operatorOpen = false

    private func load() async {
        guard let api else { return }
        do {
            struct Library: Decodable { let cases: [AgentSale]; let access: AgentSaleAccess }
            let result: Library = try await api.moduleJSON("sales", query: [.init(name: "bot_id", value: bot.id.uuidString)])
            try Task.checkCancellation()
            cases = result.cases
            access = result.access
            notice = nil
        } catch is CancellationError { return }
        catch { notice = (error as? APIError)?.title ?? "PC’en kunne ikke hente salgssagerne." }
    }
}

@MainActor struct AgentSaleComposer: View {
    let api: LiveAPI
    let bot: VillageBot
    let prompt: String
    let existing: AgentSale?
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    @State private var title = ""
    @State private var details = ""
    @State private var minimum = ""
    @State private var asking = ""
    @State private var currency = "DKK"
    @State private var shipping = "Afhentning efter aftale"
    @State private var categoryID = 0
    @State private var bidderID = 0
    @State private var providerID = 0
    @State private var shippingCost = ""
    @State private var catalog: AgentSaleCatalog?
    @State private var attributes: [AgentSaleAttributes.Field] = []
    @State private var terms: [Int: String] = [:]
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var busy = false
    @State private var loadingPhotos = false
    @State private var watchMail = true
    @State private var priceNote: String?
    @State private var questions: [String] = []
    @State private var selectingCategory = false
    @State private var notice: String?

    init(api: LiveAPI, bot: VillageBot, prompt: String, existing: AgentSale? = nil) {
        self.api = api
        self.bot = bot
        self.prompt = prompt
        self.existing = existing
        if let existing {
            _id = State(initialValue: existing.id)
            _title = State(initialValue: existing.title)
            _details = State(initialValue: existing.description)
            _minimum = State(initialValue: String(existing.minimum))
            _asking = State(initialValue: String(existing.asking))
            _currency = State(initialValue: existing.currency)
            _shipping = State(initialValue: existing.shipping)
            _categoryID = State(initialValue: existing.categoryID)
            _bidderID = State(initialValue: existing.bidderID)
            _terms = State(initialValue: Dictionary(existing.attributes.map { ($0.id, $0.values.first ?? "") }, uniquingKeysWith: { a, _ in a }))
            if let option = existing.shippingOptions.first {
                _providerID = State(initialValue: option.shippingProviderId)
                _shippingCost = State(initialValue: String(option.cost))
            }
        }
    }

    private var lowest: Double { Double(minimum.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var price: Double { Double(asking.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var categoryName: String {
        catalog?.categories.flatMap { $0.leaves() }.first { $0.0 == categoryID }?.1 ?? "Vælg kategori til udgivelsen"
    }

    var body: some View {
        NavigationStack {
            presentedForm
            .task {
                if title.isEmpty && prompt.lowercased().range(of: #"\bsælg(?:e)?\b"#, options: .regularExpression) != nil {
                    details = prompt
                    title = prompt.replacingOccurrences(of: #"(?i)^(?:(?:kan|vil) du )?sælg(?:e)?\s+"#,
                                                         with: "", options: .regularExpression)
                        .components(separatedBy: "mindst").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if title.lowercased().hasPrefix("den her") || title.lowercased().hasPrefix("det her") { title = "" }
                    let seed = AgentTraderaIntent.limit(in: prompt)
                    minimum = seed.amount
                    asking = seed.amount
                    if !seed.currency.isEmpty { currency = seed.currency }
                }
                catalog = try? await api.moduleJSON("sales/catalog", timeout: 25)
            }
            .task(id: categoryID) {
                guard categoryID != 0 else { return }
                let reply: AgentSaleAttributes? = try? await api.moduleJSON("sales/catalog",
                    query: [.init(name: "category_id", value: String(categoryID))])
                if !Task.isCancelled { attributes = reply?.attributes ?? [] }
            }
            .onChange(of: categoryID) { _, _ in terms = [:] }
            .task(id: selectedPhotos) { await loadPhotos() }
        }
    }

    private var saleForm: some View {
        Form {
            itemSection
            priceSection
            traderaSection
            saveSection
        }
    }

    private var presentedForm: some View {
        saleForm
            .scrollContentBackground(.hidden).background { FadedBackground() }
            .navigationTitle("Nyt salg").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .sheet(isPresented: $selectingCategory) {
                AgentSaleCategoryPicker(categories: catalog?.categories ?? [], selection: $categoryID)
            }
    }

    private var itemSection: some View {
        Section("Det sælger du") {
            TextField("Hvad er det? Model og navn", text: $title)
            TextField("Stand, tilbehør og oplysninger til køberen", text: $details, axis: .vertical).lineLimit(4...8)
            FadedSecondaryButton("Lad agenten foreslå annonceteksten", icon: "sparkles") { suggestText() }
                .disabled(busy || loadingPhotos || (details.isEmpty && title.isEmpty && photos.isEmpty))
            ForEach(questions, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            if existing == nil {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 8, matching: .images) {
                Label("Vælg fotos · \(photos.count)/8", systemImage: "photo.on.rectangle")
                }
            } else {
                Text("\(existing?.photoCount ?? 0) fotos er gemt på PC’en.")
            }
            if loadingPhotos { ProgressView("Gør billederne klar…") }
            if !photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(photos.indices, id: \.self) { index in
                            if let image = UIImage(data: photos[index]) {
                                VStack {
                                    Image(uiImage: image).resizable().scaledToFit().frame(width: 100, height: 100)
                                    Button("Fjern foto \(index + 1)", systemImage: "trash", role: .destructive) {
                                        photos.remove(at: index)
                                    }.labelStyle(.iconOnly).frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var priceSection: some View {
        Section("Dine rammer") {
            TextField("Mindstepris", text: $minimum).keyboardType(.decimalPad)
            TextField("Annoncepris", text: $asking).keyboardType(.decimalPad)
            Picker("Valuta", selection: $currency) {
                Text("Danske kroner").tag("DKK")
                Text("Svenske kroner").tag("SEK")
            }
            if catalog != nil {
                Button("Foreslå en pris fra lignende salg på Tradera") { suggestPrice() }
                    .disabled(busy || categoryID == 0 || title.count < 3)
            }
            if let priceNote { Text(priceNote).font(.caption).foregroundStyle(.secondary) }
            TextField("Afhentning eller levering", text: $shipping, axis: .vertical)
            if existing == nil {
                Toggle("Følg Traderas køberbeskeder i min forbundne Gmail", isOn: $watchMail)
            }
            Text("Tradera udgiver i svenske kroner. Du får den omregnede pris at se før udgivelsen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var traderaSection: some View {
        if let catalog {
            Section("Tradera-annonce") {
                Button(categoryName) { selectingCategory = true }
                Picker("Hvem må købe?", selection: $bidderID) {
                    Text("Vælg område").tag(0)
                    ForEach(catalog.bidders) { Text($0.description ?? "Område").tag($0.id) }
                }
                Picker("Fragtfirma", selection: $providerID) {
                    Text("Kun oplysningerne ovenfor").tag(0)
                    ForEach(catalog.shipping) { Text($0.name).tag($0.id) }
                }
                if providerID != 0 {
                    TextField("Fragtpris i svenske kroner", text: $shippingCost).keyboardType(.numberPad)
                }
                ForEach(attributes.filter { !($0.possibleTermValues ?? []).isEmpty }) { field in
                    Picker((field.name ?? "Egenskab") + ((field.minNumberOfValues ?? 0) > 0 ? " *" : ""),
                           selection: Binding(get: { terms[field.id] ?? "" }, set: { terms[field.id] = $0 })) {
                        Text("Vælg").tag("")
                        ForEach(field.possibleTermValues ?? [], id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        }
    }

    private var saveSection: some View {
        Section {
            Button("Gem salgskladde") { save() }.buttonStyle(FadedButtonStyle(kind: .primary))
                .disabled(busy || loadingPhotos || title.trimmingCharacters(in: .whitespaces).isEmpty ||
                          details.trimmingCharacters(in: .whitespaces).isEmpty || lowest <= 0 || price < lowest)
            if busy { ProgressView("Gemmer på PC’en…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
    }

    private func loadPhotos() async {
        loadingPhotos = true
        defer { if !Task.isCancelled { loadingPhotos = false } }
        var values: [Data] = []
        for item in selectedPhotos {
            do {
                if let loaded = try await item.loadTransferable(type: AgentSalePhoto.self) { values.append(loaded.jpeg) }
                try Task.checkCancellation()
            } catch is CancellationError { return }
            catch { notice = "Et foto kunne ikke åbnes. Prøv et andet." }
        }
        if !Task.isCancelled { photos = values }
    }

    private func save() {
        busy = true
        var body: [String: Any] = [
            "action": existing == nil ? "create" : "edit", "title": title, "description": details, "minimum": lowest, "asking": price,
            "currency": currency, "categoryID": categoryID, "bidderID": bidderID, "shipping": shipping,
            "watchMail": watchMail,
            "attributes": terms.filter { !$0.value.isEmpty }.map { ["id": $0.key, "values": [$0.value]] as [String: Any] },
            "shippingOptions": providerID == 0 ? [] : [["shippingProviderId": providerID, "cost": Int(shippingCost) ?? 0]],
            "photos": photos.map { $0.base64EncodedString() }
        ]
        if let existing { body["revision"] = existing.revision }
        Task { @MainActor in
            defer { busy = false }
            do {
                let _: AgentSale = try await api.saleAction("sales/" + id.uuidString, body: body, bot: bot.id)
                dismiss()
            } catch { notice = (error as? APIError)?.title ?? "Salgskladden kunne ikke gemmes." }
        }
    }

    private func suggestPrice() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                struct Suggestion: Decodable { let displaySuggested: Double?; let displayCurrency: String }
                let result: Suggestion = try await api.moduleJSON("sales/price", query: [
                    .init(name: "title", value: title), .init(name: "category_id", value: String(categoryID)),
                    .init(name: "currency", value: currency)
                ])
                if let value = result.displaySuggested {
                    priceNote = "Traderas forslag · " + AgentTraderaItem.money(value, result.displayCurrency)
                    asking = String(max(value, lowest))
                } else { priceNote = "Tradera har for få lignende salg til at foreslå en pris." }
            } catch { notice = (error as? APIError)?.title ?? "Prisforslaget kunne ikke hentes." }
        }
    }

    private func suggestText() {
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                struct Draft: Decodable { let title, description: String; let questions: [String] }
                var body = ["prompt": prompt, "title": title, "description": details]
                if let first = photos.first { body["photo"] = first.base64EncodedString() }
                let result: Draft = try await api.moduleJSON("sales/draft",
                    upload: JSONEncoder().encode(body), timeout: 190)
                title = result.title
                details = result.description
                questions = result.questions
            } catch { notice = (error as? APIError)?.title ?? "Agenten kunne ikke foreslå en annoncetekst." }
        }
    }
}

private struct AgentSaleCategoryPicker: View {
    let categories: [AgentSaleCatalog.Category]
    @Binding var selection: Int
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories.flatMap { $0.leaves() }.filter {
                    search.isEmpty || $0.1.localizedCaseInsensitiveContains(search)
                }, id: \.0) { id, name in
                    Button(name) { selection = id; dismiss() }
                }
            }.searchable(text: $search, prompt: "Find kategori")
                .navigationTitle("Kategori")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}
