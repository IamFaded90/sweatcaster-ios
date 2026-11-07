import MediaGenerationKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

private struct PrivateChatTurn: Codable, Identifiable {
    var id = UUID()
    let prompt: String
    var reply: String
    var imageName: String? = nil
    var source: String? = nil
}

struct OfflineStudio: View {
    let api: LiveAPI?
    @Binding var sessionUnlocked: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("offline.studio.enabled") private var enabled = false
    @AppStorage("phone.model") private var textModel = "apple"
    @AppStorage("offline.studio.lora") private var loraName = ""
    @AppStorage("village.bots") private var botData = Data()
    @AppStorage("private.bot.id") private var privateBotID = ""
    @State private var showModels = false
    @State private var showBotBuilder = false
    @State private var importLoRA = false
    @State private var prompt = ""
    @State private var answer = ""
    @State private var status = ""
    @State private var imageURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var imageModel = "sd_v1.5_f16.ckpt"
    @State private var useLoRA = false
    @State private var authenticating = false
    @State private var showHistory = false
    @State private var downloadProgress: Double?
    @State private var turns: [PrivateChatTurn] = []
    @State private var loaded = false
    @State private var pendingImageDeletion: URL?
    @FocusState private var promptFocused: Bool

    private var historyFolder: URL { URL.applicationSupportDirectory.appending(path: "StudioImages", directoryHint: .isDirectory) }
    private var privateBots: [VillageBot] { (try? JSONDecoder().decode([VillageBot].self, from: botData)) ?? [] }
    private var selectedPrivateBot: VillageBot? {
        privateBots.first { $0.id.uuidString == privateBotID } ?? privateBots.first
    }
    private var history: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: historyFolder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessionUnlocked {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                privateHeader
                                DisclosureGroup("Private indstillinger") {
                                    privateSettings.padding(.top, 10)
                                }
                                if turns.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Din private bot er klar").font(.title2.bold())
                                        Text("Skriv en besked, eller beskriv et billede. Chat og billedhistorik bliver på telefonen. Billeder kan falde tilbage til din PC.")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(16).background(.pink.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                                }
                                ForEach(turns) { turn in privateTurn(turn) }
                                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.pink) }
                                if let downloadProgress {
                                    ProgressView(value: downloadProgress) { Text(downloadProgress.formatted(.percent)) }
                                }
                                Color.clear.frame(height: 1).id("private-bottom")
                            }.padding(16)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .defaultScrollAnchor(.bottom)
                        .safeAreaInset(edge: .bottom) { privateComposer }
                        .onChange(of: turns.count) { scrollPrivate(proxy) }
                        .onChange(of: answer) { scrollPrivate(proxy) }
                    }
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "faceid").font(.system(size: 56)).foregroundStyle(.pink)
                        Text("Privat bot").font(.largeTitle.bold())
                        Text("Lås op én gang. Studiet forbliver åbent, indtil FadedAI lukkes helt.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Lås op med Face ID") { authenticate() }
                            .buttonStyle(.borderedProminent).tint(.pink)
                            .frame(minHeight: 52).disabled(authenticating)
                    }.padding(24)
                }
            }
            .navigationTitle(sessionUnlocked ? "Privat bot" : "Privat område")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left") { task?.cancel(); dismiss() }
                }
                if sessionUnlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Ny chat", systemImage: "square.and.pencil") { newPrivateConversation() }
                            .disabled(task != nil)
                    }
                }
            }
            .sheet(isPresented: $showModels) { PhoneModelsView() }
            .sheet(isPresented: $showBotBuilder) { VillageBotBuilder() }
            .sheet(isPresented: $showHistory) {
                NavigationStack {
                    List(history, id: \.self) { file in
                        HStack {
                            Button {
                                imageURL = file
                                showHistory = false
                            } label: {
                            if let stamp = file.lastPathComponent.split(separator: "-").first,
                               let millis = Double(stamp) {
                                Text(Date(timeIntervalSince1970: millis / 1000), format: .dateTime.day().month().hour().minute())
                            } else { Text("Gemt billede") }
                            }
                            Spacer()
                            Button("Slet", systemImage: "trash", role: .destructive) {
                                pendingImageDeletion = file
                            }.labelStyle(.iconOnly).accessibilityLabel("Slet billede")
                        }
                    }.navigationTitle("Billedhistorik")
                        .toolbar { Button("Tilbage") { showHistory = false } }
                }
            }
            .fileImporter(isPresented: $importLoRA, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result { loadLoRA(url) }
            }
            .confirmationDialog("Slet dette billede permanent?", isPresented: Binding(
                get: { pendingImageDeletion != nil }, set: { if !$0 { pendingImageDeletion = nil } }
            ), presenting: pendingImageDeletion) { file in
                Button("Slet billede", role: .destructive) { deleteImage(file) }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                enabled = true
                loadPrivateConversation()
                prompt = UserDefaults.standard.string(forKey: "private.chat.draft") ?? ""
                if privateBotID.isEmpty { privateBotID = privateBots.first?.id.uuidString ?? "" }
            }
            .onChange(of: prompt) { UserDefaults.standard.set(prompt, forKey: "private.chat.draft") }
        }
    }

    private var privateHeader: some View {
        HStack(spacing: 14) {
            Group {
                if let data = selectedPrivateBot?.sprite, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
                } else {
                    Circle().fill(.pink.gradient)
                        .overlay(Image(systemName: "heart.fill").font(.title).foregroundStyle(.white))
                }
            }.frame(width: 64, height: 64).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedPrivateBot?.name ?? "Din private companion").font(.title2.bold())
                Label("Kører lokalt på telefonen", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var privateSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kun for voksne. Den valgte lokale models egne begrænsninger gælder stadig.")
                .font(.caption).foregroundStyle(.secondary)
            if !privateBots.isEmpty {
                Picker("Companion", selection: $privateBotID) {
                    ForEach(privateBots) { bot in Text(bot.name).tag(bot.id.uuidString) }
                }
            }
            Button("Opret eller redigér botprofil") { showBotBuilder = true }.frame(minHeight: 44)
            Button("Lokale tekstmodeller") { showModels = true }.frame(minHeight: 44)
            Text(textReady ? "Tekstmodellen er klar." : "Vælg en downloadet Core ML-model til privat chat.")
                .font(.caption)
            Picker("Billedmodel", selection: $imageModel) {
                Text("Stable Diffusion 1.5").tag("sd_v1.5_f16.ckpt")
                Text("FLUX.2 Klein 4B").tag("flux_2_klein_4b_q8p.ckpt")
            }.disabled(task != nil)
            Button("Download billedmodel") { downloadImageModel() }
                .frame(minHeight: 44).disabled(task != nil)
            Button("Importér LoRA fra Filer") { importLoRA = true }
                .frame(minHeight: 44).disabled(task != nil)
            if !loraName.isEmpty {
                Toggle("Brug importeret LoRA", isOn: $useLoRA).disabled(task != nil)
            }
            Button("Billedhistorik") { showHistory = true }.frame(minHeight: 44)
            ShareLink(item: privateConversationText) {
                Label("Eksportér privat samtale", systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }.disabled(turns.isEmpty)
            Text(textReady && imageReady ? "Klar til flytilstand · Chat og billeder"
                 : textReady ? "Klar til flytilstand · Chat"
                 : imageReady ? "Klar til flytilstand · Billeder" : "Lokale modeller mangler")
                .font(.caption.bold())
        }
    }

    private func privateTurn(_ turn: PrivateChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 46)
                Text(turn.prompt)
                    .padding(12).background(.pink.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(turn.source ?? "Privat bot", systemImage: turn.imageName == nil ? "heart.fill" : "photo")
                    .font(.caption.bold()).foregroundStyle(.pink)
                if !turn.reply.isEmpty { Text(turn.reply).textSelection(.enabled) }
                if let name = turn.imageName {
                    let file = historyFolder.appendingPathComponent(name)
                    if let image = UIImage(contentsOfFile: file.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Genereret billede")
                        HStack {
                            ShareLink(item: file) { Label("Del", systemImage: "square.and.arrow.up") }
                            Button("Slet", systemImage: "trash", role: .destructive) { pendingImageDeletion = file }
                        }.frame(minHeight: 44)
                    } else {
                        Text("Billedet er slettet.").foregroundStyle(.secondary)
                    }
                }
                Button("Slet samtaleled", systemImage: "trash", role: .destructive) {
                    deleteTurn(turn.id)
                }.frame(minHeight: 44)
            }
            .padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        }.id(turn.id)
    }

    private var privateComposer: some View {
        VStack(spacing: 8) {
            if task != nil {
                Button("Stop", systemImage: "stop.fill") { task?.cancel() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Skriv til din private bot…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5).focused($promptFocused)
                Menu {
                    Button("Lav billede af beskeden", systemImage: "photo.badge.plus") { generateImage() }
                    Button("Åbn billedhistorik", systemImage: "photo.on.rectangle") { showHistory = true }
                } label: {
                    Image(systemName: "plus").frame(width: 48, height: 48)
                }.accessibilityLabel("Billeder").disabled(task != nil || !hasPrompt || prompt.count > 2000)
                Button { sendPrivateMessage() } label: {
                    Image(systemName: "arrow.up").frame(width: 48, height: 48)
                }
                .buttonStyle(.borderedProminent).tint(.pink)
                .accessibilityLabel("Send besked")
                .disabled(!textReady || !hasPrompt || prompt.count > 2000 || task != nil)
            }
            HStack {
                Text("\(prompt.count) / 2.000").font(.caption.monospacedDigit())
                    .foregroundStyle(prompt.count > 2000 ? Color.red : Color.secondary)
                Spacer()
                Button("Ryd") { prompt = "" }.disabled(prompt.isEmpty || task != nil)
            }
        }.padding(12).background(.ultraThinMaterial)
    }

    private func sendPrivateMessage() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionUnlocked, textReady, !message.isEmpty, task == nil else { return }
        prompt = ""
        answer = ""
        turns.append(PrivateChatTurn(prompt: message, reply: "", source: "Telefon"))
        let index = turns.count - 1
        status = "Din bot skriver…"
        task = Task {
            defer { task = nil; status = ""; savePrivateConversation() }
            do {
                let context = turns.dropLast().suffix(8).map { "Bruger: \($0.prompt)\nBot: \($0.reply)" }.joined(separator: "\n")
                let fullPrompt = context.isEmpty ? message : context + "\nBruger: " + message
                let profile = selectedPrivateBot
                let custom = profile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let instructions = "Du er \(profile?.name ?? "brugerens private AI-companion"). Du er varm, flirtende og taler naturligt med en voksen bruger. Bevar din personlighed og respekter tydelige grænser." + (custom.isEmpty ? "" : " Din personlighed: " + custom)
                try await PhoneModels.reply(modelID: textModel, prompt: fullPrompt, instructions: instructions) { value in
                    answer = value
                    turns[index].reply = value
                }
            } catch is CancellationError {
                turns[index].reply += turns[index].reply.isEmpty ? "Svaret blev stoppet." : ""
            } catch {
                turns[index].reply = "Jeg kunne ikke svare lokalt. Tjek din tekstmodel under Private indstillinger."
            }
        }
    }

    private func downloadImageModel() {
        let selected = imageModel
        let reserve: Int64 = selected.hasPrefix("flux") ? 8_000_000_000 : 4_000_000_000
        guard PhoneModels.hasDownloadSpace(bytes: reserve) else { status = "Frigør mere plads før download."; return }
        run("Henter billedmodel…") {
            defer { downloadProgress = nil }
            _ = try await MediaGenerationEnvironment.default.ensure(selected) { state in
                if case .downloading(_, let index, let count, let written, let total) = state,
                   count > 0, total > 0 {
                    let part = min(1, Double(written) / Double(total))
                    Task { @MainActor in downloadProgress = min(1, (Double(max(0, index - 1)) + part) / Double(count)) }
                }
            }
            status = "Billedmodel hentet."
        }
    }

    private func scrollPrivate(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("private-bottom", anchor: .bottom) }
        }
    }

    private func loadPrivateConversation() {
        guard let data = UserDefaults.standard.data(forKey: "private.chat.turns"),
              let stored = try? JSONDecoder().decode([PrivateChatTurn].self, from: data) else { return }
        turns = stored
    }

    private func savePrivateConversation() {
        if let data = try? JSONEncoder().encode(turns.suffix(100)) {
            UserDefaults.standard.set(data, forKey: "private.chat.turns")
        }
    }

    private func newPrivateConversation() {
        turns = []; prompt = ""; answer = ""; status = ""
        UserDefaults.standard.removeObject(forKey: "private.chat.turns")
        UserDefaults.standard.removeObject(forKey: "private.chat.draft")
    }

    private var privateConversationText: String {
        turns.map { "Dig: \($0.prompt)\n\(selectedPrivateBot?.name ?? "Privat bot"): \($0.reply)" }
            .joined(separator: "\n\n")
    }

    private func deleteTurn(_ id: UUID) {
        turns.removeAll { $0.id == id }
        savePrivateConversation()
    }

    private func deleteImage(_ file: URL) {
        do {
            try FileManager.default.removeItem(at: file)
            if imageURL == file { imageURL = nil }
            pendingImageDeletion = nil
            status = "Billedet er slettet."
        } catch { status = "Billedet kunne ikke slettes." }
    }

    private var textSection: some View {
        Section("Lokal tekst") {
            Button("Download eller importér tekstmodel") { showModels = true }
                .frame(minHeight: 48).disabled(task != nil)
            Text(textReady ? "Core ML-modellen er klar." : "Vælg en downloadet eller importeret Core ML-model.")
            Text("Modellens egne svargrænser afhænger af de valgte vægte. Apple Foundation Models bruges ikke her.")
                .font(.caption)
            TextField("Din prompt", text: $prompt, axis: .vertical).lineLimit(2...6)
            Button("Svar på telefonen") {
                let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                answer = ""
                run("Telefonen tænker…") {
                    try await PhoneModels.reply(modelID: textModel, prompt: message) { answer = $0 }
                    status = "Tekstsvar klar."
                }
            }.frame(minHeight: 48).disabled(!textReady || !hasPrompt || task != nil)
            if !answer.isEmpty { Text(answer).textSelection(.enabled) }
        }
    }

    private var imageSection: some View {
        Section("Lokale billeder") {
            Picker("Billedmodel", selection: $imageModel) {
                Text("Stable Diffusion 1.5").tag("sd_v1.5_f16.ckpt")
                Text("FLUX.2 Klein 4B").tag("flux_2_klein_4b_q8p.ckpt")
            }.disabled(task != nil)
            Text(imageReady ? "Billedmodellen er fundet på telefonen." : "Billedmodellen skal hentes først.")
            Button("Download billedmodel") {
                let selected = imageModel
                let reserve: Int64 = selected.hasPrefix("flux") ? 8_000_000_000 : 4_000_000_000
                guard PhoneModels.hasDownloadSpace(bytes: reserve) else {
                    status = "Frigør mere plads før download."
                    return
                }
                run("Henter billedmodel…") {
                    defer { downloadProgress = nil }
                    _ = try await MediaGenerationEnvironment.default.ensure(selected) { state in
                        if case .downloading(_, let index, let count, let written, let total) = state,
                           count > 0, total > 0 {
                            let part = min(1, Double(written) / Double(total))
                            let progress = min(1, (Double(max(0, index - 1)) + part) / Double(count))
                            Task { @MainActor in
                                if sessionUnlocked && task != nil { downloadProgress = progress }
                            }
                        }
                    }
                    status = "Billedmodel hentet."
                }
            }.frame(minHeight: 48).disabled(task != nil)
            Button("Importér LoRA fra Filer") { importLoRA = true }
                .frame(minHeight: 48).disabled(task != nil)
            if !loraName.isEmpty {
                Toggle("Brug importeret LoRA", isOn: $useLoRA).disabled(task != nil)
                Text("Vælg en LoRA, der passer til billedmodellen.").font(.caption)
            }
            Button("Generér billede") { generateImage() }
                .frame(minHeight: 48).disabled((!imageReady && api == nil) || !hasPrompt || task != nil)
            if let imageURL, let preview = UIImage(contentsOfFile: imageURL.path) {
                Image(uiImage: preview).resizable().scaledToFit()
                    .accessibilityLabel("Genereret billede")
                ShareLink(item: imageURL) { Label("Del billede", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var textReady: Bool { textModel != "apple" && PhoneModels.installedDirectory(textModel) != nil }
    private var imageReady: Bool {
        (try? MediaGenerationEnvironment.default.inspectModel(imageModel, offline: true))?.isDownloaded == true
    }

    private func generateImage() {
        let selected = imageModel
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lora = useLoRA ? loraName : ""
        run("Genererer billede på telefonen…") {
            try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
            var folder = historyFolder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
            let destination = folder.appendingPathComponent("\(timestamp)-\(UUID()).png")
            var source = "Telefon"
            do {
                guard imageReady else { throw PhoneModelError.unavailable }
                var pipeline = try await MediaGenerationPipeline.fromPretrained(selected, backend: .local)
                pipeline.configuration.width = 512
                pipeline.configuration.height = 512
                if !lora.isEmpty { pipeline.configuration.loras = [.init(file: lora, weight: 1, mode: .base)] }
                let results = try await pipeline.generate(prompt: message)
                try Task.checkCancellation()
                guard let result = results.first else { throw PhoneModelError.emptyResponse }
                try result.write(to: destination, type: .png)
            } catch {
                try Task.checkCancellation()
                guard let api else { throw error }
                status = "Telefonen kunne ikke lave billedet. PC’en prøver med sin egen model uden telefonens LoRA…"
                let png = try await api.v2GenerateImage(prompt: message)
                try Task.checkCancellation()
                try png.write(to: destination, options: .atomic)
                source = "PC (uden telefonens LoRA)"
            }
            imageURL = destination
            status = "Billede klar fra \(source)."
            turns.append(PrivateChatTurn(prompt: message, reply: "Billede klar.",
                                         imageName: destination.lastPathComponent, source: source))
            savePrivateConversation()
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == message { prompt = "" }
        }
    }

    private func authenticate() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            status = "Slå Face ID eller Touch ID til på telefonen for at åbne studiet."
            return
        }
        authenticating = true
        Task {
            defer { authenticating = false }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                                localizedReason: "Lås FadedAI-studiet op")
                sessionUnlocked = accepted
                enabled = accepted
                status = accepted ? "" : "Studiet er låst."
            } catch { status = "Studiet er låst. Prøv igen." }
        }
    }

    private func loadLoRA(_ source: URL) {
        guard source.pathExtension.lowercased() == "safetensors",
              let directory = MediaGenerationEnvironment.default.externalUrls.first else {
            status = "Vælg en LoRA-fil i .safetensors-format."
            return
        }
        let name = "fadedai-\(UUID().uuidString)_lora_f16.ckpt"
        let destination = directory.appendingPathComponent(name)
        run("Importerer LoRA…") {
            try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                var importer = LoRAImporter(file: source)
                try importer.import(to: destination)
            }.value
            try Task.checkCancellation()
            if !loraName.isEmpty { try? FileManager.default.removeItem(at: directory.appendingPathComponent(loraName)) }
            loraName = name
            useLoRA = true
            status = "LoRA importeret."
        }
    }

    private func run(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        guard sessionUnlocked, enabled, task == nil else { return }
        status = message
        task = Task {
            defer { task = nil }
            do { try await work() }
            catch is CancellationError { status = "Stoppet." }
            catch { status = "Billedet kunne ikke laves. Tjek plads på telefonen og forbindelsen til PC’en." }
        }
    }
}
