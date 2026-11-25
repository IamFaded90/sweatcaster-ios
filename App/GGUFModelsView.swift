import SwiftUI
import UniformTypeIdentifiers

@MainActor struct GGUFModelsView: View {
    private let featured: PhoneModels.Entry?
    private let canStart: Bool
    private let showsModelLink: Bool
    init(featured: PhoneModels.Entry? = nil, canStart: Bool = true, showsModelLink: Bool = true) {
        self.featured = featured
        self.canStart = canStart
        self.showsModelLink = showsModelLink
    }
    @AppStorage(AppStorageKeys.phoneModel) private var selected = "apple"
    @AppStorage(AppStorageKeys.phoneModelFavorites) private var savedFavorites = ""
    @Environment(\.fadedPalette) private var palette
    @State private var models: [GGUFPhoneModel] = []
    @State private var importing = false
    @State private var working = false
    @State private var notice: String?
    @State private var query = ""
    @State private var repositories: [GGUFHub.Repository] = []
    @State private var files: [GGUFHub.File] = []
    @State private var downloadChoice: GGUFHub.File?
    @State private var deletionChoice: GGUFPhoneModel?
    @State private var keyDraft = ""
    @State private var showKey = false
    @State private var lookingUp = false

    private var downloads: GGUFModelDownloads { .shared }
    private var favorites: Set<String> { Set(savedFavorites.split(separator: "|").map(String.init)) }
    private var sortedModels: [GGUFPhoneModel] {
        models.filter { favorites.contains($0.id) } + models.filter { !favorites.contains($0.id) }
    }

    var body: some View {
        Group {
            if let featured { catalogCard(featured) }
            else { browser }
        }
        .onAppear { reload(); downloads.activate() }
        .onChange(of: downloads.revision) { reload() }
        .confirmationDialog("Slet model?", isPresented: Binding(
            get: { deletionChoice != nil }, set: { if !$0 { deletionChoice = nil } }
        ), presenting: deletionChoice) { model in
            deletionActions(model)
        } message: { model in
            deletionMessage(model)
        }
    }

