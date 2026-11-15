import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor struct BotComputerView: View {
    let bot: VillageBot
    let roster: [VillageBot]
    let api: LiveAPI?
    var initialPrompt = ""
    var onFileShared: (UUID, UUID, UUID) -> Void = { _, _, _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.fadedPalette) private var palette
    @State private var store = BotComputerStore()
    @State private var prompt = ""
    @State private var acceptedHandoff = false
    @State private var sourceFile: UUID?
    @State private var remoteText = ""
    @State private var importFile = false
    @State private var openedFile: BotComputerFile?
    @State private var sharedFile: BotComputerFile?
    @State private var showRecipients = false
    @State private var showVaultAccess = false
    @State private var showPCServices = false
    @State private var showWebSearch = false
    @State private var showEverydayTools = false
    @State private var showMailbox = false
    @State private var taskContext: String?
    @State private var phoneKind: BotPhoneActionKind?
    @State private var webSearch = false
    @State private var reviewingPhoneJob: BotComputerJob?
    @AppStorage("fadedai.phone-job.applied") private var appliedPhoneJobs = ""

    private var client: BotComputerClient? { api.map { BotComputerClient(api: $0, botID: bot.id) } }
    private var otherBots: [VillageBot] { roster.filter { $0.id != bot.id } }
    private var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var monitorID: String { (api?.queueTargetID ?? "") + ":" + String(scenePhase == .active) }
    private var desktopTint: Color {
        switch bot.color {
        case "Grøn": palette.green
        case "Lilla": palette.purple
        default: palette.cyan
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            computerContent
        }
        .background {
            ZStack {
                FadedBackground()
                LinearGradient(colors: [desktopTint.opacity(0.22), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
        .foregroundStyle(palette.text)
        .navigationTitle("Computer · \(bot.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: monitorID) {
            if !acceptedHandoff {
                prompt = initialPrompt
                acceptedHandoff = true
            }
            store.selectConnection(api?.queueTargetID)
            guard let client, scenePhase == .active else {
                store.leaveDesktop()
                return
            }
            await store.monitor(client)
        }
        .onChange(of: api?.queueTargetID) {
            sourceFile = nil
            taskContext = nil
            prompt = ""
            remoteText = ""
            openedFile = nil
            sharedFile = nil
            showRecipients = false
            showVaultAccess = false
            showPCServices = false
            showWebSearch = false
            showEverydayTools = false
            showMailbox = false
            phoneKind = nil
            webSearch = false
            reviewingPhoneJob = nil
        }
        .onDisappear { store.leaveDesktop() }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText], onCompletion: importText)
        .sheet(item: $openedFile) { file in
            if let client { BotComputerFileView(file: file, client: client) }
        }
        .sheet(isPresented: $showVaultAccess) {
            if let client {
                VaultJobAccessView(botName: bot.name) { text in
                    attachLookup(text, client: client)
                }
            }
        }
        .sheet(isPresented: $showMailbox) {
            if let client {
                NavigationStack {
                    BotMailView(api: client.api, bot: bot) { content in
                        if attachLookup(content, client: client) {
                            showMailbox = false
                            return true
                        }
                        return false
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Luk") { showMailbox = false } }
                    }
                }
            }
        }
        .sheet(isPresented: $showPCServices) {
            if let client {
                NavigationStack {
                    PCServicesView(api: client.api, onUse: { attachLookup($0, client: client) })
                }
            }
        }
        .sheet(isPresented: $showWebSearch) {
            if let client {
                NavigationStack {
                    PCServiceLookupView(api: client.api, service: .web) { text in
                        guard attachLookup(text, client: client) else { return false }
                        showWebSearch = false
                        return true
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Luk") { showWebSearch = false } }
                    }
                }
            }
        }
        .sheet(isPresented: $showEverydayTools) { everydayToolsSheet }
        .sheet(item: $reviewingPhoneJob) { job in
            if let action = job.phoneAction {
                BotPhoneActionReview(action: action, jobID: job.id, botName: bot.name) {
                    var keys = appliedPhoneJobs.split(separator: ",").map(String.init)
                    let key = job.id.uuidString
                    if !keys.contains(key) { keys.append(key) }
                    appliedPhoneJobs = keys.suffix(500).joined(separator: ",")
                }
            }
        }
        .confirmationDialog("Del med en anden bot", isPresented: $showRecipients, presenting: sharedFile) { file in
            ForEach(otherBots) { recipient in
                Button("Del med \(recipient.name)") {
                    if let client {
                        Task {
                            if let copy = await store.share(file, with: recipient, client: client) {
                                onFileShared(bot.id, recipient.id, copy.id)
                            }
                        }
                    }
                }
            }
        } message: { file in
            Text("Modtageren får en kopi af \(file.name) i sit eget arbejdsrum.")
        }
    }

    private var computerContent: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.action) {
            VillagePixelImage(name: "room-" + VillageAssets.newArtName(name: bot.name, id: bot.id.uuidString),
                              folder: "new")
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(palette.card, in: .rect(cornerRadius: 18))
                .clipShape(.rect(cornerRadius: 18))
                .accessibilityLabel("Personligt rum for \(bot.name)")
            statusCard
            if let client {
                if !initialPrompt.isEmpty { jobs(client) }
                desktop(client)
                if initialPrompt.isEmpty { jobs(client) }
                files(client)
            }
        }
        .padding(FadedSpacing.edge)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }

    private var everydayToolsSheet: some View {
        let phoneDraft: ((BotPhoneActionKind) -> Void)?
        if store.status?.phoneActions == true {
            phoneDraft = { kind in preparePhoneTask(kind) }
        } else {
            phoneDraft = nil
        }
        let researchDraft: (() -> Void)?
        if canPrepareResearch {
            researchDraft = { prepareResearch() }
        } else {
            researchDraft = nil
        }
        let tools = EverydayToolsView(
            api: api,
            draftTitle: "Brug i opgaven",
            onPhoneDraft: phoneDraft,
            onResearchDraft: researchDraft,
            onDraft: insertEverydayDraft
        )

        return NavigationStack {
            tools.toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { showEverydayTools = false } }
            }
        }
    }

    private func insertEverydayDraft(_ text: String) -> Bool {
        guard !store.busy, let updated = EverydayDraft.appending(text, to: prompt, limit: 2_000) else {
            return false
        }
        prompt = updated
        showEverydayTools = false
        return true
    }

    private var statusCard: some View {
        FadedCard(accent: desktopTint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: FadedSpacing.m) {
                    VillageBotAvatar(bot: bot, size: 52, radius: 14)
                    VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                        Text(bot.name).font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                        if let specialty = bot.specialty, !specialty.isEmpty {
                            FadedDetailText(specialty)
                        }
                    }
                    Spacer()
                    Menu("Bottens indstillinger", systemImage: "ellipsis.circle") {
                        Button("Kopiér bot-id", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = bot.id.uuidString.lowercased()
                        }
                    }
                    .labelStyle(.iconOnly)
                }
                if let status = store.status {
                    Text(status.status.title).font(.subheadline.weight(.semibold))
                    if let message = status.message { Text(message).foregroundStyle(palette.secondary) }
                } else if client == nil {
                    Text("Par din iPhone med FadedAI på PC’en.").foregroundStyle(palette.secondary)
                } else if store.connectionError == nil {
                    ProgressView("Tjekker PC’en…")
                }
                if let message = store.connectionError { Text(message).foregroundStyle(palette.secondary) }
                if client == nil || store.connectionError != nil || store.status?.status == .unavailable {
                    NavigationLink {
                        AgentPhoneChat(bot: bot)
                    } label: {
                        Label("Chat på iPhone", systemImage: "iphone").frame(minHeight: 44)
                    }
                }
                if let message = store.feedback { Text(message).foregroundStyle(palette.secondary) }
                if let client, let status = store.status?.status {
                    if status == .running {
                        FadedSecondaryButton("Stop computer", icon: "stop.circle") {
                            Task { await store.changePower(start: false, client: client) }
                        }
                        .disabled(store.busy)
                    } else if status == .stopped {
                        FadedSecondaryButton("Start computer", icon: "power") {
                            Task { await store.changePower(start: true, client: client) }
                        }
                        .disabled(store.busy)
                    }
                }
            }
        }
    }

    @ViewBuilder private func desktop(_ client: BotComputerClient) -> some View {
        if store.status?.status == .running {
            FadedCard {
                VStack(alignment: .leading, spacing: 12) {
                    FadedSectionLabel("Skrivebord")
                    if store.watching {
                        desktopContents(client)
                    } else {
                        FadedSecondaryButton("Se live", icon: "eye") { store.watching = true }
                    }
                }
            }
        }
    }

    @ViewBuilder private func desktopContents(_ client: BotComputerClient) -> some View {
        if let frame = store.frame {
            BotDesktopSurface(frame: frame, takingControl: store.controlling) { input in
                Task { await store.send(input, client: client) }
            }
            .overlay(alignment: .topTrailing) {
                Button { store.leaveDesktop() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).fadedGlassSurface()
                }
                .buttonStyle(.plain).accessibilityLabel("Luk livevisning").padding(8)
            }
            Toggle("Overtag styring", isOn: Binding(get: { store.controlling }, set: { store.controlling = $0 }))
                .disabled(store.screenError != nil)
            if store.controlling { inputControls(client) }
        } else if store.screenError == nil {
            ProgressView("Henter skrivebord…")
        }
        if let message = store.screenError { Text(message).foregroundStyle(palette.secondary) }
        if store.frame == nil {
            FadedSecondaryButton("Luk livevisning", icon: "eye.slash") { store.leaveDesktop() }
        }
    }

    private func inputControls(_ client: BotComputerClient) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Skriv på skrivebordet", text: $remoteText)
                .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                .submitLabel(.send)
                .onSubmit { sendRemoteText(client) }
            FadedSecondaryButton("Send tekst", icon: "keyboard") { sendRemoteText(client) }
                .disabled(remoteText.isEmpty || remoteText.unicodeScalars.count > 500 || store.busy)
            ViewThatFits(in: .horizontal) {
                HStack { desktopKeys(client) }
                VStack(alignment: .leading) { desktopKeys(client) }
            }
            if let frame = store.frame {
                HStack {
                    scrollButton("Rul op", icon: "arrow.up", direction: -3, frame: frame, client: client)
                    scrollButton("Rul ned", icon: "arrow.down", direction: 3, frame: frame, client: client)
                }
            }
        }
    }

    private func scrollButton(_ title: String, icon: String, direction: Int,
                              frame: BotDesktopImage, client: BotComputerClient) -> some View {
        FadedSecondaryButton(title, icon: icon) {
            Task {
                await store.send(.scroll(x: frame.width / 2, y: frame.height / 2, dx: 0, dy: direction), client: client)
            }
        }
        .disabled(store.busy)
    }

    @ViewBuilder private func desktopKeys(_ client: BotComputerClient) -> some View {
        ForEach(["Enter", "Tab", "Escape", "BackSpace"], id: \.self) { key in
            FadedSecondaryButton(key) {
                Task { await store.send(.key(key), client: client) }
            }
            .disabled(store.busy)
        }
    }

    private func sendRemoteText(_ client: BotComputerClient) {
        guard !remoteText.isEmpty, remoteText.unicodeScalars.count <= 500 else { return }
        let submitted = remoteText
        Task {
            if await store.send(.text(submitted), client: client), remoteText == submitted { remoteText = "" }
        }
    }

    private func jobs(_ client: BotComputerClient) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Opgaver")
                FadedSecondaryButton("Hverdagsværktøjer", icon: "wrench.and.screwdriver") { showEverydayTools = true }
                    .disabled(store.busy)
                if store.status?.phoneActions == true {
                    NavigationLink {
                        MailAppointmentsView(api: client.api, bot: bot)
                    } label: {
                        Label("Gmail-aftaler", systemImage: "calendar.badge.envelope")
                            .frame(minHeight: 44)
                    }
                    Picker("Opgavetype", selection: $phoneKind) {
                        Text("Almindelig opgave").tag(nil as BotPhoneActionKind?)
                        ForEach(BotPhoneActionKind.allCases, id: \.self) { kind in
                            if kind != .alarm || BotPhoneActionReview.supportsAlarms {
                                Text(kind.title).tag(Optional(kind))
                            }
                        }
                    }
                    .frame(minHeight: 44)
                }
                if phoneKind == nil && store.loadedCatalog && store.status?.agentProfile != true && agentProfile != nil {
                    FadedDetailText("Opdatér PC’en for at bruge bottens instruktioner i opgaver.")
                }
                TextField(phoneKind == nil ? "Giv \(bot.name) en opgave" : "Skriv hvad der skal ske og hvornår",
                          text: $prompt, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).frame(minHeight: 44)
                if phoneKind == nil && sourceFile == nil && taskContext == nil && store.status?.webSearch == true {
                    Toggle("Brug nettet", isOn: $webSearch)
                        .disabled(!store.canSend || store.busy)
                    if webSearch { FadedDetailText("Skriv, hvad agenten skal undersøge. Kilderne følger med svaret.") }
                }
                if phoneKind == nil && !webSearch && taskContext == nil && !store.files.isEmpty {
                    Picker("Brug en fil", selection: $sourceFile) {
                        Text("Ingen fil valgt").tag(nil as UUID?)
                        ForEach(store.files) { file in Text(file.name).tag(Optional(file.id)) }
                    }
                    .frame(minHeight: 44)
                }
                if phoneKind == nil && webSearch {
                    FadedDetailText("PC’en søger ud fra opgaven og viser links til de kilder, agenten brugte.")
                } else if phoneKind == nil {
                    if taskContext != nil {
                        FadedDetailText("Ét opslag følger kun denne opgave. Adgangen udløber efter 30 minutter i køen.")
                        FadedSecondaryButton("Fjern opslag", icon: "xmark") {
                            taskContext = nil
                            store.forgetDraft()
                        }
                        .disabled(store.busy)
                    } else {
                        FadedSecondaryButton("Brug Fælles Vault", icon: "lock.shield") { showVaultAccess = true }
                            .disabled(!store.canSend || store.busy || store.status?.taskContext != true)
                        FadedSecondaryButton("Brug en e-mail", icon: "envelope") { showMailbox = true }
                            .disabled(!store.canSend || store.busy || store.status?.taskContext != true)
                        FadedSecondaryButton("Find kilder på nettet", icon: "magnifyingglass") { showWebSearch = true }
                            .disabled(!store.canSend || store.busy || store.status?.taskContext != true)
                        FadedSecondaryButton("Brug en PC-forbindelse", icon: "desktopcomputer") { showPCServices = true }
                            .disabled(!store.canSend || store.busy || store.status?.taskContext != true)
                    }
                } else {
                    FadedDetailText("Botten foreslår titlen og tidspunktet. Du godkender på din iPhone.")
                }
                FadedPrimaryButton(phoneKind != nil ? "Bed om forslag" : webSearch ? "Send opgave med websøgning" : "Send opgave",
                                   icon: "arrow.up") { submit(client) }
                    .disabled(!store.canSend || store.busy || cleanPrompt.isEmpty || cleanPrompt.unicodeScalars.count > 2_000)
                if let message = store.catalogError {
                    Text(message).foregroundStyle(palette.secondary)
                } else if store.jobs.isEmpty && store.loadedCatalog {
                    Text("Botten har endnu ingen opgaver.").foregroundStyle(palette.secondary)
                }
                ForEach(store.jobs) { job in jobRow(job, client: client) }
            }
        }
    }

    private var agentProfile: String? {
        let instructions = bot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialty = bot.specialty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let responsibility = bot.responsibility?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instructions.isEmpty || !specialty.isEmpty || !responsibility.isEmpty else { return nil }
        let sections = [instructions, specialty.isEmpty ? "" : "Speciale: " + String(specialty.prefix(64)),
                        responsibility.isEmpty ? "" : "Ansvar: " + String(responsibility.prefix(400))]
        return String(decoding: sections.filter { !$0.isEmpty }.joined(separator: "\n").utf8.prefix(5_900), as: UTF8.self)
    }

    private func preparePhoneTask(_ kind: BotPhoneActionKind) {
        guard !store.busy, store.status?.phoneActions == true else { return }
        phoneKind = kind
        showEverydayTools = false
    }

    private var canPrepareResearch: Bool {
        store.canSend && !store.busy && store.status?.webSearch == true && taskContext == nil && sourceFile == nil
    }

    private func prepareResearch() {
        guard canPrepareResearch else { return }
        phoneKind = nil
        webSearch = true
        showEverydayTools = false
    }

    private func submit(_ client: BotComputerClient) {
        let submitted = cleanPrompt
        let kind = phoneKind
        let file = kind == nil ? sourceFile : nil
        let context = kind == nil ? taskContext : nil
        let search = kind == nil && file == nil && context == nil && webSearch
        let profile = kind == nil && store.status?.agentProfile == true ? agentProfile : nil
        Task {
            if await store.submit(prompt: submitted, fileID: file, phoneKind: kind, context: context,
                                  agentProfile: profile, webSearch: search, client: client) {
                if cleanPrompt == submitted { prompt = "" }
                if let context, taskContext == context { taskContext = nil }
                if search { webSearch = false }
            }
        }
    }

    private func attachLookup(_ text: String, client: BotComputerClient) -> Bool {
        guard self.client?.api.queueTargetID == client.api.queueTargetID,
              !text.isEmpty, text.utf8.count <= 8_000 else { return false }
        taskContext = text
        sourceFile = nil
        webSearch = false
        store.forgetDraft()
        return true
    }

    private func jobRow(_ job: BotComputerJob, client: BotComputerClient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(jobLabel(job))
                .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
            Text(job.prompt).font(.subheadline).lineLimit(3)
            if let error = job.error { Text(error).font(.subheadline).foregroundStyle(palette.secondary) }
            if let result = job.result, !result.isEmpty {
                if job.phoneKind != nil {
                    Text(result).foregroundStyle(palette.secondary)
                } else {
                    DisclosureGroup("Læs resultat") {
                        Text(result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let sources = job.webSources, !sources.isEmpty {
                DisclosureGroup("Kilder · \(sources.count)") {
                    ForEach(sources) { source in
                        if ["http", "https"].contains(source.url.scheme ?? ""), source.url.host != nil,
                           source.url.user == nil, source.url.password == nil {
                            Link(destination: source.url) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(source.title, systemImage: "arrow.up.right.square")
                                    Text(source.readPage ? "Læst på siden" : "Uddrag fra søgningen")
                                        .font(.caption).foregroundStyle(palette.secondary)
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            if let action = job.phoneAction, action.kind == job.phoneKind {
                if appliedPhoneJobs.split(separator: ",").contains(Substring(job.id.uuidString)) {
                    Label("Oprettet på iPhone", systemImage: "checkmark.circle")
                } else {
                    FadedSecondaryButton("Gennemgå \(action.kind.title.lowercased())", icon: "checkmark.circle") {
                        reviewingPhoneJob = job
                    }
                }
            } else if job.phoneKind != nil && job.status == .completed {
                FadedSecondaryButton("Ret opgaven", icon: "pencil") { reuse(job) }
            }
            if job.status.canCancel {
                FadedSecondaryButton("Annuller opgave", icon: "stop.circle") {
                    Task { await store.cancel(job.id, client: client) }
                }
                .disabled(store.busy || !store.canSend)
            } else if job.status.canRetry {
                FadedSecondaryButton("Brug opgaven igen", icon: "arrow.counterclockwise") { reuse(job) }
                if job.hasTaskContext == true { FadedDetailText("Hent opslaget igen, hvis du vil bruge det i den nye opgave.") }
            }
        }
    }

    private func jobLabel(_ job: BotComputerJob) -> String {
        guard job.phoneKind != nil, job.status == .completed else { return job.status.title }
        return job.phoneAction == nil ? "Afventer et svar fra dig" : "Forslag klar"
    }

    private func reuse(_ job: BotComputerJob) {
        prompt = job.prompt
        sourceFile = job.fileID
        taskContext = nil
        phoneKind = job.phoneKind
        webSearch = job.webSearch == true && store.status?.webSearch == true
        store.forgetDraft()
    }

    private func files(_ client: BotComputerClient) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Filer")
                FadedSecondaryButton("Importér tekstfil", icon: "square.and.arrow.down") { importFile = true }
                    .disabled(store.busy || !store.canSend)
                if store.files.isEmpty && store.loadedCatalog {
                    Text("Botten har endnu ingen filer.").foregroundStyle(palette.secondary)
                }
                ForEach(store.files) { file in fileRow(file) }
            }
        }
    }

    private func fileRow(_ file: BotComputerFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                store.leaveDesktop()
                openedFile = file
            } label: {
                Label(file.name, systemImage: "doc.text")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(!store.canSend)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                .font(.caption).foregroundStyle(palette.secondary)
            if !otherBots.isEmpty {
                FadedSecondaryButton("Del en kopi", icon: "square.and.arrow.up") {
                    sharedFile = file
                    showRecipients = true
                }
                .accessibilityLabel("Del en kopi af \(file.name)")
                .disabled(store.busy || !store.canSend)
            }
        }
    }

    private func importText(_ result: Result<URL, any Error>) {
        guard let client, case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try LocalFileStore.readBytes(from: url, maximumBytes: 16_000)
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let name = url.lastPathComponent
            Task {
                if let file = await store.upload(name: name, content: content, client: client) {
                    sourceFile = file.id
                }
            }
        } catch {
            store.feedback = "Vælg en UTF-8-tekstfil på højst 16 KB."
        }
    }
}

private struct BotDesktopImage {
    let image: UIImage
    let width: Int
    let height: Int

    init?(_ source: BotComputerFrame) {
        guard let decoder = CGImageSourceCreateWithData(source.png as CFData, nil),
              let type = CGImageSourceGetType(decoder), type as String == UTType.png.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(decoder, 0, nil) as? [String: Any],
              let pixelWidth = (info[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let pixelHeight = (info[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else { return nil }
        guard (1...16_384).contains(pixelWidth), (1...16_384).contains(pixelHeight),
              pixelWidth * pixelHeight <= 16_777_216,
              let decoded = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { return nil }
        image = UIImage(cgImage: decoded)
        width = source.width ?? pixelWidth
        height = source.height ?? pixelHeight
    }
}

private struct BotDesktopSurface: View {
    let frame: BotDesktopImage
    let takingControl: Bool
    let onInput: (BotComputerClient.Input) -> Void

    var body: some View {
        Image(uiImage: frame.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                if takingControl {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                                let x = Int(tap.location.x / geometry.size.width * CGFloat(frame.width))
                                let y = Int(tap.location.y / geometry.size.height * CGFloat(frame.height))
                                onInput(.click(x: min(frame.width - 1, max(0, x)), y: min(frame.height - 1, max(0, y))))
                            })
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FadedRadius.small))
            .privacySensitive()
            .accessibilityLabel("Seneste billede fra bottens skrivebord")
    }
}

@MainActor private struct BotComputerFileView: View {
    let file: BotComputerFile
    let client: BotComputerClient
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let content {
                    Text(content).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(FadedSpacing.edge)
                } else if let failure {
                    Text(failure).padding(FadedSpacing.edge)
                } else {
                    ProgressView("Henter filen…").padding(FadedSpacing.edge)
                }
            }
            .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
        .task {
            do { content = try await client.file(file.id) }
            catch { if !Task.isCancelled { failure = BotComputerStore.message(for: error) } }
        }
    }
}

@MainActor @Observable private final class BotComputerStore {
    private struct Draft: Equatable {
        let prompt: String
        let fileID: UUID?
        let phoneKind: BotPhoneActionKind?
        let phoneTime: String?
        let context: String?
        let agentProfile: String?
        let webSearch: Bool
        let requestID = UUID()

        func matches(_ prompt: String, _ fileID: UUID?, _ phoneKind: BotPhoneActionKind?,
                     _ context: String?, _ agentProfile: String?, _ webSearch: Bool) -> Bool {
            self.prompt == prompt && self.fileID == fileID && self.phoneKind == phoneKind &&
                self.context == context && self.agentProfile == agentProfile && self.webSearch == webSearch
        }
    }

    var status: BotComputerStatus?
    var jobs: [BotComputerJob] = []
    var files: [BotComputerFile] = []
    var watching = false
    var controlling = false
    var frame: BotDesktopImage?
    var busy = false
    var loadedCatalog = false
    var connectionError: String?
    var catalogError: String?
    var screenError: String?
    var feedback: String?
    private var target: String?
    private var revision = 0
    private var draft: Draft?

    var canSend: Bool { status != nil && connectionError == nil }

    func selectConnection(_ id: String?) {
        guard id != target else { return }
        target = id
        revision += 1
        status = nil
        jobs = []
        files = []
        loadedCatalog = false
        busy = false
        draft = nil
        feedback = nil
        connectionError = nil
        catalogError = nil
        leaveDesktop()
    }

    func leaveDesktop() {
        watching = false
        controlling = false
        frame = nil
        screenError = nil
    }

    func forgetDraft() { draft = nil }

    func monitor(_ client: BotComputerClient) async {
        var nextStatusCheck = ContinuousClock.now
        while !Task.isCancelled {
            if !busy {
                if ContinuousClock.now >= nextStatusCheck {
                    await refresh(client)
                    nextStatusCheck = ContinuousClock.now.advanced(by: .seconds(5))
                }
                if watching && status?.status == .running { await refreshScreen(client) }
            }
            do { try await Task.sleep(for: watching ? .seconds(1) : .seconds(2)) }
            catch { return }
        }
    }

    private func isCurrent(_ client: BotComputerClient, _ revision: Int) -> Bool {
        !Task.isCancelled && target == client.api.queueTargetID && self.revision == revision
    }

    private func refresh(_ client: BotComputerClient) async {
        let current = revision
        do {
            let value = try await client.status()
            guard isCurrent(client, current) else { return }
            status = value
            connectionError = nil
            if value.status != .running { leaveDesktop() }
        } catch {
            guard isCurrent(client, current) else { return }
            status = nil
            leaveDesktop()
            connectionError = Self.message(for: error)
            return
        }
        await refreshCatalog(client, revision: current)
    }

    private func refreshCatalog(_ client: BotComputerClient, revision: Int) async {
        do {
            async let nextJobs = client.jobs()
            async let nextFiles = client.files()
            let snapshot = try await (nextJobs, nextFiles)
            guard isCurrent(client, revision) else { return }
            jobs = snapshot.0
            files = snapshot.1
            SimulationEngine.shared.ingestJobs(jobs.map { .init(id: $0.id, status: $0.status) },
                                               for: client.botID, targetID: client.api.queueTargetID)
            loadedCatalog = true
            catalogError = nil
        } catch {
            guard isCurrent(client, revision) else { return }
            catalogError = Self.message(for: error)
        }
    }

    private func refreshScreen(_ client: BotComputerClient) async {
        let current = revision
        do {
            let data = try await client.screenshot()
            guard isCurrent(client, current), watching else { return }
            guard let image = BotDesktopImage(data) else { throw APIError.malformed }
            frame = image
            screenError = nil
        } catch {
            guard isCurrent(client, current), watching else { return }
            frame = nil
            controlling = false
            screenError = Self.message(for: error)
        }
    }

    @discardableResult private func perform<T>(
        _ client: BotComputerClient, operation: () async throws -> T,
        apply: (T) -> Void
    ) async -> Bool {
        guard target == client.api.queueTargetID, !busy else { return false }
        revision += 1
        let current = revision
        busy = true
        feedback = nil
        defer { if revision == current { busy = false } }
        do {
            let response = try await operation()
            guard isCurrent(client, current) else { return false }
            apply(response)
            return true
        } catch {
            guard isCurrent(client, current) else { return false }
            feedback = Self.message(for: error)
            return false
        }
    }

    func changePower(start: Bool, client: BotComputerClient) async {
        if !start { leaveDesktop() }
        await perform(client) {
            if start { try await client.start() } else { try await client.stop() }
        } apply: { status = $0 }
    }

    @discardableResult func send(_ input: BotComputerClient.Input, client: BotComputerClient) async -> Bool {
        guard watching, controlling, frame != nil, status?.status == .running else { return false }
        return await perform(client) { try await client.send(input) } apply: { _ in }
    }

    func submit(prompt: String, fileID: UUID?, phoneKind: BotPhoneActionKind?, context: String?,
                agentProfile: String?, webSearch: Bool, client: BotComputerClient) async -> Bool {
        guard canSend, !busy else { return false }
        guard loadedCatalog else {
            feedback = "Vent, til bottens opgaver er hentet, og prøv igen."
            return false
        }
        guard phoneKind == nil || status?.phoneActions == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge iPhone-opgaver."
            return false
        }
        guard context == nil || status?.taskContext == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge opslag i botopgaver."
            return false
        }
        guard !webSearch || status?.webSearch == true else {
            feedback = "Opdatér FadedAI på PC’en for at bruge websøgning i opgaven."
            return false
        }
        let current = if let draft, draft.matches(prompt, fileID, phoneKind, context, agentProfile, webSearch) {
            draft
        } else {
            Draft(prompt: prompt, fileID: fileID, phoneKind: phoneKind,
                  phoneTime: phoneKind.map { _ in BotPhoneAction.localFormatter().string(from: .now) },
                  context: context, agentProfile: agentProfile, webSearch: webSearch)
        }
        draft = current
        return await perform(client) {
            try await client.submit(prompt: prompt, fileID: fileID, requestID: current.requestID,
                                    phoneKind: current.phoneKind, phoneTime: current.phoneTime,
                                    taskContext: current.context, agentProfile: current.agentProfile, webSearch: current.webSearch)
        } apply: { job in
            draft = nil
            applyJob(job)
        }
    }

    func cancel(_ id: UUID, client: BotComputerClient) async {
        await perform(client) { try await client.cancel(id) } apply: { applyJob($0) }
    }

    func upload(name: String, content: String, client: BotComputerClient) async -> BotComputerFile? {
        var imported: BotComputerFile?
        await perform(client) {
            try await client.upload(name: name, content: content)
        } apply: { file in
            files.insert(file, at: 0)
            feedback = "Filen ligger i bottens arbejdsrum."
            imported = file
        }
        return imported
    }

    func share(_ file: BotComputerFile, with recipient: VillageBot, client: BotComputerClient) async -> BotComputerFile? {
        var copy: BotComputerFile?
        await perform(client) {
            try await client.share(fileID: file.id, with: recipient.id)
        } apply: {
            copy = $0
            feedback = "En kopi er delt med \(recipient.name)."
        }
        return copy
    }

    private func applyJob(_ job: BotComputerJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
    }

    static func message(for error: any Error) -> String {
        guard let error = error as? APIError else { return "PC’ens svar kunne ikke læses. Prøv igen." }
        switch error {
        case .http(404, _): return "Funktionen eller filen blev ikke fundet. Tjek, at FadedAI på PC’en er opdateret."
        case .http(422, _): return "Tjek teksten, filen eller handlingen, og prøv igen."
        case .http(409, _): return "Handlingen kan ikke udføres i den aktuelle tilstand. Opdater og prøv igen."
        case .http(503, _): return "Tjek, at Docker Desktop og FadedAI kører på PC’en."
        case .offline, .transport(_): return "Forbindelsen til FadedAI på PC’en er afbrudt."
        default: return error.title
        }
    }
}
