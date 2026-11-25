import SwiftUI

@MainActor struct AgentRoomPublishedView: View {
    let api: LiveAPI?
    var onOpenBot: (UUID) -> Void = { _ in }
    @State private var store = AgentRoomStore()
    @State private var attempt = 0

    var body: some View {
        List {
            if let message = store.message { Section { FadedDetailText(message) } }
            Section("Mine agentrum") {
                if store.rooms.isEmpty {
                    FadedDetailText("Byg et rum fra en skitse i en bots chat. Når du beholder det, vises det her.")
                }
                ForEach(store.rooms.filter { $0.published != nil }) { room in
                    NavigationLink {
                        AgentRoomPublishedRoom(room: room, api: api, onOpenBot: onOpenBot)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(room.title).font(.headline)
                            Text("\(room.published?.figures.count ?? 0) figurer · version \(room.publishedRevision ?? 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Mine agentrum").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(api?.queueTargetID ?? ""):\(attempt)") { await store.load(api: api, published: true) }
        .refreshable { attempt += 1 }
    }
}

@MainActor private struct AgentRoomPublishedRoom: View {
    let room: AgentRoom
    let api: LiveAPI?
    let onOpenBot: (UUID) -> Void
    @State private var store = AgentRoomStore()
    @State private var editing = false
    @State private var expanded = false
    @State private var selectedFigure: UUID?
    @State private var hotspot: AgentRoom.Hotspot?
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    private var current: AgentRoom { store.current ?? room }
    private var version: AgentRoom.Version? { current.published ?? room.published }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let version {
                    AgentRoomCanvas(version: version, artwork: store.images[version.artwork],
                                    selectedFigure: selectedFigure, onSelectFigure: selectFigure,
                                    onSelectHotspot: selectHotspot, ambienceScene: VillageAmbience.room(current.id))
                    VillageAmbienceButton(scene: VillageAmbience.room(current.id), title: current.title)
                    RoomWorksPanel(scene: VillageAmbience.room(current.id))
                    FadedSecondaryButton("Åbn rummet i fuld størrelse", icon: "arrow.up.left.and.arrow.down.right") {
                        expanded = true
                    }
                    ForEach(version.figures) { figure in
                        Button { selectedFigure = figure.id; onOpenBot(figure.id) } label: {
                            Label(figure.name, systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 10).fadedGlassSurface()
                        }.buttonStyle(.plain)
                    }
                    ForEach(version.hotspots) { spot in
                        Button(spot.title) { selectHotspot(spot) }.frame(minHeight: 44)
                    }
                }
                if let message = store.message { FadedDetailText(message) }
                if (api != nil && !store.offline) || AgentPhoneRoomEditor.isLocal(current) {
                    FadedSecondaryButton("Juster rummet", icon: "slider.horizontal.3") { editing = true }
                }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
        .modifier(VillageAmbienceLifecycle(scene: VillageAmbience.room(current.id)))
        .task(id: "\(api?.queueTargetID ?? ""):\(attempt)") {
            await store.load(api: api, published: true)
            if api != nil && !store.offline && !store.rooms.contains(where: { $0.id == room.id }) {
                dismiss()
                return
            }
            store.select(store.rooms.first(where: { $0.id == room.id }) ?? room)
            if let version { await store.image(room: current, version: version, api: api) }
        }
        .fullScreenCover(isPresented: $expanded) {
            if let version {
                AgentRoomFullScreen(room: current, version: version, artwork: store.images[version.artwork],
                                    onOpenBot: onOpenBot)
            }
        }
        .sheet(isPresented: $editing, onDismiss: { attempt += 1 }) {
            NavigationStack { AgentRoomEditor(room: current, api: api) }
        }
        .alert(hotspot?.title ?? "I rummet", isPresented: Binding(
            get: { hotspot != nil }, set: { if !$0 { hotspot = nil } }
        )) { Button("OK", role: .cancel) { hotspot = nil } }
    }

    private func selectFigure(_ id: UUID) { selectedFigure = id; onOpenBot(id) }
    private func selectHotspot(_ spot: AgentRoom.Hotspot) {
        if spot.action == .bot, let id = spot.botID { onOpenBot(id) }
        else { hotspot = spot }
    }
}
