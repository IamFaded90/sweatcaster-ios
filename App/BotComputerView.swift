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
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.fadedPalette) var palette
    @State var store = BotComputerStore()
    @State var prompt = ""
    @State var acceptedHandoff = false
    @State var sourceFile: UUID?
    @State var remoteText = ""
    @State var importFile = false
    @State var openedFile: BotComputerFile?
    @State var sharedFile: BotComputerFile?
    @State var showRecipients = false
    @State var showVaultAccess = false
    @State var showPCServices = false
    @State var showWebSearch = false
    @State var showEverydayTools = false
    @State var showMailbox = false
    @State var showPhoneWorkspace = false
    @State var pendingWorkspaceDocument: AgentDocument?
    @State var chatDocument: AgentDocument?
    @State var taskContext: String?
    @State var phoneKind: BotPhoneActionKind?
    @State var webSearch = false
    @State var taskModel: String?
    @State var reviewingPhoneJob: BotComputerJob?
    @AppStorage("fadedai.phone-job.applied") var appliedPhoneJobs = ""

    var client: BotComputerClient? { api.map { BotComputerClient(api: $0, botID: bot.id) } }
    var otherBots: [VillageBot] { roster.filter { $0.id != bot.id } }
    var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var monitorID: String { (api?.queueTargetID ?? "") + ":" + String(scenePhase == .active) }
    var desktopTint: Color {
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
            taskModel = nil
            reviewingPhoneJob = nil
        }
        .onDisappear { store.leaveDesktop() }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText], onCompletion: importText)
        .sheet(isPresented: $showPhoneWorkspace, onDismiss: {
            chatDocument = pendingWorkspaceDocument
            pendingWorkspaceDocument = nil
        }) {
            AgentWorkspaceView(bot: bot, api: api, model: PhoneModels.readyTextModel(for: bot.id),
                              initialPrompt: prompt) { document in
                pendingWorkspaceDocument = document
                showPhoneWorkspace = false
            }
        }
        .sheet(item: $chatDocument) { document in
            AgentPhoneChat(bot: bot, api: api, startsOnPhone: true,
                           sharedAttachment: .init(document: document, onUse: {}))
        }
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

    var computerContent: some View {
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

    var everydayToolsSheet: some View {
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

    func insertEverydayDraft(_ text: String) -> Bool {
        guard !store.busy, let updated = EverydayDraft.appending(text, to: prompt, limit: 2_000) else {
            return false
        }
        prompt = updated
        showEverydayTools = false
        return true
    }

    var statusCard: some View {
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
                    Text("PC’en er ikke tilsluttet. Du kan arbejde videre på din iPhone.").foregroundStyle(palette.secondary)
                } else if store.connectionError == nil {
                    ProgressView("Tjekker PC’en…")
                }
                if let message = store.connectionError { Text(message).foregroundStyle(palette.secondary) }
                Button("Åbn arbejdsrum på iPhone", systemImage: "iphone") {
                    showPhoneWorkspace = true
                }
                .frame(minHeight: 44)
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

    @ViewBuilder func desktop(_ client: BotComputerClient) -> some View {
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

    @ViewBuilder func desktopContents(_ client: BotComputerClient) -> some View {
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

    func inputControls(_ client: BotComputerClient) -> some View {
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

    func scrollButton(_ title: String, icon: String, direction: Int,
                              frame: BotDesktopImage, client: BotComputerClient) -> some View {
        FadedSecondaryButton(title, icon: icon) {
            Task {
                await store.send(.scroll(x: frame.width / 2, y: frame.height / 2, dx: 0, dy: direction), client: client)
            }
        }
        .disabled(store.busy)
    }

    @ViewBuilder func desktopKeys(_ client: BotComputerClient) -> some View {
        ForEach(["Enter", "Tab", "Escape", "BackSpace"], id: \.self) { key in
            FadedSecondaryButton(key) {
                Task { await store.send(.key(key), client: client) }
            }
            .disabled(store.busy)
        }
    }

    func sendRemoteText(_ client: BotComputerClient) {
        guard !remoteText.isEmpty, remoteText.unicodeScalars.count <= 500 else { return }
        let submitted = remoteText
        Task {
            if await store.send(.text(submitted), client: client), remoteText == submitted { remoteText = "" }
        }
    }
}
