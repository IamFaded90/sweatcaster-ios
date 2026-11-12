// Adam or Eva's own desk. Tapping the bot in Landsbyen opens this screen directly.

import SwiftUI
import UIKit

@MainActor final class BotComputerScreenModel: ObservableObject {
    @Published var link: BotComputerLink
    @Published var tasks: [BotComputerTask] = []
    @Published var files: [BotComputerFile] = []
    @Published var frame: Data?
    @Published var live = false
    @Published var control = false
    @Published var notice: String?
    @Published var openFile: BotComputerFile?
    @Published var openTask: BotComputerTask?
    let bot: VillageBot
    private let session: BotComputerSession

    func appear() async {
        await session.refresh(botID: bot.id.uuidString.lowercased())
        reload()
        if link == .online {
            do {
                let started = try await sessionStart()
                session.note(started)
                live = started == .online
            } catch {
                let failed = BotComputerSession.link(for: error)
                session.note(failed)
                live = false
            }
            reload()
        }
    }

    func give(_ instruction: String, key: String) async {
        let result = await session.give(botID: bot.id.uuidString.lowercased(), name: bot.name,
                                        instruction: instruction, key: key, inputPath: nil)
        reload()
        if case .failure(let error) = result { notice = message(for: error) }
    }

    func cancel(_ id: String) async {
        _ = await session.cancel(id: id)
        reload()
    }

    func retry(_ id: String, key: String) async {
        _ = await session.retry(id: id, retryKey: key)
        reload()
    }

    func showFile(ownerID: String, path: String) async {
        do {
            openFile = try await session.openFile(readerID: bot.id.uuidString.lowercased(), ownerID: ownerID, path: path)
            notice = nil
        } catch let error as BotComputerFailure {
            openFile = nil
            notice = message(for: error)
        } catch {
            notice = "Filen kunne ikke åbnes."
        }
        reload()
    }

    func share(path: String, with readerID: String) async {
        do {
            _ = try await session.share(ownerID: bot.id.uuidString.lowercased(), path: path, with: readerID, approved: true)
            notice = "Filen er delt."
        } catch let error as BotComputerFailure {
            notice = message(for: error)
        } catch {
            notice = "Filen kunne ikke deles."
        }
        reload()
    }

    func refreshFrame() async {
        guard live, link == .online else { return }
        do {
            frame = try await sessionFrame()
        } catch let error as BotComputerFailure {
            notice = message(for: error)
            if error == .pcOffline || error == .dockerOffline { live = false }
        } catch {
            live = false
        }
        reload()
    }

    func click(x: Double, y: Double) async {
        guard control, live else { return }
        do { try await sessionClick(x: x, y: y) }
        catch let error as BotComputerFailure { notice = message(for: error) }
        catch { notice = "Styringen nåede ikke skrivebordet." }
    }

    func pollTasks() async {
        await session.refresh(botID: bot.id.uuidString.lowercased())
        reload()
    }

    func stopLive() { live = false }

    private func sessionStart() async throws -> BotComputerLink {
        let transportLink = try await startTransport()
        link = transportLink
        return transportLink
    }

    private let starter: (String, String) async throws -> BotComputerLink
    private let framer: (String, String) async throws -> Data
    private let clicker: (String, String, Double, Double, Bool) async throws -> Void

    init(bot: VillageBot, session: BotComputerSession,
         starter: @escaping (String, String) async throws -> BotComputerLink,
         framer: @escaping (String, String) async throws -> Data,
         clicker: @escaping (String, String, Double, Double, Bool) async throws -> Void) {
        self.bot = bot
        self.session = session
        self.starter = starter
        self.framer = framer
        self.clicker = clicker
        link = session.office.link
        reload()
    }

    convenience init(bot: VillageBot, transport: any BotComputerTransport, directory: URL) {
        let session = BotComputerSession(directory: directory, transport: transport)
        self.init(bot: bot, session: session,
                  starter: { botID, name in try await transport.startDesktop(botID: botID, name: name) },
                  framer: { botID, name in try await transport.frame(botID: botID, name: name) },
                  clicker: { botID, name, x, y, approved in
                      try await transport.click(botID: botID, name: name, x: x, y: y, approved: approved)
                  })
    }

    private func startTransport() async throws -> BotComputerLink {
        try await starter(bot.id.uuidString.lowercased(), bot.name)
    }

