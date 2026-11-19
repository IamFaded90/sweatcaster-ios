import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AgentInstagramDraft: Equatable, Codable {
    var caption = ""
    var imageURL = ""
    var hasPhoto = false
    var subject = ""
    var approvedPC: String?
    var approvedAccount: String?
    var approvedUsername: String?
    var timing: AgentInstagramTiming?
    var scheduledJob: AgentInstagramJob?
}

struct AgentInstagramPlanChange: Equatable {
    let id = UUID()
    let turn: UUID
    let timing: AgentInstagramTiming
}

enum AgentInstagramIntent {
    static func match(_ text: String) -> AgentChatAction.Kind? {
        guard text.contains("instagram") else { return nil }
        let beginning = #"^(?:(?:kan|vil) du (?:lige |godt )?)?"#
        func matches(_ pattern: String) -> Bool {
            text.range(of: beginning + pattern, options: .regularExpression) != nil
        }
        if matches(#"(?:vis(?: mig)?|tjek|åbn) (?:mine |dine )?(?:(?:planlagte )?instagram[ -]?(?:planer|opslag|rapporter)|planlagte opslag på instagram)\b"#) {
            return .instagramPlans
        }
        if matches(#"planlæg(?:ge)? (?:et |mit )?(?:instagram[ -]?opslag|opslag på instagram)\b"#) { return .instagramPost }
        if matches(#"(?:opret(?:te)?|lav(?:e)?|åbn(?:e)?) (?:dig )?(?:(?:en|din(?: egen)?) )?(?:instagram[ -]?konto|(?:konto|profil) (?:til dig selv )?på instagram|instagram[ -]?profil)\b"#)
            || matches(#"(?:tilmeld(?:e)? dig|skriv(?:e)? dig op) (?:på |hos )?(?:https://(?:www\.)?)?instagram(?:\.com(?:/|$)|$)"#) {
            return .instagramAccount
        }
        if matches(#"(?:lav(?:e)?|skriv(?:e)?|opret(?:te)?|forbered(?:e)?|udgiv(?:e)?|post(?:e)?|del(?:e)?) (?:(?:et|dit|en|din) )?(?:instagram[ -]?(?:opslag|post|kladde)|(?:opslag|billede|foto|billedet|fotoet) (?:til |på )instagram)\b"#)
            || matches(#"(?:post(?:e)?|udgiv(?:e)?|del(?:e)?) på instagram\b"#) {
            return .instagramPost
        }
        return nil
    }

    static func draft(from prompt: String) -> AgentInstagramDraft {
        var draft = AgentInstagramDraft()
        if let literal = prompt.range(of: #"(?i)\b(?:med (?:billed)?teksten\s*:?\s*|(?:billedtekst|tekst)\s*:\s*)"#,
                                      options: .regularExpression) {
            let value = prompt[literal.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            draft.caption = value
        } else if let subject = prompt.range(of: #"(?i)\bom\s+"#, options: .regularExpression) {
            draft.subject = String(prompt[subject.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let plan = AgentInstagramTiming.requested(in: prompt) { draft.timing = plan }
        return draft
    }

    @MainActor static func mediaURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2048, let url = AgentSignupPage.siteURL(text),
              text.lowercased().hasPrefix("https://"), url.fragment == nil,
              let host = url.host?.lowercased(), !host.hasSuffix(".local") else { return nil }
        return url
    }
}

@MainActor struct AgentInstagramAccount: View {
    let api: LiveAPI?
    let bot: VillageBot
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brug \(bot.name)s e-mail. Du vælger brugernavn og godkender kontoen hos Instagram.")
            if let api {
                DisclosureGroup("Hent agentens e-mail") {
                    AgentEmailCard(api: api, bot: bot, request: .address, prompt: "Vis din e-mail")
                }
            } else { FadedDetailText("Forbind PC’en for at hente agentens adresse.") }
            Link("Opret konto hos Instagram", destination: URL(string: "https://www.instagram.com/accounts/emailsignup/")!)
            FadedDetailText("Skift kontoen til en professionel konto hos Instagram. Derefter kan du forbinde den, når du laver det første opslag.")
            Button("Lav første Instagram-opslag", systemImage: "camera", action: next)
        }
    }
}

struct AgentInstagramPhoto: Transferable, Sendable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file.file as CFURL, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                let crop = cropRect(CGSize(width: thumb.width, height: thumb.height))
                guard let image = thumb.cropping(to: crop) else { throw CocoaError(.fileReadCorruptFile) }
                let width = min(1080, max(320, image.width))
                let scaled = (CGFloat(width) * CGFloat(image.height) / CGFloat(image.width)).rounded()
                let height = min(floor(CGFloat(width) / 0.8), max(ceil(CGFloat(width) / 1.91), scaled))
                let size = CGSize(width: CGFloat(width), height: height)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let output = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.86) { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
                }
                guard output.count <= 4_194_304 else { throw LocalFileStore.Failure.tooLarge }
                return Self(jpeg: output)
            }
        }
    }

    static func cropRect(_ size: CGSize) -> CGRect {
        let width = min(size.width, floor(size.height * 1.91))
        let height = min(size.height, floor(size.width / 0.8))
        return CGRect(x: floor((size.width - width) / 2), y: floor((size.height - height) / 2), width: width, height: height)
    }
}

