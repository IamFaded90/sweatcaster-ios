import SwiftUI
import UniformTypeIdentifiers

struct AgentBuiltTool: Decodable, Identifiable {
    let id: UUID
    let title: String
    let description: String
    let checks: [String]
}

@MainActor struct AgentBuiltTools: View {
    let api: LiveAPI
    var initialBrief = ""
    var buildsOnOpen = false
    @State private var tools: [AgentBuiltTool] = []
    @State private var brief = ""
    @State private var building = false
    @State private var message: String?
    @State private var requestID = UUID()
    @State private var selected: AgentBuiltTool?
    @State private var opened = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Byg et PC-værktøj").font(.headline)
                        Text("Beskriv et værktøj til billeder, filnavne, CSV-kolonner, tekster eller ZIP-pakker. Code Bot bygger og afprøver det, før det bliver gemt.")
                            .font(.callout)
                        TextField("Fx gør mine billeder klar til en annonce og pak dem", text: $brief, axis: .vertical)
                            .lineLimit(2...5).padding(12).fadedGlassSurface()
                            .disabled(building)
                        FadedPrimaryButton(building ? "Bygger og tester…" : "Byg værktøjet", icon: "hammer") { build() }
                            .disabled(building || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.count > 1000)
                        if building { ProgressView("Afprøver på prøvefiler…") }
                    }
                }
                if let message { Text(message).font(.callout) }
                if tools.isEmpty && !building { Text("Dine afprøvede værktøjer kommer her.").foregroundStyle(.secondary) }
                ForEach(tools) { tool in
                    NavigationLink {
                        AgentBuiltToolDetail(api: api, tool: tool, removed: { tools.removeAll { $0.id == tool.id } })
                    } label: {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(tool.title, systemImage: "wrench.and.screwdriver").font(.headline)
                                Text(tool.description).font(.callout)
                                Label("Afprøvet på PC’en", systemImage: "checkmark.seal").font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(FadedSpacing.edge)
        }
        .background { FadedBackground() }
        .navigationTitle("Agenternes værktøjer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { tool in
            AgentBuiltToolDetail(api: api, tool: tool, removed: { tools.removeAll { $0.id == tool.id } })
        }
        .task {
            if brief.isEmpty { brief = initialBrief }
            await load()
            if buildsOnOpen && !opened && !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                opened = true
                build()
            }
        }
        .onChange(of: brief) { _, _ in requestID = UUID() }
    }

    private func load() async {
        struct Library: Decodable { let items: [AgentBuiltTool] }
        do {
            let library: Library = try await api.moduleJSON("agent-tools")
            tools = library.items
            message = nil
        } catch { message = AgentPCFeedback.message(error, fallback: "Kunne ikke hente værktøjerne fra PC’en.") }
    }

    private func build() {
        building = true; message = nil
        let input = ["brief": brief, "requestID": requestID.uuidString.lowercased()]
        Task {
            defer { building = false }
            do {
                let tool: AgentBuiltTool = try await api.moduleJSON("agent-tools/build",
                    upload: JSONEncoder().encode(input), timeout: 180)
                await load()
                selected = tool
            } catch { message = AgentPCFeedback.message(error, fallback: "Værktøjet kunne ikke bestå prøven. Prøv en tydeligere beskrivelse.") }
        }
    }
}