    private func catalogCard(_ entry: PhoneModels.Entry) -> some View {
        FadedCard(accent: selected == entry.selectionID ? palette.lime : nil) {
            VStack(alignment: .leading, spacing: 10) {
                if let model = models.first(where: { $0.id == entry.selectionID }) {
                    installedRow(model)
                } else {
                    HStack {
                        Label(entry.name, systemImage: "cpu").font(.headline)
                        Spacer()
                        Button("Favorit", systemImage: favorites.contains(entry.selectionID) ? "star.fill" : "star") { toggleFavorite(entry.selectionID) }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .accessibilityValue(favorites.contains(entry.selectionID) ? "Valgt" : "Ikke valgt")
                    }
                    FadedDetailText(entry.description)
                    if downloads.pending?.file.isCatalogMiniCPM == true {
                        GGUFTransferStatus()
                    } else {
                        FadedSecondaryButton("Hent MiniCPM5 · 688 MB", icon: "arrow.down.circle") { downloads.start(GGUFHub.miniCPM) }
                            .disabled(!canStart || downloads.pending != nil)
                        if downloads.noticeFile?.isCatalogMiniCPM == true, let message = downloads.notice, downloads.pending == nil {
                            FadedDetailText(message)
                        }
                    }
                }
                if let notice { FadedDetailText(notice) }
                if showsModelLink, let source = entry.modelCardURL { Link("Modelkort på Hugging Face", destination: source).font(.footnote) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.action) {
                installedSection
                searchSection
                if let notice { FadedDetailText(notice).accessibilityAddTraits(.updatesFrequently) }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("Ekstra iPhone-modeller")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let first = urls.first { importFile(first) }
        }
        .confirmationDialog("Hent model?", isPresented: Binding(
            get: { downloadChoice != nil }, set: { if !$0 { downloadChoice = nil } }
        ), presenting: downloadChoice) { file in
            Button("Hent modellen") { downloads.start(file) }
        } message: { file in
            Text("\(file.name) fylder \(ModelDiskStorage.gigabytes(file.bytes)).")
        }
        .sheet(isPresented: $showKey, onDismiss: { keyDraft = "" }) { keySheet }
    }

    private var installedSection: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("På din iPhone")
                FadedSecondaryButton("Importér GGUF fra Filer", icon: "folder") { importing = true }
                    .disabled(working || downloads.pending != nil)
                if working { ProgressView("Arbejder med modelfilen…") }
                ForEach(sortedModels) { model in installedRow(model) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func installedRow(_ model: GGUFPhoneModel) -> some View {
        let estimated = Int64(model.memoryEstimateMiB) * 1_048_576
        let hint = PhoneMemoryBudget.assess(model).explanation
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(model.name).font(FadedTypography.action).textSelection(.enabled)
            FadedDetailText("\(ModelDiskStorage.gigabytes(model.bytes)) lager · ca. \(ModelDiskStorage.gigabytes(estimated)) RAM")
            FadedDetailText(hint)
            HStack {
                Button(selected == model.id ? "Valgt" : "Brug model", systemImage: "checkmark") { selected = model.id }
                    .frame(minHeight: 44)
                    .disabled(selected == model.id)
                Spacer()
                Button(favorites.contains(model.id) ? "Fjern favorit" : "Gør til favorit",
                       systemImage: favorites.contains(model.id) ? "star.fill" : "star") { toggleFavorite(model.id) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                Button("Slet \(model.name)", systemImage: "trash", role: .destructive) { deletionChoice = model }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(working)
            }
        }
    }

    private var searchSection: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Hent fra Hugging Face")
                HStack {
                    TextField("Søg efter en model", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).onSubmit(search)
                    Button("Søg", systemImage: "magnifyingglass", action: search)
                        .frame(minHeight: 44)
                        .disabled(lookingUp || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                FadedSecondaryButton("Find Qwen3 1.7B", icon: "arrow.down.circle") { showFiles("Qwen/Qwen3-1.7B-GGUF") }
                    .disabled(lookingUp)
                if OfflineAgentModels.installedChat == nil {
                    FadedSecondaryButton("Qwen3 4B · samtale · 2,5 GB", icon: "arrow.down.circle") { downloadChoice = OfflineAgentModels.chat }
                        .disabled(lookingUp || downloads.pending != nil)
                }
                Button("Hugging Face-adgang", systemImage: "key") { showKey = true }
                    .frame(minHeight: 44)
                if lookingUp { ProgressView("Henter modelliste…") }
                ForEach(repositories) { repo in
                    Button(repo.id, systemImage: "folder") { showFiles(repo.id) }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(lookingUp)
                }
                GGUFTransferStatus()
                ForEach(files) { file in
                    Button {
                        downloadChoice = file
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(file.name, systemImage: "arrow.down.circle")
                            FadedDetailText(ModelDiskStorage.gigabytes(file.bytes))
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(downloads.pending != nil || working)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var keySheet: some View {
        NavigationStack {
            Form {
                SecureField("Læsenøgle fra Hugging Face", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("Opret eller find en læsenøgle", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                Button("Gem nøglen") {
                    do { try GGUFHubKey.save(keyDraft); showKey = false }
                    catch { notice = "Nøglen kunne ikke gemmes. Brug en Hugging Face-nøgle, der begynder med hf_."; showKey = false }
                }
                .disabled(keyDraft.isEmpty)
                Button("Fjern nøglen", role: .destructive) { GGUFHubKey.remove(); showKey = false }
            }
            .navigationTitle("Hugging Face-adgang")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { showKey = false } }
        }
    }

    private func reload() {
        models = GGUFPhoneModel.installed
        if let featured, featured.id != featured.selectionID, favorites.contains(featured.id) {
            savedFavorites = favorites.subtracting([featured.id]).union([featured.selectionID]).sorted().joined(separator: "|")
        }
    }

    private func search() {
        let value = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !lookingUp, !value.isEmpty else { return }
        lookingUp = true
        notice = nil
        files = []
        repositories = []
        Task {
            defer { lookingUp = false }
            do {
                repositories = try await GGUFHub.search(value)
                if repositories.isEmpty { notice = "Ingen modeller matchede søgningen." }
            } catch { notice = (error as? GGUFHub.Failure)?.message ?? GGUFHub.Failure.request.message }
        }
    }

    private func showFiles(_ repository: String) {
        guard !lookingUp else { return }
        lookingUp = true
        files = []
        notice = nil
        Task {
            defer { lookingUp = false }
            do {
                files = try await GGUFHub.files(in: repository)
                if files.isEmpty { notice = "Modellen har ingen GGUF-filer, som kan hentes enkeltvis." }
            } catch { notice = (error as? GGUFHub.Failure)?.message ?? GGUFHub.Failure.request.message }
        }
    }

    private func importFile(_ url: URL) {
        guard !working else { return }
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) { try GGUFPhoneModel.importFile(url) }.value
                downloads.notifyCatalogChange()
                notice = "Modellen er importeret."
            } catch APIError.storage {
                notice = "Der er for lidt ledig plads. Frigør plads til modelfilen, og prøv igen."
            } catch {
                notice = "Modellen kunne ikke åbnes. Vælg én komplet GGUF-tekstmodel."
            }
        }
    }

    private func toggleFavorite(_ id: String) {
        var updated = favorites
        if !updated.insert(id).inserted { updated.remove(id) }
        savedFavorites = updated.sorted().joined(separator: "|")
    }

    private func agents(using id: String) -> [VillageBot] {
        VillageBot.list(from: MigratedAppData.shared.villageBots).filter {
            UserDefaults.standard.string(forKey: PhoneModels.agentModelKey($0.id)) == id
        }
    }

    @ViewBuilder private func deletionActions(_ model: GGUFPhoneModel) -> some View {
        if selected == model.id || !agents(using: model.id).isEmpty {
            let replacements = PhoneModels.textOptions.filter { $0.id != model.id && PhoneModels.isReady($0.id) }
            if replacements.isEmpty {
                Button("Slet og fjern modelvalget", role: .destructive) { remove(model, replacement: nil) }
            } else {
                ForEach(replacements.prefix(8), id: \.id) { entry in
                    Button("Slet og skift til \(entry.name)", role: .destructive) { remove(model, replacement: entry.id) }
                }
            }
        } else {
            Button("Slet modellen", role: .destructive) { remove(model, replacement: nil) }
        }
    }

    private func deletionMessage(_ model: GGUFPhoneModel) -> Text {
        let names = agents(using: model.id).map(\.name).joined(separator: ", ")
        return Text(names.isEmpty ? model.name : "Disse agenter bruger modellen: \(names).")
    }

    private func remove(_ model: GGUFPhoneModel, replacement: String?) {
        working = true
        notice = nil
        Task {
            defer { working = false }
            do {
                try await LocalCompute.run(minimumMiB: 0) {
                    guard let current = GGUFPhoneModel.installed(id: model.id) else { return }
                    try FileManager.default.removeItem(at: current.url.deletingLastPathComponent())
                    if selected == model.id { selected = replacement ?? "apple" }
                    for bot in agents(using: model.id) {
                        UserDefaults.standard.set(replacement, forKey: PhoneModels.agentModelKey(bot.id))
                    }
                    if favorites.contains(model.id) { toggleFavorite(model.id) }
                }
                downloads.notifyCatalogChange()
            } catch {
                notice = "Modellen kunne ikke slettes. Prøv igen, når enheden er klar."
            }
        }
    }
}

@MainActor struct GGUFTransferStatus: View {
    private var downloads: GGUFModelDownloads { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let entry = downloads.pending {
                if downloads.interrupted {
                    Text("Afbrudt hentning · \(entry.file.name)").font(.subheadline)
                    Button("Fortsæt download", systemImage: "arrow.clockwise") { downloads.resume() }
                        .disabled(downloads.isPausing)
                        .frame(minHeight: 44)
                } else if let progress = downloads.progress {
                    ProgressView(entry.file.name, value: progress)
                } else { ProgressView("Klargør \(entry.file.name)…") }
                Button("Stop download", role: .cancel) { downloads.cancel() }.frame(minHeight: 44)
                if !downloads.interrupted {
                    Button(downloads.isPausing ? "Sætter på pause…" : "Pause download", systemImage: "pause.circle") { downloads.pause() }.frame(minHeight: 44).disabled(downloads.isPausing)
                }
            }
            if let message = downloads.notice { FadedDetailText(message) }
        }
    }
}
