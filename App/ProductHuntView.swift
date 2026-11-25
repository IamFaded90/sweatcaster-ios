import SwiftUI
import UIKit

@MainActor struct ProductHuntView: View {
    let bot: VillageBot
    let api: LiveAPI?
    let model: String
    let initialQuery: String
    let initialPhoto: Data?
    var onResult: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var hunt: ProductHunt
    @State private var photo: Data?
    @State private var selectedPhoto: Data?
    @State private var picking = false
    @State private var cropOpen = false
    @State private var loaded = false
    @State private var busy = false
    @State private var progress = ""
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    init(bot: VillageBot, api: LiveAPI?, model: String, query: String = "", photo: Data? = nil,
         onResult: @escaping (String) -> Void = { _ in }) {
        self.bot = bot; self.api = api; self.model = model
        initialQuery = query; initialPhoto = photo; self.onResult = onResult
        _hunt = State(initialValue: .init(botID: bot.id))
    }
    private var storage: ProductHunt.Store { .init(botID: bot.id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Find det, du faldt for").font(.title2.bold())
                    Text("Markér en ting på dit foto, eller beskriv den. Du får mulige fund, som du kan kontrollere og gemme.").foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ChatPhotoPicker(photo: $photo, loading: $picking, onError: { notice = $0 },
                                addTitle: "Vælg et foto", replaceTitle: "Skift foto")
                            if let data = selectedPhoto ?? photo, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 190).clipShape(RoundedRectangle(cornerRadius: 16))
                                HStack {
                                    Button("Markér tingen", systemImage: "crop") { cropOpen = true }
                                    Spacer()
                                    Button("Slet foto", systemImage: "trash", role: .destructive) {
                                        do { try storage.savePhoto(nil); photo = nil; selectedPhoto = nil }
                                        catch { notice = "Fotoet kunne ikke slettes." }
                                    }
                                }.frame(minHeight: 44)
                            }
                            TextField("Hvad leder du efter? Fx grøn lænestol i velour", text: $hunt.query, axis: .vertical)
                                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                            if !hunt.observations.isEmpty {
                                DisclosureGroup("Forslaget fra billedet") { Text(hunt.observations).font(.caption).textSelection(.enabled) }
                            }
                            FadedPrimaryButton(photo == nil ? "Find produkter" : "Find det markerede", icon: "sparkle.magnifyingglass") { search() }
                                .disabled(!loaded || busy || picking || (photo == nil && hunt.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                            if photo != nil && !hunt.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button("Søg på min beskrivelse uden billedanalyse") { search(readPhoto: false) }.frame(minHeight: 44)
                            }
                            Text("Billedanalysen foregår på iPhone, når en billedmodel er klar. Ellers kan din parrede PC bruges. Søgning og forhandlerpriser kræver internet.").font(.caption).foregroundStyle(.secondary)
                        }.disabled(busy)
                    }
                    if busy { ProgressView(progress); Button("Stop søgningen") { operation?.cancel() }.frame(minHeight: 44) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                    if !hunt.matches.isEmpty {
                        Text("Mulige fund").font(.title3.bold())
                        Text("Priser er varepriser uden ukendt fragt. Valutaer sammenlignes hver for sig. Kontrollér størrelse og variant hos forhandleren.").font(.caption).foregroundStyle(.secondary)
                        comparison
                        ForEach(hunt.matches) { match in card(match, result: true) }
                        FadedSecondaryButton("Gem fundene i chatten", icon: "checkmark.bubble") {
                            onResult(hunt.matches.map { "\($0.title) · \($0.price?.formatted ?? "pris ikke kontrolleret")\n\($0.url.absoluteString)" }.joined(separator: "\n\n"))
                            dismiss()
                        }
                    }
                    if !hunt.favorites.isEmpty {
                        Text("Dine gemte fund").font(.title3.bold())
                        ForEach(hunt.favorites) { match in card(match, result: false) }
                    }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Find fra et billede").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Slet søgning og alle fund", systemImage: "trash", role: .destructive) {
                            do { try storage.remove(); hunt = .init(botID: bot.id); photo = nil; selectedPhoto = nil; loaded = true }
                            catch { notice = "Fundene kunne ikke slettes." }
                        }.disabled(busy || !loaded)
                    }
                }
                .onAppear(perform: load).onDisappear { operation?.cancel() }
                .onChange(of: photo) { _, data in
                    selectedPhoto = nil
                    guard loaded else { return }
                    do { if let data { let normalized = try AgentRoomImages.sketch(data); try storage.savePhoto(normalized) } }
                    catch { notice = "Fotoet kunne ikke gemmes. Vælg et mindre foto." }
                }
                .sheet(isPresented: $cropOpen) {
                    if let photo, let small = try? AgentRoomImages.sketch(photo), let image = UIImage(data: small) {
                        ProductCropView(image: image) { data in
                            selectedPhoto = data; hunt.observations = ""; hunt.query = ""
                        }
                    }
                }
                .onChange(of: hunt.query) { _, text in if text.count > 500 { hunt.query = String(text.prefix(500)) } }
        }
    }
    private func card(_ match: ProductHunt.Match, result: Bool) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(match.title).font(.headline)
                Label(match.identityConfirmed ? "Bekræftet af dig" : "Muligt match", systemImage: match.identityConfirmed ? "checkmark.seal" : "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let price = match.price {
                    Text(price.formatted).font(.title3.bold())
                    Text("Varepris læst \(price.checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else { Text("Prisen kunne ikke kontrolleres for én bestemt variant.").font(.caption).foregroundStyle(.secondary) }
                if !match.evidence.isEmpty { DisclosureGroup("Kilde til prisen") { Text(match.evidence).font(.caption).textSelection(.enabled) } }
                Link("Åbn \(match.url.host ?? "forhandleren")", destination: match.url).frame(minHeight: 44)
                Button("Kontrollér prisen igen", systemImage: "arrow.clockwise") { refreshPrice(match) }.frame(minHeight: 44).disabled(busy)
                HStack {
                    Button(hunt.favorites.contains(where: { $0.id == match.id }) ? "Fjern favorit" : "Gem favorit", systemImage: "heart") { hunt.favorite(match); save() }
                    if result { Button(match.identityConfirmed ? "Fortryd match" : "Det er den", systemImage: "checkmark") { hunt.confirm(match.id); save() } }
                }.buttonStyle(.bordered).disabled(busy)
            }
        }
    }
    private func load() {
        guard !loaded else { return }
        do {
            hunt = try storage.load(); photo = try storage.photo(); loaded = true
            if let initialPhoto { photo = try AgentRoomImages.sketch(initialPhoto); try storage.savePhoto(photo) }
            if !initialQuery.isEmpty { hunt.query = String(initialQuery.prefix(500)) }
        } catch { notice = "De gemte fund kunne ikke læses. De bliver ikke overskrevet. " + error.localizedDescription }
    }
    private func save() {
        guard loaded else { return }
        do { hunt.updated = .now; try storage.save(hunt) }
        catch { notice = "Ændringen kunne ikke gemmes." }
    }
    private func search(readPhoto: Bool = true) {
        guard !busy, loaded else { return }
        busy = true; notice = nil
        operation = Task {
            defer { busy = false }
            do {
                if readPhoto, let data = selectedPhoto ?? photo {
                    progress = "\(bot.name) kigger på det markerede…"
                    let instruction = "Beskriv kun den synlige ting, som skal findes i en butik. Svar kun med en kort søgefrase på højst 180 tegn: varetype, synlig farve, materiale og eventuelt læsbart mærke/model. Gæt ikke et mærke. Ønsker: " + String(hunt.query.prefix(300))
                    let pc = PhoneModels.preferredVisionModel(preferred: model) == nil ? api : nil
                    let result = try await AgentChatPhotoReply.answer(data, question: instruction, agent: bot.name, language: "da-DK", pc: pc, preferredModel: model)
                    try Task.checkCancellation()
                    hunt.observations = String(result.text.prefix(4_000))
                    if result.model == "Billedtekst" {
                        notice = "Jeg kunne kun læse billedtekst. Beskriv varen i søgefeltet og søg uden foto, eller gør en billedmodel klar."; save(); return
                    }
                    hunt.query = String(result.text.replacingOccurrences(of: "\n", with: " ").prefix(220))
                }
                progress = "Finder mulige produkter…"
                let sources = try await AgentInternetTools.research(query: String(hunt.query.prefix(440)) + " køb pris Danmark", api: api)
                try Task.checkCancellation()
                var found: [ProductHunt.Match] = []
                var seen = Set<URL>()
                for source in sources.sources.prefix(5) where ProductHunt.publicURL(source.url) && seen.insert(source.url).inserted {
                    progress = "Kontrollerer priser · \(found.count + 1)…"
                    var match = ProductHunt.Match(title: String(source.title.prefix(350)), url: source.url)
                    do {
                        if let offer = try await ProductHuntPage.offer(at: source.url) {
                            match.title = offer.title
                            match.price = .init(amount: offer.amount, currency: offer.currency, checked: .now)
                            match.evidence = String(("Forhandlerens Product/Offer-data: \(offer.title) · \(offer.amount) \(offer.currency)\n" + source.url.absoluteString).prefix(1_500))
                            match.checked = .now
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* A search result remains usable; an unreadable price stays unknown. */ }
                    try Task.checkCancellation(); found.append(match)
                }
                hunt.matches = found; save()
                if found.isEmpty { notice = "Ingen brugbare produktlinks denne gang. Prøv et mere konkret varenavn." }
            } catch { if !Task.isCancelled { notice = "Søgningen kunne ikke afsluttes. Dit foto og dine gemte fund er bevaret. " + error.localizedDescription } }
        }
    }
    @ViewBuilder private var comparison: some View {
        let priced = hunt.matches.filter { $0.price != nil }
        if priced.count > 1 {
            FadedCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sammenlign varepriser").font(.headline)
                    ForEach(Array(Set(priced.compactMap { $0.price?.currency })).sorted(), id: \.self) { currency in
                        ForEach(priced.filter { $0.price?.currency == currency }.sorted { ($0.price?.amount ?? 0) < ($1.price?.amount ?? 0) }) { item in
                            HStack { Text(item.title).lineLimit(2); Spacer(); Text(item.price?.formatted ?? "").bold() }.font(.subheadline)
                        }
                    }
                }
            }
        }
    }
    private func refreshPrice(_ item: ProductHunt.Match) {
        guard !busy else { return }
        busy = true; progress = "Kontrollerer forhandlerens pris…"; notice = nil
        operation = Task {
            defer { busy = false }
            do {
                let offer = try await ProductHuntPage.offer(at: item.url)
                try Task.checkCancellation()
                var updated = item; updated.checked = .now
                updated.price = offer.map { .init(amount: $0.amount, currency: $0.currency, checked: .now) }
                updated.evidence = offer.map { "Forhandlerens Product/Offer-data: \($0.title) · \($0.amount) \($0.currency)" } ?? ""
                if let index = hunt.matches.firstIndex(where: { $0.id == item.id }) { hunt.matches[index] = updated }
                if let index = hunt.favorites.firstIndex(where: { $0.id == item.id }) { hunt.favorites[index] = updated }
                save()
                if offer == nil { notice = "Prisen kunne ikke bekræftes for én variant. Det gamle prisfelt er ryddet, så det ikke ligner et nyt opslag." }
            } catch { if !Task.isCancelled { notice = "Kunne ikke kontrollere prisen nu. Den gemte pris har stadig sit gamle tidspunkt." } }
        }
    }
}

