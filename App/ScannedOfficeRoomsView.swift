import AVFoundation
import QuickLook
import RoomPlan
import SwiftUI

@MainActor struct ScannedOfficeRoomsView: View {
    let bots: [VillageLifeBot]
    @State private var rooms: [ScannedOfficeRoom] = []
    @State private var capturing = false
    @State private var requestingCamera = false
    @State private var selected: ScannedOfficeRoom?
    @State private var removal: ScannedOfficeRoom?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                if RoomCaptureSession.isSupported {
                    Button("Scan mit værelse", systemImage: "viewfinder") { begin() }
                        .frame(minHeight: 44)
                        .disabled(requestingCamera || rooms.count >= ScannedOfficeStore.limit)
                    if rooms.count >= ScannedOfficeStore.limit { FadedDetailText("Du kan gemme op til seks rum.") }
                } else {
                    FadedDetailText("Rumscanning kræver en iPhone eller iPad med LiDAR.")
                }
                if let failure { FadedDetailText(failure) }
            }
            Section("Mine rum") {
                if rooms.isEmpty { FadedDetailText("Gem en scanning for at få et rum, du kan indrette.") }
                ForEach(rooms) { room in
                    Button {
                        selected = room
                    } label: {
                        Label(room.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "cube")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .swipeActions {
                        Button("Slet", systemImage: "trash", role: .destructive) { removal = room }
                    }
                    .accessibilityAction(named: Text("Slet rum")) { removal = room }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Mine rum")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .fullScreenCover(isPresented: $capturing, onDismiss: load) {
            ScannedOfficeCapture { _ in failure = nil }
        }
        .sheet(item: $selected, onDismiss: load) { room in
            ScannedOfficeLayoutView(room: room, bots: bots)
        }
        .confirmationDialog("Slet rum og scanning?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { room in
            Button("Slet rum", role: .destructive) { remove(room) }
        }
    }

    private func load() {
        do { rooms = try ScannedOfficeStore.rooms() }
        catch { failure = "Rummene kunne ikke læses. Prøv igen, mens telefonen er låst op." }
    }

    private func begin() {
        guard !requestingCamera, RoomCaptureSession.isSupported, rooms.count < ScannedOfficeStore.limit else { return }
        requestingCamera = true
        Task {
            defer { requestingCamera = false }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let permitted = status == .authorized
            if permitted {
                failure = nil
                capturing = true
            } else if status == .notDetermined, await AVCaptureDevice.requestAccess(for: .video) {
                failure = nil
                capturing = true
            } else {
                failure = "Giv FadedAI adgang til kameraet i Indstillinger for at scanne."
            }
        }
    }

    private func remove(_ room: ScannedOfficeRoom) {
        do {
            try ScannedOfficeStore.remove(room.id)
            failure = nil
            load()
        } catch { failure = "Rummet kunne ikke slettes. Prøv igen." }
    }
}

