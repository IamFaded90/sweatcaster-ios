import AVFoundation
import QuickLook
import RoomPlan
import SceneKit
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
                    HStack(spacing: 8) {
                        Button {
                            selected = room
                        } label: {
                            Label(room.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "cube")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            removal = room
                        } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Slet rum")
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
    @State private var showScene = false

    init(room: ScannedOfficeRoom, bots: [VillageLifeBot]) {
        _room = State(initialValue: room)
        self.bots = bots
    }

    private var selected: ScannedOfficeRoom.Item? { room.items.first { $0.id == selection && !$0.wall } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    Picker("Visning", selection: $showScene) {
                        Text("Plantegning").tag(false)
                        Text("Indret i 3D").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if showScene {
                        FadedDetailText("Drej rummet med én finger. Vægfotos ses fra den side, du scannede. Tryk på et møbel eller en bot for at flytte den.")
                        ScannedOfficeScene(room: room, selection: $selection)
                            .frame(height: 360)
                            .clipShape(.rect(cornerRadius: FadedRadius.medium))
                            .accessibilityHidden(true)
                        Menu("Vælg møbel eller bot", systemImage: "selection.pin.in.out") {
                            ForEach(room.items.filter { !$0.wall }) { item in
                                Button(item.title) { selection = item.id }
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(!room.items.contains { !$0.wall })
                    } else {
                        FadedDetailText("Træk et møbel eller en bot for at indrette.")
                        plan.frame(height: 360)
                    }
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
                    ShareLink(item: ScannedOfficePCExport(room), preview: SharePreview("FadedAI-kontor")) {
                        Label("Del plantegning til PC", systemImage: "desktopcomputer")
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

@MainActor private struct ScannedOfficeScene: UIViewRepresentable {
    let room: ScannedOfficeRoom
    @Binding var selection: UUID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        let bounds = room.bounds
        let span = max(bounds.width, bounds.height)
        context.coordinator.photos = ScannedOfficeStore.photos(room.id).compactMapValues { photo in
            guard let image = UIImage(data: photo.jpeg), (1...512).contains(image.size.width),
                  (1...512).contains(image.size.height) else { return nil }
            return (photo.front, image)
        }
        scene.rootNode.addChildNode(context.coordinator.layout)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = max(100, Double(span) * 8)
        camera.position = SCNVector3(Float(bounds.midX + span * 0.75), Float(span * 1.05 + 1),
                                     Float(bounds.midY + span * 0.85))
        camera.look(at: SCNVector3(Float(bounds.midX), 0.4, Float(bounds.midY)))
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.12, alpha: 1)
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.target = SCNVector3(Float(bounds.midX), 0.4, Float(bounds.midY))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                        action: #selector(Coordinator.pick(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        guard coordinator.items != room.items || coordinator.highlight != selection else { return }
        coordinator.items = room.items
        coordinator.highlight = selection
        coordinator.layout.childNodes.forEach { $0.removeFromParentNode() }
        let bounds = room.bounds
        let floor = SCNBox(width: bounds.width, height: 0.06, length: bounds.height, chamferRadius: 0)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(Float(bounds.midX), -0.03, Float(bounds.midY))
        floor.firstMaterial?.diffuse.contents = UIColor(red: 0.34, green: 0.29, blue: 0.23, alpha: 1)
        coordinator.layout.addChildNode(floorNode)
        for item in room.items {
            let height = item.displayHeight
            let shape = SCNBox(width: item.width, height: height, length: item.depth,
                               chamferRadius: item.wall ? 0 : min(0.04, item.width / 5, item.depth / 5))
            let node = SCNNode(geometry: shape)
            node.position = SCNVector3(Float(item.x), Float(height / 2), Float(item.z))
            node.eulerAngles.y = Float(-item.angle)
            if !item.wall { node.name = item.id.uuidString }
            let color: UIColor = item.wall ? .lightGray : item.botID == nil ? .systemTeal : .systemGreen
            shape.firstMaterial?.diffuse.contents = color
            if item.id == selection { shape.firstMaterial?.emission.contents = UIColor.systemYellow.withAlphaComponent(0.6) }
            if item.wall { shape.firstMaterial?.transparency = 0.42 }
            if item.wall, let photo = coordinator.photos[item.id] {
                let face = SCNPlane(width: item.width, height: height)
                let material = SCNMaterial()
                material.diffuse.contents = photo.image
                material.lightingModel = .constant
                face.materials = [material]
                let interior = SCNNode(geometry: face)
                interior.position.z = Float((item.depth / 2 + 0.001) * (photo.front ? 1 : -1))
                if !photo.front { interior.eulerAngles.y = .pi }
                node.addChildNode(interior)
            }
            coordinator.layout.addChildNode(node)
        }
    }

    @MainActor final class Coordinator: NSObject {
        let layout = SCNNode()
        var photos: [UUID: (front: Bool, image: UIImage)] = [:]
        var selection: Binding<UUID?>?
        var items: [ScannedOfficeRoom.Item]?
        var highlight: UUID?

        @objc func pick(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            for hit in view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
                if let name = hit.node.name, let id = UUID(uuidString: name) {
                    selection?.wrappedValue = id
                    return
                }
            }
        }
    }
}