    private func sessionFrame() async throws -> Data {
        try await framer(bot.id.uuidString.lowercased(), bot.name)
    }

    private func sessionClick(x: Double, y: Double) async throws {
        try await clicker(bot.id.uuidString.lowercased(), bot.name, x, y, true)
    }

    private func reload() {
        let id = bot.id.uuidString.lowercased()
        link = session.office.link
        tasks = session.office.tasks.filter { $0.botID == id }.sorted { $0.created > $1.created }
        files = session.office.visibleFiles(readerID: id)
        if let openTask, let fresh = tasks.first(where: { $0.id == openTask.id }) { self.openTask = fresh }
    }

    private func message(for error: BotComputerFailure) -> String {
        switch error {
        case .isolated: "Den fil er ikke delt med \(bot.name)."
        case .rejected(let text): text
        case .pcOffline: BotComputerLink.pcOffline.detail
        case .dockerOffline: BotComputerLink.dockerOffline.detail
        case .moduleMissing: BotComputerLink.moduleMissing.detail
        }
    }
}

@MainActor struct BotComputerScreen: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: BotComputerScreenModel
    @State private var panel: Panel?
    @State private var instruction = ""
    @State private var pendingKey: String?
    @State private var retryKeys: [String: String] = [:]
    @State private var confirmControl = false
    @State private var shareTarget: ShareTarget?
    let others: [VillageBot]
    let onClose: () -> Void

    init(bot: VillageBot, others: [VillageBot], api: LiveAPI?, directory: URL? = nil, onClose: @escaping () -> Void) {
        self.others = others
        self.onClose = onClose
        let transport: any BotComputerTransport = api.map { LiveBotComputerTransport(api: $0) } ?? OfflineBotComputerTransport()
        _model = StateObject(wrappedValue: BotComputerScreenModel(bot: bot, transport: transport,
                                                                  directory: directory ?? BotComputerDisk.defaultDirectory))
    }

    private enum Panel: String, Identifiable {
        case tasks, files
        var id: String { rawValue }
    }

    private struct ShareTarget: Identifiable {
        let path: String
        let reader: VillageBot
        var id: String { path + reader.id.uuidString }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                desk
                VStack(spacing: FadedSpacing.s) {
                    if model.link != .online {
                        Text(model.link.title).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(FadedSpacing.m)
                            .fadedGlassSurface(radius: FadedRadius.medium)
                            .accessibilityLabel(model.link.title + ". " + model.link.detail)
                    }
                    Spacer(minLength: 0).allowsHitTesting(false)
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(FadedSpacing.m)
                            .fadedGlassSurface()
                    }
                    if panel == .tasks { taskPanel }
                    if panel == .files { filePanel }
                    controls
                }
                .padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .terminal) }
            .foregroundStyle(palette.text)
            .navigationTitle("\(model.bot.name)s computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onClose)
                }
            }
        }
        .task {
            await model.appear()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await model.pollTasks()
            }
        }
        .task(id: model.live) {
            guard model.live else { return }
            while !Task.isCancelled && model.live {
                await model.refreshFrame()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stopLive() }
        }
        .confirmationDialog("Overtag styring", isPresented: $confirmControl, titleVisibility: .visible) {
            Button("Godkend") { model.control = true }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Du overtager \(model.bot.name)s skrivebord. Det sker kun, fordi du godkender det.")
        }
        .confirmationDialog("Del fil", isPresented: Binding(get: { shareTarget != nil }, set: { if !$0 { shareTarget = nil } }), titleVisibility: .visible) {
            Button("Godkend") {
                if let shareTarget { Task { await model.share(path: shareTarget.path, with: shareTarget.reader.id.uuidString.lowercased()) } }
            }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Filen deles først, når du godkender det.")
        }
    }

    private var desk: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: FadedRadius.media).fill(FadedColors.terminal)
                if model.live, let frame = model.frame, let image = UIImage(data: frame) {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                        .accessibilityLabel("Live skrivebord for \(model.bot.name)")
                } else {
                    VStack(spacing: FadedSpacing.s) {
                        Image(systemName: "desktopcomputer").font(.largeTitle)
                        Text(model.bot.name).font(FadedTypography.title)
                        Text(model.live ? "Henter skrivebordet…" : "Skrivebordet er klar.")
                            .font(.subheadline).foregroundStyle(palette.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FadedRadius.media))
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard model.control, panel == nil, let image = model.frame.flatMap(UIImage.init(data:)) else { return }
                guard let point = BotComputerPointer.normalized(
                    tapX: value.location.x, tapY: value.location.y,
                    viewWidth: geometry.size.width, viewHeight: geometry.size.height,
                    imageWidth: image.size.width, imageHeight: image.size.height) else { return }
                Task { await model.click(x: point.x, y: point.y) }
            })
        }
        .padding(FadedSpacing.edge)
        .allowsHitTesting(panel == nil)
    }

    private var controls: some View {
        VStack(spacing: FadedSpacing.s) {
            HStack(spacing: FadedSpacing.s) {
                glassButton(model.live ? "Skjul live" : "Se live", icon: "eye") {
                    model.live.toggle()
                    if !model.live { model.control = false }
                }
                glassButton(model.control ? "Du styrer" : "Overtag styring", icon: "hand.point.up.left") {
                    if model.control { model.control = false } else { confirmControl = true }
                }
            }
            HStack(spacing: FadedSpacing.s) {
                glassButton("Opgaver", icon: "checklist") { panel = panel == .tasks ? nil : .tasks }
                glassButton("Filer", icon: "folder") { panel = panel == .files ? nil : .files }
            }
        }
    }

    private func glassButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(palette.text)
                .fadedGlassSurface(radius: FadedRadius.medium)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            TextField("Opgave til \(model.bot.name)", text: $instruction, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .padding(FadedSpacing.s)
                .fadedGlassSurface()
            Button("Giv opgave") { submit() }
                .buttonStyle(FadedButtonStyle(kind: .primary))
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(model.tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.instruction).font(.subheadline).lineLimit(2)
                    Text(task.status.title).font(.caption.weight(.semibold))
                    if task.status == .done {
                        Button("Åbn resultat") { model.openTask = task }
                    }
                    if task.status == .waiting || task.status == .running {
                        Button("Annuller", role: .destructive) { Task { await model.cancel(task.id) } }
                    }
                    if task.status == .failed {
                        Button("Prøv igen") { retry(task) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FadedSpacing.s)
                .fadedGlassSurface()
            }
            if let openTask = model.openTask, openTask.status == .done {
                Text(openTask.resultText ?? "Resultatet er tomt.")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FadedSpacing.s)
                    .fadedGlassSurface()
                    .accessibilityLabel("Resultat")
            }
        }
        .padding(FadedSpacing.s)
        .fadedGlassSurface(radius: FadedRadius.card)
    }

    private var filePanel: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            if model.files.isEmpty {
                Text("Ingen filer endnu.").font(.subheadline)
            }
            ForEach(model.files) { file in
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.path).font(.subheadline.weight(.semibold))
                    Text(file.ownerID == model.bot.id.uuidString.lowercased() ? "Egen fil" : "Delt fra \(file.ownerName)")
                        .font(.caption).foregroundStyle(palette.secondary)
                    Button("Åbn") { Task { await model.showFile(ownerID: file.ownerID, path: file.path) } }
                    if file.ownerID == model.bot.id.uuidString.lowercased() {
                        ForEach(others) { other in
                            Button("Del med \(other.name)") { shareTarget = ShareTarget(path: file.path, reader: other) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FadedSpacing.s)
                .fadedGlassSurface()
            }
            if let openFile = model.openFile {
                Text(openFile.text).font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FadedSpacing.s)
                    .fadedGlassSurface()
            }
        }
        .padding(FadedSpacing.s)
        .fadedGlassSurface(radius: FadedRadius.card)
    }

    private func submit() {
        let key = pendingKey ?? UUID().uuidString.lowercased()
        pendingKey = key
        let text = instruction
        Task {
            await model.give(text, key: key)
            if model.tasks.contains(where: { $0.idempotencyKey == key }) {
                instruction = ""
                pendingKey = nil
            }
        }
    }

    private func retry(_ task: BotComputerTask) {
        let key = retryKeys[task.id] ?? UUID().uuidString.lowercased()
        retryKeys[task.id] = key
        Task {
            await model.retry(task.id, key: key)
            let status = model.tasks.first { $0.id == task.id }?.status
            if status != .waiting && status != .running { retryKeys[task.id] = nil }
        }
    }
}