@MainActor private struct ProductCropView: View {
    let image: UIImage
    let selected: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var crop: ProductHunt.Crop?
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Træk en ramme om den ting, du vil finde.").padding(.horizontal)
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().scaledToFit()
                        if let crop {
                            Rectangle().stroke(FadedBrand.mint, lineWidth: 3)
                                .background(FadedBrand.mint.opacity(0.12))
                                .frame(width: geometry.size.width * crop.width, height: geometry.size.height * crop.height)
                                .offset(x: geometry.size.width * crop.x, y: geometry.size.height * crop.y)
                        }
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2).onChanged {
                        crop = ProductHunt.Crop.selection(from: $0.startLocation, to: $0.location, size: geometry.size)
                    })
                }.aspectRatio(image.size.width / max(1, image.size.height), contentMode: .fit).padding()
                Button("Brug hele fotoet") { crop = nil }
                FadedPrimaryButton("Brug markeringen", icon: "checkmark") { apply() }.padding(.horizontal)
                Spacer(minLength: 0)
            }.background { FadedBackground() }.navigationTitle("Markér tingen")
                .toolbar { Button("Annuller") { dismiss() } }
        }
    }
    private func apply() {
        let size = image.size
        let normalized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let c = crop ?? .init(x: 0, y: 0, width: 1, height: 1)
        guard let cg = normalized.cgImage, let part = cg.cropping(to: CGRect(
            x: Double(cg.width) * c.x, y: Double(cg.height) * c.y,
            width: Double(cg.width) * c.width, height: Double(cg.height) * c.height)),
              let data = UIImage(cgImage: part).jpegData(compressionQuality: 0.88) else { return }
        selected(data); dismiss()
    }
}