extension AgentBuiltTool: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor private struct AgentBuiltToolDetail: View {
    let api: LiveAPI
    let tool: AgentBuiltTool
    let removed: () -> Void
    struct File: Decodable, Identifiable {
        let index: Int
        let name: String
        let bytes: Int
        var id: Int { index }
    }
    struct Run: Decodable, Identifiable {
        let id: UUID
        let files: [File]
    }
    struct Input: Encodable { let name: String; let data: Data }
    struct Request: Encodable { let requestID: String; let files: [Input] }
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var inputs: [Input] = []
    @State private var runs: [Run] = []
    @State private var busy = false
    @State private var message: String?
    @State private var removing = false
    @State private var share: URL?
    @State private var requestID = UUID()
    @State private var temporaryFiles: [URL] = []
    @State private var operation: Task<Void, Never>?
    private var route: String { "agent-tools/" + tool.id.uuidString.lowercased() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tool.description)
                DisclosureGroup("Sådan er værktøjet afprøvet") {
                    ForEach(Array(tool.checks.enumerated()), id: \.offset) { _, check in
                        Label(check, systemImage: "checkmark")
                    }
                }
                FadedSecondaryButton("Vælg filer", icon: "doc.badge.plus") { importing = true }.disabled(busy)
                ForEach(Array(inputs.enumerated()), id: \.offset) { index, file in
                    HStack {
                        Text(file.name).lineLimit(2)
                        Spacer()
                        Button("Fjern", systemImage: "xmark.circle") {
                            inputs.remove(at: index); requestID = UUID()
                        }.labelStyle(.iconOnly).disabled(busy)
                    }
                }
                FadedPrimaryButton("Brug værktøjet", icon: "play.fill") { run() }
                    .disabled(busy || inputs.isEmpty)
                if busy { ProgressView("Arbejder på PC’en…") }
                if let message { Text(message).font(.callout) }
                if let share { ShareLink("Gem eller del filen", item: share).buttonStyle(.borderedProminent) }
                ForEach(runs) { run in
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Resultat").font(.headline)
                            ForEach(run.files) { file in
                                Button {
                                    download(run: run.id, file: file)
                                } label: {
                                    Label(file.name + " · " + ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file),
                                          systemImage: "square.and.arrow.down")
                                }.disabled(busy)
                            }
                            Button("Slet resultat", systemImage: "trash", role: .destructive) { removeRun(run.id) }
                                .disabled(busy)
                        }
                    }
                }
                Button("Slet værktøj og dets resultater", systemImage: "trash", role: .destructive) { removing = true }
                    .disabled(busy)
            }.padding(FadedSpacing.edge)
        }
        .background { FadedBackground() }
        .navigationTitle(tool.title).navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                var added: [Input] = []
                var total = inputs.reduce(0) { $0 + $1.data.count }
                guard inputs.count + urls.count <= 20 else { throw ImportError.tooLarge }
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size >= 0, total + size <= 24_000_000 else { throw ImportError.tooLarge }
                    let data = try readInput(url, limit: 24_000_000 - total)
                    total += data.count
                    guard total <= 24_000_000 else { throw ImportError.tooLarge }
                    added.append(Input(name: url.lastPathComponent, data: data))
                }
                guard Set((inputs + added).map(\.name)).count == inputs.count + added.count else { throw ImportError.sameName }
                inputs.append(contentsOf: added); requestID = UUID()
            } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Slet værktøjet og dets gemte resultater?", isPresented: $removing) {
            Button("Slet", role: .destructive) { removeTool() }
            Button("Annuller", role: .cancel) {}
        }
        .task { await loadRuns() }
        .onDisappear { operation?.cancel(); cleanTemporaryFiles() }
    }

    private func loadRuns() async {
        struct Library: Decodable { let items: [Run] }
        do {
            let value: Library = try await api.moduleJSON(route + "/runs")
            runs = value.items
            message = nil
        } catch { message = AgentPCFeedback.message(error, fallback: "Resultaterne kunne ikke hentes.") }
    }

    private func run() {
        busy = true; message = nil
        let body = Request(requestID: requestID.uuidString.lowercased(), files: inputs)
        operation = Task {
            defer { busy = false }
            do {
                let _: Run = try await api.moduleJSON(route + "/run", upload: JSONEncoder().encode(body), timeout: 120)
                try Task.checkCancellation()
                inputs = []; requestID = UUID()
                await loadRuns()
            } catch { message = AgentPCFeedback.message(error, fallback: "Værktøjet kunne ikke behandle filerne.") }
        }
    }

    private func download(run: UUID, file: File) {
        struct Download: Decodable { let name: String; let data: Data }
        busy = true; message = nil
        operation = Task {
            defer { busy = false }
            do {
                let value: Download = try await api.moduleJSON("agent-tools/runs/" + run.uuidString.lowercased()
                    + "/files/\(file.index)/data", timeout: 30, maximumBytes: 65_000_000)
                try Task.checkCancellation()
                guard value.name == file.name, value.data.count == file.bytes else { throw ImportError.invalidFile }
                cleanTemporaryFiles()
                let folder = FileManager.default.temporaryDirectory.appending(path: "agent-tool-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                temporaryFiles = [folder]
                let destination = folder.appending(path: URL(fileURLWithPath: value.name).lastPathComponent)
                try value.data.write(to: destination, options: .atomic)
                share = destination
            } catch { message = AgentPCFeedback.message(error, fallback: "Filen kunne ikke hentes.") }
        }
    }

    private func removeRun(_ id: UUID) {
        action("agent-tools/runs/" + id.uuidString.lowercased() + "/remove") {
            runs.removeAll { $0.id == id }; cleanTemporaryFiles()
        }
    }

    private func removeTool() {
        action(route + "/remove") { removed(); cleanTemporaryFiles(); dismiss() }
    }

    private func action(_ path: String, complete: @escaping () -> Void) {
        struct Receipt: Decodable { let removed: Bool }
        busy = true; message = nil
        operation = Task {
            defer { busy = false }
            do {
                let receipt: Receipt = try await api.moduleJSON(path, upload: Data("{}".utf8))
                try Task.checkCancellation()
                guard receipt.removed else { throw ImportError.invalidFile }
                complete()
            } catch { message = AgentPCFeedback.message(error, fallback: "Sletningen blev ikke bekræftet.") }
        }
    }

    private func cleanTemporaryFiles() {
        share = nil
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
    }

    private func readInput(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let block = try handle.read(upToCount: min(1_000_000, limit - data.count + 1)), !block.isEmpty {
            guard data.count + block.count <= limit else { throw ImportError.tooLarge }
            data.append(block)
        }
        return data
    }

    private enum ImportError: LocalizedError {
        case tooLarge, sameName, invalidFile
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Vælg højst 20 filer og tilsammen højst 24 MB."
            case .sameName: "To filer har samme navn. Vælg dem i hver sin kørsel."
            case .invalidFile: "Resultatet passer ikke med filen på PC’en."
            }
        }
    }
}
