import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor struct AgentRoomView: View {
    let api: LiveAPI?
    let bot: VillageBot
    var prompt = ""
    var onResult: (String) -> Void = { _ in }
    @State private var store = AgentRoomStore()
    @State private var title = "Mit rum"
    @State private var brief = ""
    @State private var sketch: Data?
    @State private var choosingSketch = false
    @State private var selectedFigures: Set<UUID> = []
    @State private var selectedRoom: AgentRoom?
    @State private var imageError: String?
    @Environment(\.fadedPalette) private var palette

    private var roster: [VillageBot] {
        let saved = VillageBot.list(from: MigratedAppData.shared.villageBots)
        return [bot] + saved.filter { $0.id != bot.id }
    }
    private var figures: [VillageBot] { roster.filter { selectedFigures.contains($0.id) } }
    private var canBuild: Bool {
        api != nil && !store.busy && sketch != nil && !figures.isEmpty &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        title.count <= 90 && brief.count <= 390
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.action) {
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Byg et rum fra din skitse").font(.title2.bold())
                        TextField("Rummets navn", text: $title).textFieldStyle(.roundedBorder)
                        if title.count > 90 { FadedDetailText("Brug højst 90 tegn i rummets navn.") }
                        sketchPicker
                        TextField("Hvordan skal rummet være?", text: $brief, axis: .vertical)
                            .lineLimit(3...7).textFieldStyle(.roundedBorder).frame(minHeight: 70)
                        if brief.count > 390 {
                            FadedDetailText("Forkort beskrivelsen til højst 390 tegn.")
                        }
                        figurePicker
                        if let imageError { FadedDetailText(imageError) }
                        FadedPrimaryButton(store.busy ? "Sender til PC’en…" : "Byg rummet", icon: "square.grid.3x3") {
                            create()
                        }
                        .disabled(!canBuild)
                    }
                }
                if let message = store.message { FadedDetailText(message) }
                savedRooms
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle("Mine agentrum")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: api?.queueTargetID) {
            if brief.isEmpty { brief = prompt }
            if selectedFigures.isEmpty { selectedFigures = [bot.id] }
            await store.load(api: api, botID: bot.id)
        }
        .fileImporter(isPresented: $choosingSketch, allowedContentTypes: [.jpeg, .png], onCompletion: chooseSketch)
        .sheet(item: $selectedRoom, onDismiss: reload) { room in
            NavigationStack { AgentRoomEditor(room: room, api: api, onResult: onResult) }
        }
    }

    private var sketchPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sketch, let image = UIImage(data: sketch) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: FadedRadius.medium))
                    .accessibilityLabel("Din valgte skitse")
            }
            FadedSecondaryButton(sketch == nil ? "Vælg skitse" : "Skift skitse", icon: "photo") { choosingSketch = true }
                .disabled(store.busy)
        }
    }

    private var figurePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Figurer i rummet · \(selectedFigures.count)/8").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                ForEach(roster) { profile in
                    let chosen = selectedFigures.contains(profile.id)
                    Button {
                        if chosen { selectedFigures.remove(profile.id) }
                        else if selectedFigures.count < 8 { selectedFigures.insert(profile.id) }
                    } label: {
                        Label(profile.name, systemImage: chosen ? "checkmark.circle.fill" : "circle")
                            .lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 8).fadedGlassSurface()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .disabled(store.busy || (!chosen && selectedFigures.count == 8))
                }
            }
        }
    }

    private var savedRooms: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dine rum").font(.headline).accessibilityAddTraits(.isHeader)
            if store.rooms.isEmpty { FadedDetailText("Dine rum vises her, når den første skitse er sendt.") }
            ForEach(store.rooms) { room in
                Button { selectedRoom = room } label: {
                    FadedCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(room.title).font(.headline)
                                Text(room.state.title).font(.caption).foregroundStyle(palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.frame(minHeight: 44)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func create() {
        guard canBuild, let sketch else { return }
        Task {
            selectedRoom = await store.create(api: api, bot: bot, title: title, brief: brief, sketch: sketch, figures: figures)
        }
    }

    private func chooseSketch(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try LocalFileStore.readBytes(from: url, maximumBytes: 12_000_000)
            sketch = try AgentRoomImages.sketch(bytes)
            imageError = nil
        } catch { imageError = AgentRoomFailure.image.localizedDescription }
    }

    private func reload() { Task { await store.load(api: api, botID: bot.id) } }
}

@MainActor struct AgentRoomEditor: View {
    let room: AgentRoom
    let api: LiveAPI?
    var onResult: (String) -> Void = { _ in }
    @State private var store = AgentRoomStore()
    @State private var revision: Int?
    @State private var figureID: UUID?
    @State private var scale = 1.0
    @State private var instruction = ""
    @State private var compare = false
    @State private var expanded = false
    @State private var confirmRemove = false
    @State private var hotspot: AgentRoom.Hotspot?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.fadedPalette) private var palette

    private var current: AgentRoom { store.current ?? room }
    private var version: AgentRoom.Version? {
        current.versions.first { $0.revision == revision } ?? current.current ?? current.published
    }
    private var figure: AgentRoom.Figure? { version?.figures.first { $0.id == figureID } }
    private var online: Bool { api != nil && !store.offline }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                status
                if let version {
                    preview(version)
                    versions
                    figures(version)
                    if online { editing(version) }
                    if compare, let first = current.versions.first, first.revision != version.revision {
                        comparison(first)
                    }
                    if !version.checks.isEmpty {
                        DisclosureGroup("PC’ens kontrol") {
                            ForEach(version.checks, id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
                if let message = store.message { FadedDetailText(message) }
                if online && version != nil { publishing }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        .task(id: api?.queueTargetID) {
            await store.load(api: api, botID: room.botID)
            if let loaded = store.rooms.first(where: { $0.id == room.id }) { store.select(loaded) }
            else if api != nil && !store.offline { dismiss(); return }
            else { store.select(room) }
            await loadArtwork()
        }
        .task(id: "\(current.state.rawValue):\(phase == .active)") {
            guard current.state.busy, phase == .active else { return }
            while !Task.isCancelled {
                await store.refresh(api: api)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: version?.artwork) { await loadArtwork() }
        .onChange(of: figureID) { _, _ in scale = figure?.scale ?? 1 }
        .onChange(of: version?.revision) { _, _ in scale = figure?.scale ?? 1 }
        .fullScreenCover(isPresented: $expanded) {
            if let version {
                AgentRoomFullScreen(room: current, version: version, artwork: store.images[version.artwork],
                                    onSelectFigure: { figureID = $0 })
            }
        }
        .confirmationDialog("Fjern rummet?", isPresented: $confirmRemove) {
            Button("Fjern rummet", role: .destructive) {
                Task {
                    if await store.remove(api: api) { onResult("Rummet er fjernet."); dismiss() }
                }
            }
        } message: { Text("Rummet og den gemte kopi på telefonen fjernes.") }
        .alert(hotspot?.title ?? "I rummet", isPresented: Binding(
            get: { hotspot != nil }, set: { if !$0 { hotspot = nil } }
        )) { Button("OK", role: .cancel) { hotspot = nil } }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.state.title).font(.headline)
            if current.state.busy {
                ProgressView()
                FadedDetailText("Du kan lukke siden. PC’en arbejder videre på rummet.")
            }
            if let notice = current.notice { FadedDetailText(notice) }
            if store.offline { FadedDetailText("Gemt rum på telefonen. Forbind til PC’en for at ændre det.") }
            if current.state == .failed && online {
                FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { Task { await store.retry(api: api) } }
                    .disabled(store.busy)
            }
        }
    }

    private func preview(_ version: AgentRoom.Version) -> some View {
        let selection: UUID? = if case .adjustment(let adjustment) = AgentRoomRevisionIntent.resolve(instruction, figures: version.figures) {
            adjustment.figureID
        } else { figureID }
        return VStack(spacing: 8) {
            AgentRoomCanvas(version: version, artwork: store.images[version.artwork], selectedFigure: selection,
                            onSelectFigure: { figureID = $0 }, onSelectHotspot: { hotspot = $0 })
            FadedSecondaryButton("Prøv i fuld størrelse", icon: "arrow.up.left.and.arrow.down.right") { expanded = true }
        }
    }

    private var versions: some View {
        Picker("Version", selection: Binding(get: { version?.revision ?? 0 }, set: { revision = $0 })) {
            ForEach(current.versions) { item in
                Text("Version \(item.revision)" + (item.revision == current.publishedRevision ? " · gemt" : ""))
                    .tag(item.revision)
            }
        }.frame(minHeight: 44)
    }

    private func figures(_ version: AgentRoom.Version) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vælg en figur").font(.headline)
            ForEach(version.figures) { item in
                Button { figureID = item.id } label: {
                    Label(item.name, systemImage: figureID == item.id ? "checkmark.circle.fill" : "person")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 10).fadedGlassSurface()
                }
                .buttonStyle(.plain).accessibilityAddTraits(figureID == item.id ? .isSelected : [])
            }
        }
    }

    private func editing(_ version: AgentRoom.Version) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Fx Gør Adam større og behold lyset", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                if instruction.count > 250 { FadedDetailText("Forkort justeringen til højst 250 tegn.") }
                let resolution = AgentRoomRevisionIntent.resolve(instruction, figures: version.figures)
                if case .adjustment(let change) = resolution {
                    FadedDetailText(change.summary)
                    FadedSecondaryButton("Lav ny version for \(change.name)", icon: "slider.horizontal.3") {
                        revise(version, figure: change.figureID, scale: change.scale, description: instruction)
                    }
                    .disabled(store.busy || current.state.busy || instruction.count > 250)
                } else {
                    if case .unsupported(let reason) = resolution { FadedDetailText(reason) }
                    if let figure {
                        Text("Juster \(figure.name)").font(.headline)
                        Slider(value: $scale, in: 0.7...1.65, step: 0.05).accessibilityLabel("Figurens størrelse")
                        Text("Størrelse \(Int(scale * 100)) %").font(.caption.monospacedDigit())
                        FadedSecondaryButton("Brug sliderens størrelse", icon: "slider.horizontal.3") {
                            let size = min(1.65, max(0.7, scale))
                            revise(version, figure: figure.id, scale: size,
                                   description: "Juster \(figure.name) til \(Int(size * 100)) procent størrelse.")
                        }
                        .disabled(store.busy || current.state.busy || abs(scale - figure.scale) < 0.001)
                    } else { FadedDetailText("Tryk på en figur for at justere dens størrelse.") }
                }
                Toggle("Sammenlign med den første version", isOn: $compare).frame(minHeight: 44)
            }
        }
    }

    private func revise(_ version: AgentRoom.Version, figure: UUID, scale: Double, description: String) {
        Task {
            await store.revise(api: api, revision: version.revision, figureID: figure, scale: scale, instruction: description)
            if store.current?.revision != version.revision {
                revision = nil
                figureID = figure
                instruction = ""
            }
        }
    }

    private func comparison(_ original: AgentRoom.Version) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Første version").font(.headline)
            AgentRoomCanvas(version: original, artwork: store.images[original.artwork])
        }
        .task(id: original.artwork) { await store.image(room: current, version: original, api: api) }
    }

    private var publishing: some View {
        VStack(spacing: 10) {
            FadedPrimaryButton("Behold denne version", icon: "checkmark") {
                guard let version else { return }
                Task {
                    await store.publish(api: api, revision: version.revision)
                    if store.current?.publishedRevision == version.revision {
                        onResult("Rummet “\(current.title)” er gemt i landsbyen.")
                    }
                }
            }.disabled(store.busy || current.state.busy || version?.revision == current.publishedRevision)
            FadedSecondaryButton("Fjern rummet", icon: "trash", role: .destructive) { confirmRemove = true }
                .disabled(store.busy || current.state.busy)
        }
    }

    private func loadArtwork() async {
        if let version { await store.image(room: current, version: version, api: api) }
    }
}