@MainActor struct AgentInstagramPost: View {
    private struct Account: Decodable {
        let connected: Bool
        let accountID, username: String?
    }
    struct Receipt: Decodable {
        let published: Bool
        let mediaID, state: String?
        var confirmed: Bool { published && (state == "published" || mediaID?.isEmpty == false) }
    }
    private struct Submission: Encodable {
        let id: UUID
        let accountID, caption: String
        let approved = true
        let imageURL: String?
        let image_jpeg: Data?
        let publishAt, followUpAt: TimeInterval?
        let notifyEmail: Bool?
    }

    let api: LiveAPI?
    let bot: VillageBot
    let id: UUID
    let suggest: (String) async throws -> String
    let save: (AgentInstagramDraft) -> Void
    let published: (String) -> Void
    let requestedPlan: AgentInstagramPlanChange?
    let planApplied: () -> Void
    @State private var draft: AgentInstagramDraft
    @State private var picker: PhotosPickerItem?
    @State private var jpeg: Data?
    @State private var account: Account?
    @State private var state: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var preparingPhoto = false
    @State private var confirming = false
    @State private var cancelling = false
    @State private var showingLink = false
    @State private var refresh = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase

    init(api: LiveAPI?, bot: VillageBot, id: UUID, prompt: String, draft: AgentInstagramDraft?,
         suggest: @escaping (String) async throws -> String,
         requestedPlan: AgentInstagramPlanChange? = nil, planApplied: @escaping () -> Void = {},
         save: @escaping (AgentInstagramDraft) -> Void, published: @escaping (String) -> Void) {
        self.api = api
        self.bot = bot
        self.id = id
        self.suggest = suggest
        self.save = save
        self.published = published
        self.requestedPlan = requestedPlan
        self.planApplied = planApplied
        let initial = draft ?? AgentInstagramIntent.draft(from: prompt)
        _draft = State(initialValue: initial)
        _showingLink = State(initialValue: !initial.imageURL.isEmpty)
    }

