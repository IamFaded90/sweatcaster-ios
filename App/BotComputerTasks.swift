import ImageIO
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension BotComputerView {
    func jobs(_ client: BotComputerClient) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                FadedSectionLabel("Opgaver")
                if phoneKind == nil, let available = store.status?.taskModels, !available.isEmpty {
                    Picker("Model til opgaven", selection: $taskModel) {
                        Text("Lokal PC-model").tag(nil as String?)
                        ForEach(available.filter { OpenRouterCloud.preferredModels.contains($0) }, id: \.self) { model in
                            Text(OpenRouterCloud.title(model)).tag(Optional(model))
                        }
                    }.frame(minHeight: 44).disabled(store.busy)
                    if taskModel != nil {
                        FadedDetailText("Opgaven og eventuelle bilag sendes til OpenRouter. Kun gratis adgang bruges. PC’en gemmer resultatet i agentens arbejdsrum.")
                    }
                }
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

    var agentProfile: String? {
        let instructions = bot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let specialty = bot.specialty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let responsibility = bot.responsibility?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instructions.isEmpty || !specialty.isEmpty || !responsibility.isEmpty else { return nil }
        let sections = [instructions, specialty.isEmpty ? "" : "Speciale: " + String(specialty.prefix(64)),
                        responsibility.isEmpty ? "" : "Ansvar: " + String(responsibility.prefix(400))]
        return String(decoding: sections.filter { !$0.isEmpty }.joined(separator: "\n").utf8.prefix(5_900), as: UTF8.self)
    }

    func preparePhoneTask(_ kind: BotPhoneActionKind) {
        guard !store.busy, store.status?.phoneActions == true else { return }
        phoneKind = kind
        showEverydayTools = false
    }

    var canPrepareResearch: Bool {
        store.canSend && !store.busy && store.status?.webSearch == true && taskContext == nil && sourceFile == nil
    }

    func prepareResearch() {
        guard canPrepareResearch else { return }
        phoneKind = nil
        webSearch = true
        showEverydayTools = false
    }

    func submit(_ client: BotComputerClient) {
        let submitted = cleanPrompt
        let kind = phoneKind
        let file = kind == nil ? sourceFile : nil
        let context = kind == nil ? taskContext : nil
        let search = kind == nil && file == nil && context == nil && webSearch
        let profile = kind == nil && store.status?.agentProfile == true ? agentProfile : nil
        let selectedModel = kind == nil ? taskModel : nil
        Task {
            if await store.submit(prompt: submitted, fileID: file, phoneKind: kind, context: context,
                                  agentProfile: profile, webSearch: search, client: client, taskModel: selectedModel) {
                if cleanPrompt == submitted { prompt = "" }
                if let context, taskContext == context { taskContext = nil }
                if search { webSearch = false }
            }
        }
    }

    func attachLookup(_ text: String, client: BotComputerClient) -> Bool {
        guard self.client?.api.queueTargetID == client.api.queueTargetID,
              !text.isEmpty, text.utf8.count <= 8_000 else { return false }
        taskContext = text
        sourceFile = nil
        webSearch = false
        store.forgetDraft()
        return true
    }

    func jobRow(_ job: BotComputerJob, client: BotComputerClient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(jobLabel(job))
                .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
            Text(job.prompt).font(.subheadline).lineLimit(3)
            if let model = job.taskModel {
                Label(OpenRouterCloud.title(model), systemImage: "cloud").font(.caption)
            }
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

    func jobLabel(_ job: BotComputerJob) -> String {
        guard job.phoneKind != nil, job.status == .completed else { return job.status.title }
        return job.phoneAction == nil ? "Afventer et svar fra dig" : "Forslag klar"
    }

    func reuse(_ job: BotComputerJob) {
        prompt = job.prompt
        sourceFile = job.fileID
        taskContext = nil
        phoneKind = job.phoneKind
        taskModel = job.taskModel
        webSearch = job.webSearch == true && store.status?.webSearch == true
        store.forgetDraft()
    }

    func files(_ client: BotComputerClient) -> some View {
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

    func fileRow(_ file: BotComputerFile) -> some View {
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

    func importText(_ result: Result<URL, any Error>) {
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