@MainActor private struct ScannedOfficeLayoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var room: ScannedOfficeRoom
    let bots: [VillageLifeBot]
    @State private var selection: UUID?
    @State private var preview: URL?
    @State private var failure: String?
    @GestureState private var drag: CGSize = .zero

    init(room: ScannedOfficeRoom, bots: [VillageLifeBot]) {
        _room = State(initialValue: room)
        self.bots = bots
    }

    private var selected: ScannedOfficeRoom.Item? { room.items.first { $0.id == selection && !$0.wall } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    FadedDetailText("Træk et møbel eller en bot for at indrette. Scanningen kan åbnes i 3D.")
                    plan.frame(height: 360)
                    if let selected {
                        selectedTools(selected)
                    }
                    if let failure { FadedDetailText(failure) }
                    Menu("Placér en bot", systemImage: "person.crop.circle.badge.plus") {
                        ForEach(bots) { bot in
                            Button(bot.displayName) { place(bot) }
                        }
                    }
                    .frame(minHeight: 44).disabled(bots.isEmpty)
                    Button("Se original scanning i 3D", systemImage: "cube") {
                        preview = ScannedOfficeStore.modelURL(room.id)
                    }.frame(minHeight: 44)
                    ShareLink(item: ScannedOfficeStore.modelURL(room.id)) {
                        Label("Del USDZ-fil", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                }
                .frame(maxWidth: 640)
                .padding(FadedSpacing.edge)
                .frame(maxWidth: .infinity)
            }
            .background { FadedBackground(variant: .village) }
            .navigationTitle("Indret rummet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .quickLookPreview($preview)
            .privacySensitive()
        }
    }

    private var plan: some View {
        GeometryReader { proxy in
            let bounds = room.bounds.insetBy(dx: -0.2, dy: -0.2)
            let meters = max(1, min(proxy.size.width / bounds.width, proxy.size.height / bounds.height))
            ZStack {
                ForEach(room.walls) { item in
                    objectShape(item, meters: meters)
                        .position(point(item, bounds: bounds, size: proxy.size, meters: meters))
                        .accessibilityHidden(true)
                }
                ForEach(room.items.filter { !$0.wall }) { item in
                    movable(item, point: point(item, bounds: bounds, size: proxy.size, meters: meters), meters: meters)
                }
            }
            .coordinateSpace(name: "room-plan")
        }
        .fadedGlassSurface(radius: FadedRadius.medium)
        .clipShape(.rect(cornerRadius: FadedRadius.medium))
    }

    private func point(_ item: ScannedOfficeRoom.Item, bounds: CGRect, size: CGSize, meters: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2 + (item.x - bounds.midX) * meters,
                y: size.height / 2 + (item.z - bounds.midY) * meters)
    }

    private func objectShape(_ item: ScannedOfficeRoom.Item, meters: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: item.wall ? 1 : 5)
            .fill(item.wall ? palette.secondary : item.botID == nil ? palette.cyan.opacity(0.42) : palette.lime.opacity(0.55))
            .frame(width: max(2, item.width * meters), height: max(2, item.depth * meters))
            .overlay {
                if item.id == selection { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.lime, lineWidth: 2) }
            }
            .rotationEffect(.radians(item.angle))
            .shadow(color: .black.opacity(item.wall ? 0 : 0.75), radius: 0, x: 3, y: 3)
    }

    private func movable(_ item: ScannedOfficeRoom.Item, point: CGPoint, meters: CGFloat) -> some View {
        objectShape(item, meters: meters)
            .overlay {
                Text(verbatim: item.title).font(.caption2.bold()).foregroundStyle(palette.text)
                    .lineLimit(1).minimumScaleFactor(0.55).padding(2)
                    .allowsHitTesting(false)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .offset(item.id == selection ? drag : .zero)
            .position(point)
            .onTapGesture { selection = item.id }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("room-plan"))
                .onChanged { _ in selection = item.id }
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    var moved = item
                    moved.x += value.translation.width / meters
                    moved.z += value.translation.height / meters
                    savePlacement(moved)
                })
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection = item.id }
    }

    private func selectedTools(_ item: ScannedOfficeRoom.Item) -> some View {
        HStack {
            Text(verbatim: item.title).font(FadedTypography.action)
            Spacer()
            Menu("Indret", systemImage: "move.3d") {
                Button("Til venstre") { adjust(item, x: -0.1, z: 0) }
                Button("Til højre") { adjust(item, x: 0.1, z: 0) }
                Button("Op") { adjust(item, x: 0, z: -0.1) }
                Button("Ned") { adjust(item, x: 0, z: 0.1) }
                Button("Drej 15°") {
                    var rotated = item
                    rotated.angle = (rotated.angle + .pi / 12).truncatingRemainder(dividingBy: .pi * 2)
                    savePlacement(rotated)
                }
                if item.botID != nil {
                    Button("Fjern fra rummet", role: .destructive) {
                        var updated = room
                        updated.items.removeAll { $0.id == item.id }
                        save(updated)
                        selection = nil
                    }
                }
            }.frame(minHeight: 44)
        }
    }

    private func adjust(_ item: ScannedOfficeRoom.Item, x: Double, z: Double) {
        var moved = item
        moved.x += x
        moved.z += z
        savePlacement(moved)
    }

    private func place(_ bot: VillageLifeBot) {
        if let existing = room.items.first(where: { $0.botID == bot.id }) {
            selection = existing.id
        } else {
            let marker = ScannedOfficeRoom.Item(id: UUID(), title: bot.displayName, width: 0.36, depth: 0.36,
                                                wall: false, botID: bot.id, x: room.bounds.midX,
                                                z: room.bounds.midY, angle: 0)
            savePlacement(marker)
        }
    }

    private func savePlacement(_ item: ScannedOfficeRoom.Item) {
        var updated = room
        updated.place(item)
        save(updated)
        selection = item.id
    }

    private func save(_ updated: ScannedOfficeRoom) {
        do { try ScannedOfficeStore.save(updated); room = updated; failure = nil }
        catch { failure = "Indretningen kunne ikke gemmes. Prøv igen, mens telefonen er låst op." }
    }
}
