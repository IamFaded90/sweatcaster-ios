import SwiftUI
import UIKit

struct VillageMapView: View {
    let bots: [VillageLifeBot]
    let night: Bool
    let cinematic: Bool
    let reduceMotion: Bool
    let offline: Bool
    var banner: String? = nil
    var onSelect: (VillageLifeBot) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var magnifyStart: CGFloat = 1
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(night
                          ? Color(red: 0.03, green: 0.06, blue: 0.14)
                          : Color(red: 0.12, green: 0.28, blue: 0.38))

                terrainLayer(size: size)
                pathLayer(size: size)

                ForEach(buildingsSorted) { building in
                    buildingStack(building, size: size)
                }

                propLayer(size: size)

                ForEach(bots.sorted(by: { botY($0, size: size) < botY($1, size: size) })) { bot in
                    botNode(bot, size: size)
                }

                VStack(spacing: 8) {
                    if offline {
                        Text("PC’en er afbrudt. Landsbyen fortsætter.")
                            .font(.caption2.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let banner, !banner.isEmpty {
                        Text(banner)
                            .font(.caption2.weight(.semibold))
                            .padding(8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
                .allowsHitTesting(false)
            }
            .scaleEffect(zoom)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let next = min(2.2, max(1, magnifyStart * value.magnification))
                        zoom = next
                        offset = VillageCamera.clampOffset(offset, zoom: next, frame: size)
                        dragStart = offset
                    }
                    .onEnded { _ in
                        magnifyStart = zoom
                        if zoom <= 1.001 {
                            zoom = 1
                            offset = .zero
                            magnifyStart = 1
                            dragStart = .zero
                        } else {
                            offset = VillageCamera.clampOffset(offset, zoom: zoom, frame: size)
                            dragStart = offset
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard zoom > 1.001 else {
                            offset = .zero
                            return
                        }
                        let proposed = CGSize(
                            width: dragStart.width + value.translation.width,
                            height: dragStart.height + value.translation.height
                        )
                        offset = VillageCamera.clampOffset(proposed, zoom: zoom, frame: size)
                    }
                    .onEnded { _ in
                        dragStart = offset
                        if zoom <= 1.001 {
                            offset = .zero
                            dragStart = .zero
                        }
                    }
            )
            .onChange(of: size) { _, newSize in
                offset = VillageCamera.clampOffset(offset, zoom: zoom, frame: newSize)
                dragStart = offset
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
            .overlay(alignment: .bottomTrailing) {
                if zoom > 1.001 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoom = 1
                            offset = .zero
                            magnifyStart = 1
                            dragStart = .zero
                        }
                    } label: {
                        Label(VillageCopy.cameraReset, systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                            .labelStyle(.iconOnly)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(10)
                    .accessibilityLabel(VillageCopy.cameraReset)
                }
            }
        }
        .frame(height: cinematic ? 520 : 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Landsbykort")
    }

    private struct BuildingSpot: Identifiable {
        let id: VillageZoneID
        var zone: VillageZoneID { id }
    }

    private var buildingsSorted: [BuildingSpot] {
        VillageZoneID.allCases
            .map(BuildingSpot.init)
            .sorted { $0.zone.pointIndex < $1.zone.pointIndex }
    }

    private func terrainLayer(size: CGSize) -> some View {
        let tile = VillageAssets.image(named: "terrain_grass", subdirectory: "tiles")
        return Canvas { context, canvas in
            context.fill(Path(CGRect(origin: .zero, size: canvas)),
                         with: .color(night ? Color(red: 0.05, green: 0.14, blue: 0.14) : Color(red: 0.10, green: 0.32, blue: 0.24)))
            guard let tile else { return }
            let stepX: CGFloat = 48
            let stepY: CGFloat = 24
            var row = 0
            var y: CGFloat = 40
            while y < canvas.height - 20 {
                var x: CGFloat = row % 2 == 0 ? 8 : 32
                while x < canvas.width {
                    context.draw(Image(uiImage: tile),
                                 in: CGRect(x: x, y: y, width: 64, height: 32))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        }
        .allowsHitTesting(false)
    }

    private func pathLayer(size: CGSize) -> some View {
        let cross = VillageAssets.image(named: "path_cross", subdirectory: "tiles")
        let ne = VillageAssets.image(named: "path_straight_ne", subdirectory: "tiles")
        return ZStack {
            if let ne {
                ForEach(0..<5, id: \.self) { i in
                    Image(uiImage: ne).interpolation(.none).resizable()
                        .frame(width: 64, height: 32)
                        .position(x: size.width * 0.22 + CGFloat(i) * 36, y: size.height * 0.48)
                        .opacity(0.9)
                }
            }
            if let cross {
                Image(uiImage: cross).interpolation(.none).resizable()
                    .frame(width: 72, height: 36)
                    .position(x: size.width * 0.5, y: size.height * 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func buildingStack(_ spot: BuildingSpot, size: CGSize) -> some View {
        let point = VillageLifeSimulator.mapPoint(zone: spot.zone, size: size)
        let base = spot.zone.buildingAsset
        return ZStack {
            VillagePixelImage(name: base + "_shadow", folder: "buildings", width: 150, height: 150)
                .offset(x: 6, y: 8)
            VillagePixelImage(name: base, folder: "buildings", width: 150, height: 150)
            if night {
                VillagePixelImage(name: base + "_windows_night", folder: "buildings", width: 150, height: 150)
            }
            VillagePixelImage(name: base + "_foreground", folder: "buildings", width: 150, height: 150)
            if !cinematic {
                Text(spot.zone.title)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .offset(y: 62)
            }
        }
        .position(x: point.x, y: point.y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func propLayer(size: CGSize) -> some View {
        ZStack {
            VillagePixelImage(name: "prop_tree", folder: "props", width: 40, height: 60)
                .position(x: size.width * 0.12, y: size.height * 0.32)
            VillagePixelImage(name: "prop_tree", folder: "props", width: 40, height: 60)
                .position(x: size.width * 0.88, y: size.height * 0.58)
            VillagePixelImage(name: "prop_lamp", folder: "props", width: 22, height: 44)
                .position(x: size.width * 0.42, y: size.height * 0.46)
            VillagePixelImage(name: "prop_lamp", folder: "props", width: 22, height: 44)
                .position(x: size.width * 0.58, y: size.height * 0.54)
            VillagePixelImage(name: "prop_sign", folder: "props", width: 28, height: 28)
                .position(x: size.width * 0.5, y: size.height * 0.62)
        }
        .allowsHitTesting(false)
    }

    private func botY(_ bot: VillageLifeBot, size: CGSize) -> CGFloat {
        VillageLifeSimulator.interpolatedPoint(bot: bot, size: size).y
    }

    private func botNode(_ bot: VillageLifeBot, size: CGSize) -> some View {
        let point = VillageLifeSimulator.interpolatedPoint(bot: bot, size: size)
        return Button {
            onSelect(bot)
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    VillageBotSprite(bot: bot, size: 48)
                        .opacity(bot.activity == .sleep ? 0.55 : 1)
                    if bot.carrying != nil {
                        Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: 4, y: -2)
                    }
                    if bot.pcJobRunning {
                        Circle().fill(Color.green).frame(width: 8, height: 8).offset(x: -4, y: -2)
                    } else if bot.pcJobQueued {
                        Circle().fill(Color.yellow).frame(width: 8, height: 8).offset(x: -4, y: -2)
                    }
                    if let speech = VillageCopy.speech(bot.speechHint) {
                        Text(speech)
                            .font(.system(size: 8, weight: .bold))
                            .padding(3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            .offset(y: -14)
                    }
                }
                if !cinematic {
                    Text(bot.displayName).font(.caption2.bold()).lineLimit(1)
                    Text(bot.poseLabel).font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    if let live = bot.pcLiveLabel, bot.pcJobRunning || bot.pcJobQueued {
                        Text(live).font(.system(size: 7)).foregroundStyle(.mint)
                    }
                    needDots(bot.needs)
                }
            }
            .frame(width: 86)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .position(point)
        .accessibilityLabel(accessibilityText(for: bot))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: bot.zoneID)
        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: bot.pathProgress)
    }

    private func accessibilityText(for bot: VillageLifeBot) -> String {
        var parts = ["\(bot.displayName), \(bot.poseLabel) på \(bot.zoneID.title)"]
        if bot.pcJobRunning { parts.append("PC-opgave i gang") }
        else if bot.pcJobQueued { parts.append("Venter på en opgave") }
        return parts.joined(separator: ", ")
    }

    private func needDots(_ needs: VillageNeeds) -> some View {
        HStack(spacing: 3) {
            Circle().fill(needs.energy < 0.35 ? .red : .green).frame(width: 4, height: 4)
            Circle().fill(needs.social < 0.35 ? .orange : .cyan).frame(width: 4, height: 4)
            Circle().fill(needs.fulfillment < 0.35 ? .yellow : .blue).frame(width: 4, height: 4)
        }
        .accessibilityHidden(true)
    }
}
