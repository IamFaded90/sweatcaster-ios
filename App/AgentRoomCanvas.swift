import SwiftUI
import UIKit

struct AgentRoomCanvas: View {
    let version: AgentRoom.Version
    let artwork: UIImage?
    var selectedFigure: UUID? = nil
    var onSelectFigure: (UUID) -> Void = { _ in }
    var onSelectHotspot: (AgentRoom.Hotspot) -> Void = { _ in }
    var ambienceScene: String? = nil
    @ObservedObject private var ambience = VillageAmbienceHub.shared
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var magnification = 1.0
    @GestureState private var drag = CGSize.zero
    @State private var ignoreTapsUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var figures: [AgentRoom.Figure] {
        version.figures.sorted { $0.y == $1.y ? $0.id.uuidString < $1.id.uuidString : $0.y < $1.y }
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let size = geometry.size
                let scale = AgentRoomCamera.zoom(zoom * magnification)
                let offset = AgentRoomCamera.pan(CGSize(width: pan.width + drag.width,
                                                        height: pan.height + drag.height), zoom: scale, size: size)
                room(size: size)
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .clipped()
                    .gesture(pinch(size: size))
                    .simultaneousGesture(panAndSelect(size: size, zoom: scale, offset: offset))
                    .onChange(of: size) { _, next in pan = AgentRoomCamera.pan(pan, zoom: zoom, size: next) }
            }
            .aspectRatio(CGFloat(version.width) / CGFloat(version.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: FadedRadius.medium))
            .overlay { RoundedRectangle(cornerRadius: FadedRadius.medium).strokeBorder(.white.opacity(0.12)) }
            HStack(spacing: 12) {
                Text("Knib for at zoome").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Nulstil", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { zoom = 1; pan = .zero }
                }
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityLabel("Nulstil rummets udsnit")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rum i fuld størrelse")
        .accessibilityValue("Zoom \(Int(AgentRoomCamera.zoom(zoom) * 100)) procent")
    }

    private func room(size: CGSize) -> some View {
        ZStack {
            if let image = ambienceScene.flatMap({ ambience.image($0) }) ?? artwork {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .brightness(ambienceScene.map { ambience.settings($0).brightness } ?? 0)
                    .saturation(ambienceScene.map { ambience.settings($0).saturation } ?? 1)
                    .overlay { if let ambienceScene { VillageAmbienceLight(settings: ambience.settings(ambienceScene)) } }
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else {
                Rectangle().fill(.black.opacity(0.18)).overlay { ProgressView("Henter rummet…") }
            }
            ForEach(figures) { figure in
                AgentRoomFigure(figure: figure, selected: selectedFigure == figure.id)
                    .frame(width: AgentRoomCamera.figureWidth(figure, size: size),
                           height: AgentRoomCamera.figureHeight(figure, size: size))
                    .position(x: size.width * figure.x, y: size.height * figure.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay { if let ambienceScene { RoomWorksOverlay(scene: ambienceScene) } }
        .background(.black.opacity(0.18))
    }

    private func pinch(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, current, _ in current = value.magnification }
            .onChanged { _ in ignoreTapsUntil = .now.addingTimeInterval(0.4) }
            .onEnded {
                zoom = AgentRoomCamera.zoom(zoom * $0.magnification)
                pan = AgentRoomCamera.pan(pan, zoom: zoom, size: size)
                ignoreTapsUntil = .now.addingTimeInterval(0.4)
            }
    }

    private func panAndSelect(size: CGSize, zoom: Double, offset: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($drag) { value, current, _ in
                if zoom > 1.001 { current = value.translation }
            }
            .onEnded { value in
                if let ambienceScene, RoomWorkHub.shared.editing.contains(ambienceScene) { return }
                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 8 {
                    pan = AgentRoomCamera.pan(CGSize(width: pan.width + value.translation.width,
                                                     height: pan.height + value.translation.height), zoom: zoom, size: size)
                    ignoreTapsUntil = .now.addingTimeInterval(0.3)
                } else if .now > ignoreTapsUntil {
                    let point = AgentRoomCamera.point(value.location, zoom: zoom, offset: offset, size: size)
                    select(point, size: size)
                }
            }
    }

    private func select(_ point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let ambienceScene, (RoomWorkHub.shared.layouts[ambienceScene]?.items ?? []).contains(where: {
            CGRect(x: $0.x * size.width - 24, y: $0.y * size.height - 24, width: 48, height: 48).contains(point)
        }) { return }
        for figure in figures.reversed() {
            let width = AgentRoomCamera.figureWidth(figure, size: size)
            let height = AgentRoomCamera.figureHeight(figure, size: size)
            let rect = CGRect(x: size.width * figure.x - width / 2, y: size.height * figure.y - height / 2,
                              width: width, height: height)
            if rect.insetBy(dx: -4, dy: -4).contains(point) { onSelectFigure(figure.id); return }
        }
        for hotspot in version.hotspots.reversed() {
            let rect = CGRect(x: (hotspot.x - hotspot.w / 2) * size.width,
                              y: (hotspot.y - hotspot.h / 2) * size.height,
                              width: hotspot.w * size.width, height: hotspot.h * size.height)
            if rect.contains(point) { onSelectHotspot(hotspot); return }
        }
    }
}

private struct AgentRoomFigure: View {
    let figure: AgentRoom.Figure
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !selected || reduceMotion || phase != .active)) { clock in
            let steps = [0, 0, 1, 0, 0, 7]
            let index = Int(max(0, clock.date.timeIntervalSinceReferenceDate) * 2) % steps.count
            let step = selected && !reduceMotion && phase == .active ? steps[index] : 0
            portrait(step: step)
        }
    }

    private func portrait(step: Int) -> some View {
        Group {
            if let image = VillageProductionArt.frame(character: figure.character, direction: 0, step: step) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                Image(systemName: "person.fill").resizable().scaledToFit().foregroundStyle(FadedBrand.mint)
            }
        }
        .padding(2)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(FadedBrand.mint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

enum AgentRoomCamera {
    static func zoom(_ value: Double) -> Double { value.isFinite ? min(3, max(1, value)) : 1 }
    static func pan(_ value: CGSize, zoom: Double, size: CGSize) -> CGSize {
        let limitX = max(0, size.width * (zoom - 1) / 2)
        let limitY = max(0, size.height * (zoom - 1) / 2)
        return CGSize(width: min(limitX, max(-limitX, value.width)),
                      height: min(limitY, max(-limitY, value.height)))
    }
    static func point(_ value: CGPoint, zoom: Double, offset: CGSize, size: CGSize) -> CGPoint {
        CGPoint(x: (value.x - size.width / 2 - offset.width) / zoom + size.width / 2,
                y: (value.y - size.height / 2 - offset.height) / zoom + size.height / 2)
    }
    static func figureHeight(_ figure: AgentRoom.Figure, size: CGSize) -> CGFloat { size.height * 0.18 * figure.scale }
    static func figureWidth(_ figure: AgentRoom.Figure, size: CGSize) -> CGFloat {
        min(size.width * 0.19, figureHeight(figure, size: size))
    }
}

struct AgentRoomFullScreen: View {
    let room: AgentRoom
    let version: AgentRoom.Version
    let artwork: UIImage?
    var onOpenBot: (UUID) -> Void = { _ in }
    var onSelectFigure: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFigure: UUID?
    @State private var hotspot: AgentRoom.Hotspot?

    var body: some View {
        NavigationStack {
            ScrollView {
                AgentRoomCanvas(version: version, artwork: artwork, selectedFigure: selectedFigure,
                                onSelectFigure: selectFigure, onSelectHotspot: selectHotspot, ambienceScene: VillageAmbience.room(room.id))
                    .padding(FadedSpacing.edge)
                ForEach(version.figures) { figure in
                    Button {
                        selectedFigure = figure.id
                        onSelectFigure(figure.id)
                        onOpenBot(figure.id)
                    } label: {
                        Label(figure.name, systemImage: "person")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, FadedSpacing.edge)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Vælg \(figure.name)")
                }
            }
            .background { FadedBackground(variant: .village) }
            .navigationTitle(room.title)
            .modifier(VillageAmbienceLifecycle(scene: VillageAmbience.room(room.id)))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .alert(hotspot?.title ?? "I rummet", isPresented: Binding(
                get: { hotspot != nil }, set: { if !$0 { hotspot = nil } }
            )) { Button("OK", role: .cancel) { hotspot = nil } }
        }
    }

    private func selectFigure(_ id: UUID) { selectedFigure = id; onSelectFigure(id) }

    private func selectHotspot(_ value: AgentRoom.Hotspot) {
        if value.action == .bot, let id = value.botID { onOpenBot(id) }
        else { hotspot = value }
    }
}