    private var targetName: String { draft.approvedUsername ?? account?.username ?? "" }
    private var agentQuery: [URLQueryItem] { [URLQueryItem(name: "bot_id", value: bot.id.uuidString)] }
    private var isLocked: Bool { draft.approvedPC != nil }
    private var wrongPC: Bool { isLocked && draft.approvedPC != api?.queueTargetID }
    private var ready: Bool {
        guard let state, ["draft", "preparing", "ready"].contains(state), !wrongPC,
              let account, account.connected, account.accountID?.isEmpty == false,
              !targetName.isEmpty, !busy, !preparingPhoto else { return false }
        if draft.scheduledJob != nil || draft.timing?.isValid == false { return false }
        if let pinned = draft.approvedAccount, account.accountID != pinned { return false }
        return (draft.hasPhoto ? jpeg != nil : AgentInstagramIntent.mediaURL(draft.imageURL) != nil) &&
            draft.caption.unicodeScalars.count <= 2200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = draft.scheduledJob {
                Text(job.summary).textSelection(.enabled)
                if job.state == "scheduled" {
                    Button("Annuller udgivelse", role: .destructive) { cancelling = true }.disabled(busy || wrongPC || api == nil)
                        .confirmationDialog("Annuller det planlagte opslag?", isPresented: $cancelling, titleVisibility: .visible) {
                            Button("Annuller udgivelse", role: .destructive) { cancelSchedule() }
                            Button("Behold opslaget", role: .cancel) {}
                        }
                }
            } else {
                editor
            }
            if let notice { Text(notice).font(.callout) }
            if busy || preparingPhoto { ProgressView() }
            if api != nil {
                Button("Opdatér status", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(busy)
            }
        }
        .privacySensitive()
        .task(id: refresh) { await reload() }
        .task(id: picker) { if let picker { await loadPhoto(picker) } }
        .onChange(of: requestedPlan, initial: true) { _, request in
            guard let request, request.turn == id, !isLocked else { return }
            draft.timing = request.timing
            save(draft)
            planApplied()
        }
        .onChange(of: phase) { _, value in if value == .active, !busy { refresh += 1 } }
        .task(id: draft) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            save(draft)
        }
        .onDisappear { save(draft) }
    }

    @ViewBuilder private var editor: some View {
            if let name = account?.username, account?.connected == true {
                Label("@\(name)", systemImage: "person.crop.circle")
            } else if account?.connected == true {
                FadedDetailText("Instagram har ikke oplyst kontonavnet. Tjek forbindelsen, og opdatér status.")
            } else if api == nil {
                FadedDetailText("Du kan skrive kladden nu. Forbind PC’en for at udgive.")
            } else if account?.connected == false || notice != nil {
                Button("Forbind professionel Instagram-konto") { connect() }.disabled(busy)
            }
            draftFields.disabled(isLocked || busy)
            InstagramTimingFields(timing: $draft.timing).disabled(isLocked || busy)
            Button(draft.timing == nil ? "Udgiv på Instagram" : "Planlæg opslag", systemImage: draft.timing == nil ? "paperplane" : "clock") { confirming = true }
                .disabled(!ready)
            .confirmationDialog((draft.timing == nil ? "Udgiv" : "Planlæg opslag") + " på @\(targetName)?",
                                isPresented: $confirming, titleVisibility: .visible) {
            Button(draft.timing == nil ? "Udgiv nu" : "Godkend tidspunkt og opslag") { submit() }
            Button("Annuller", role: .cancel) {}
        } message: {
            if let timing = draft.timing {
                let source = draft.hasPhoto ? "PC’en gemmer dit valgte foto." : "Instagram henter det foto, som dit link viser på udgivelsestidspunktet."
                let follow = timing.followUp.map { " Opfølgning " + $0.formatted(date: .abbreviated, time: .shortened) + (timing.notifyEmail ? " i chatten og på mail." : " i chatten.") } ?? ""
                Text(source + " Udgives " + timing.publish.formatted(date: .abbreviated, time: .shortened) + "." + follow)
            } else { Text(draft.hasPhoto ? "Det viste foto og din billedtekst sendes til Instagram via PC’en og Composio." :
                    "Fotoet fra dit link og din billedtekst sendes til Instagram via PC’en og Composio.")
            }
        }
    }

    @ViewBuilder private var draftFields: some View {
        if let jpeg, let preview = UIImage(data: jpeg) {
            Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 240)
                .accessibilityLabel("Beskæring som bliver udgivet på Instagram")
            Button("Fjern foto", systemImage: "trash") {
                do {
                    try MigratedAppData.shared.removeInstagramPhoto(id)
                    self.jpeg = nil; picker = nil; draft.hasPhoto = false
                } catch { notice = "Kunne ikke fjerne fotoet fra kladden." }
            }
        }
        PhotosPicker(selection: $picker, matching: .images) {
            Label(jpeg == nil ? "Vælg foto fra iPhone" : "Skift foto", systemImage: "photo")
        }
        if jpeg == nil {
            DisclosureGroup("Brug et billedlink", isExpanded: $showingLink) {
                TextField("Offentligt HTTPS-link til et JPEG-foto", text: $draft.imageURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        TextField("Billedtekst", text: $draft.caption, axis: .vertical)
            .lineLimit(2...8)
        if draft.caption.unicodeScalars.count > 2200 { FadedDetailText("Forkort billedteksten til 2.200 tegn.") }
        HStack {
            TextField("Emne til \(bot.name)", text: $draft.subject)
            Button("Foreslå tekst") { generate() }
                .disabled(draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func generate() {
        guard !busy, !isLocked else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                let text = try await suggest(String(draft.subject.prefix(1200)))
                draft.caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
                save(draft)
            } catch { notice = AppErrorPresentation(error).title }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard !isLocked else { return }
        preparingPhoto = true
        defer { if !Task.isCancelled { preparingPhoto = false } }
        do {
            guard let image = try await item.loadTransferable(type: AgentInstagramPhoto.self) else { throw APIError.malformed }
            try Task.checkCancellation()
            try MigratedAppData.shared.saveInstagramPhoto(image.jpeg, id: id)
            jpeg = image.jpeg
            draft.imageURL = ""
            draft.hasPhoto = true
            save(draft)
        } catch {
            if !Task.isCancelled { notice = "Kunne ikke klargøre fotoet. Vælg et andet billede." }
        }
    }

    private func reload() async {
        if draft.hasPhoto && jpeg == nil {
            jpeg = try? MigratedAppData.shared.instagramPhoto(id)
            if jpeg == nil { notice = "Fotoet mangler på telefonen. Vælg det igen." }
        }
        guard let api, !busy else { return }
        if wrongPC { notice = "Forbind den PC, som godkendelsen blev sendt til."; return }
        state = nil
        do {
            if isLocked, draft.timing != nil {
                let job: AgentInstagramJob = try await api.moduleJSON("composio/instagram/schedule/\(id.uuidString)",
                                                                       timeout: 20, query: agentQuery)
                try Task.checkCancellation()
                if acceptJob(job) { return }
            }
            let receipt: Receipt = try await api.moduleJSON("composio/instagram/receipts/\(id.uuidString)", timeout: 15,
                                                           query: agentQuery)
            try Task.checkCancellation()
            if accept(receipt) { return }
            let profile: Account = try await api.moduleJSON("composio/instagram/status", timeout: 25, query: agentQuery)
            try Task.checkCancellation()
            account = profile
            state = receipt.state
            if receipt.state == "publishing" { notice = "Afventer bekræftelse fra Instagram. Tjek kontoen eller opdatér status." }
            else if isLocked, receipt.state == "draft" {
                draft.approvedPC = nil; draft.approvedAccount = nil; draft.approvedUsername = nil
                notice = "PC’en har ingen registreret udgivelse. Du kan gennemgå kladden igen."
            } else if let pinned = draft.approvedAccount, pinned != profile.accountID {
                notice = "Forbind den konto, du godkendte opslaget til."
            } else if state == "preparing" || state == "ready" {
                notice = "Instagram har modtaget billedet. Du kan fortsætte med samme opslag."
            } else if state == "draft" && (!draft.hasPhoto || jpeg != nil) { notice = nil }
        } catch {
            if !Task.isCancelled { account = nil; state = nil; notice = explanation(error) }
        }
    }

    private func submit() {
        guard ready, let api, let accountID = account?.accountID else { return }
        draft.approvedPC = api.queueTargetID
        draft.approvedAccount = accountID
        draft.approvedUsername = account?.username
        save(draft)
        let body = Submission(id: id, accountID: accountID, caption: draft.caption,
                              imageURL: draft.hasPhoto ? nil : AgentInstagramIntent.mediaURL(draft.imageURL)?.absoluteString,
                              image_jpeg: draft.hasPhoto ? jpeg : nil,
                              publishAt: draft.timing?.publish.timeIntervalSince1970,
                              followUpAt: draft.timing?.followUp?.timeIntervalSince1970,
                              notifyEmail: draft.timing?.notifyEmail)
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                if body.publishAt != nil {
                    let job: AgentInstagramJob = try await api.moduleJSON("composio/instagram/schedule",
                                                                           upload: JSONEncoder().encode(body), timeout: 90, query: agentQuery)
                    guard acceptJob(job) else { throw APIError.malformed }
                    return
                }
                let receipt: Receipt = try await api.moduleJSON("composio/instagram/publish", upload: JSONEncoder().encode(body),
                                                                timeout: 110, query: agentQuery)
                guard accept(receipt) else { throw APIError.malformed }
            } catch {
                state = nil
                notice = explanation(error) + " Tryk på Opdatér status."
            }
        }
    }

    private func acceptJob(_ job: AgentInstagramJob) -> Bool {
        guard job.id == id, job.state != "draft" else { return false }
        notice = nil
        if job.completed { published(job.summary) }
        else {
            draft.scheduledJob = job
            save(draft)
        }
        return true
    }

    private func cancelSchedule() {
        guard let api, !busy, !wrongPC, draft.scheduledJob?.state == "scheduled" else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let job: AgentInstagramJob = try await api.moduleJSON("composio/instagram/schedule/\(id.uuidString)/cancel",
                                                                       upload: Data("{}".utf8), query: agentQuery)
                guard acceptJob(job) else { throw APIError.malformed }
            } catch { notice = explanation(error) }
        }
    }

    private func accept(_ receipt: Receipt) -> Bool {
        guard receipt.confirmed else { return false }
        let account = targetName.isEmpty ? "Instagram" : "@\(targetName)"
        published("Opslaget er udgivet på \(account).")
        return true
    }

    private func connect() {
        guard let api, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let link: ComposioLink = try await api.moduleJSON("composio/instagram/link", upload: Data("{}".utf8),
                                                                 timeout: 65, query: agentQuery)
                guard let host = link.url.host?.lowercased(), link.url.scheme == "https",
                      link.url.user == nil, link.url.password == nil,
                      ["composio.dev", "composio.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                    throw APIError.malformed
                }
                openURL(link.url)
            } catch { notice = explanation(error) }
        }
    }

    private func explanation(_ error: Error) -> String {
        if case APIError.http(let status, let problem) = error {
            if status == 404 { return "Opdatér FadedAI på PC’en for at bruge Instagram." }
            if let detail = problem?.message { return detail }
        }
        return AppErrorPresentation(error).title
    }
}
