import SwiftUI
import UIKit

struct VillageMapView: View {
    let bots: [VillageLifeBot]
    let night: Bool
    let cinematic: Bool
    let reduceMotion: Bool
    let offline: Bool
    var banner: String? = nil
    var paused = false
    var onSelect: (VillageLifeBot) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(2.2, max(1, zoom * magnification))
            let pan = clampedPan(adding: translation, zoom: scale, size: size)
            ZStack {
                mapContent(size: size)
                    .scaleEffect(scale)
                    .offset(pan)
                mapStatus
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .updating($magnification) { value, current, _ in
                        current = value.magnification
                    }
                    .onEnded { value in
                        let finalScale = min(2.2, max(1, zoom * value.magnification))
                        zoom = finalScale > 1.001 ? finalScale : 1
                        offset = VillageCamera.clampOffset(offset, zoom: zoom, frame: size)
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($translation) { value, current, _ in
                        current = value.translation
                    }
                    .onEnded { value in offset = clampedPan(adding: value.translation, zoom: scale, size: size) },
                including: scale > 1.001 ? .all : .subviews
            )
            .onChange(of: size) { _, newSize in
                offset = VillageCamera.clampOffset(offset, zoom: zoom, frame: newSize)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08)))
            .overlay(alignment: .bottomTrailing) {
                if zoom > 1.001 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            zoom = 1
                            offset = .zero
                        }
                    } label: {
                        Label(VillageCopy.cameraReset, systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .fadedGlassSurface()
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

    private func clampedPan(adding translation: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        VillageCamera.clampOffset(
            CGSize(width: offset.width + translation.width, height: offset.height + translation.height),
            zoom: zoom,
            frame: size
        )
    }

    private func mapContent(size: CGSize) -> some View {
        let placements = botPlacements(size: size)
        return ZStack {
            terrainLayer(size: size)
            pathLayer(size: size)
            ForEach(buildingsSorted) { building in
                buildingStack(building, size: size)
            }
            propLayer(size: size)
            ForEach(placements) { placement in
                botNode(placement.bot, at: placement.foot)
            }
            ForEach(buildingsSorted) { building in
                VillagePixelImage(name: building.zone.buildingAsset + "_foreground", folder: "buildings",
                                  width: 150, height: 150)
                    .position(buildingCenter(building.zone, size: size))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var mapStatus: some View {
        VStack(spacing: 8) {
            if offline {
                Text(VillageCopy.pcUnavailable)
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
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
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
        let plaza = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let stone = VillageAssets.image(named: "terrain_plaza", subdirectory: "tiles")
        let cross = VillageAssets.image(named: "path_cross", subdirectory: "tiles")
        let paths = VillageZoneID.allCases.map { zone in
            let anchor = VillageLifeSimulator.mapPoint(zone: zone, size: size)
            return CGPoint(x: anchor.x, y: anchor.y + 36)
        }
        return Canvas { context, _ in
            if let stone {
                let tile = context.resolve(Image(uiImage: stone).interpolation(.none))
                for destination in paths {
                    let dx = destination.x - plaza.x
                    let dy = destination.y - plaza.y
                    let steps = max(1, Int(ceil(max(abs(dx) / 24, abs(dy) / 15))))
                    for step in 1...steps {
                        let fraction = CGFloat(step) / CGFloat(steps)
                        context.draw(tile, at: CGPoint(x: plaza.x + dx * fraction, y: plaza.y + dy * fraction))
                    }
                }
            }
            if let cross {
                context.draw(Image(uiImage: cross).interpolation(.none),
                             in: CGRect(x: plaza.x - 36, y: plaza.y - 18, width: 72, height: 36))
            }
        }
        .allowsHitTesting(false)
    }

    private func buildingStack(_ spot: BuildingSpot, size: CGSize) -> some View {
        let base = spot.zone.buildingAsset
        return ZStack {
            VillagePixelImage(name: base + "_shadow", folder: "buildings", width: 150, height: 150)
                .offset(x: 6, y: 8)
            VillagePixelImage(name: base, folder: "buildings", width: 150, height: 150)
            if night {
                VillagePixelImage(name: base + "_windows_night", folder: "buildings", width: 150, height: 150)
            }
            if !cinematic {
                Text(spot.zone.title)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .offset(y: 62)
            }
        }
        .position(buildingCenter(spot.zone, size: size))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func buildingCenter(_ zone: VillageZoneID, size: CGSize) -> CGPoint {
        let anchor = VillageLifeSimulator.mapPoint(zone: zone, size: size)
        // The bottom anchor of each 192px building sprite is at y=176.
        return CGPoint(x: anchor.x, y: anchor.y - 150 * (176 - 96) / 192)
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

    private struct BotPlacement: Identifiable {
        let bot: VillageLifeBot
        let foot: CGPoint
        var id: String { bot.id }
    }

    private func botPlacements(size: CGSize) -> [BotPlacement] {
        // Each bot keeps the same offset in every zone and along each route.
        let slots = [
            CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0),
            CGPoint(x: -60, y: 0), CGPoint(x: 60, y: 0),
            CGPoint(x: 0, y: -44), CGPoint(x: 0, y: 44),
            CGPoint(x: -44, y: -44), CGPoint(x: 44, y: 44),
            CGPoint(x: -44, y: 44), CGPoint(x: 44, y: -44)
        ]
        let spread = min(1, size.width / 330)
        return bots.sorted { $0.id < $1.id }.enumerated().map { index, bot in
            let point = VillageLifeSimulator.interpolatedPoint(bot: bot, size: size)
            let slot = slots[index % slots.count]
            return BotPlacement(bot: bot, foot: CGPoint(x: point.x + slot.x * spread, y: point.y + slot.y))
        }.sorted {
            $0.foot.y == $1.foot.y ? $0.id < $1.id : $0.foot.y < $1.foot.y
        }
    }

    private func botNode(_ bot: VillageLifeBot, at foot: CGPoint) -> some View {
        Button {
            onSelect(bot)
        } label: {
            VillageBotSprite(bot: bot, size: 48, animateWalk: !paused && !reduceMotion)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 3) {
                        if bot.carrying != nil {
                            Image(systemName: "shippingbox.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if bot.pcJobRunning {
                            Circle().fill(Color.green).frame(width: 8, height: 8).offset(x: -4, y: -2)
                        } else if bot.pcJobQueued {
                            Circle().fill(Color.yellow).frame(width: 8, height: 8).offset(x: -4, y: -2)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    if let speech = VillageCopy.speech(bot.speechHint) {
                        Text(speech)
                            .font(.caption2.weight(.semibold))
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                            .offset(y: -14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !cinematic {
                        VStack(spacing: 2) {
                            Text(bot.displayName).font(.caption2.bold()).lineLimit(1)
                            Text(bot.poseLabel).font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                            if let live = bot.pcLiveLabel, bot.pcJobRunning || bot.pcJobQueued {
                                Text(live).font(.system(size: 7)).foregroundStyle(.mint)
                            }
                            needDots(bot.needs)
                        }
                        .frame(width: 86)
                        .alignmentGuide(.bottom) { $0[.top] }
                        .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        // The 64px frames share foot y=60, i.e. 21pt below the center at this size.
        .position(x: foot.x, y: foot.y - 21)
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
