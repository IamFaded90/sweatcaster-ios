import SwiftUI
import UIKit

@MainActor struct VillageMapView: View {
    @AppStorage(AppStorageKeys.villageMapNames) private var showNames = true
    @AppStorage("village.map.navigationLocked.v2") private var navigationLocked = true
    @AppStorage(VillageCamera.Focus.storageKey) private var focus = VillageCamera.Focus.center
    @Binding var zoom: Double
    let bots: [VillageLifeBot]
    let night: Bool
    let cinematic: Bool
    let reduceMotion: Bool
    let offline: Bool
    var banner: String? = nil
    var paused = false
    var onSelect: (VillageLifeBot) -> Void
    var onSelectBuilding: (VillageZoneID) -> Void = { _ in }
    var onSelectCemetery: () -> Void = {}
    var onSelectCreator: () -> Void = {}

    @GestureState private var magnification: CGFloat = 1
    @GestureState private var translation: CGSize = .zero
    @ObservedObject private var ambience = VillageAmbienceHub.shared
    @State private var ambienceOpen = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = CGFloat(VillageCamera.clampZoom(zoom * Double(magnification)))
            let pan = focus.offset(zoom: scale, frame: size, adding: translation)
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
                        if !navigationLocked { current = value.magnification }
                    }
                    .onEnded { value in
                        guard !navigationLocked else { return }
                        let finalScale = VillageCamera.clampZoom(zoom * Double(value.magnification))
                        zoom = finalScale > 1.001 ? finalScale : 1
                    },
                including: navigationLocked ? .subviews : .all
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($translation) { value, current, _ in
                        if !navigationLocked { current = value.translation }
                    }
                    .onEnded { value in
                        guard !navigationLocked, scale > 1.001 else { return }
                        let moved = focus.offset(zoom: scale, frame: size, adding: value.translation)
                        focus = VillageCamera.Focus(offset: moved, zoom: scale, frame: size)
                    },
                including: !navigationLocked && scale > 1.001 ? .all : .subviews
            )
            .onChange(of: zoom, initial: true) { _, value in
                if VillageCamera.clampZoom(value) <= 1.001, focus != .center { focus = .center }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(LinearGradient(colors: [FadedBrand.mint.opacity(0.4), .white.opacity(0.08), FadedBrand.blue.opacity(0.28)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) { villageHUD.padding(10).allowsHitTesting(false) }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Button { navigationLocked.toggle() } label: {
                        Image(systemName: navigationLocked ? "lock.fill" : "hand.draw")
                            .frame(width: 44, height: 44).fadedGlassSurface()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(navigationLocked ? "Kortet er låst" : "Flyt kortet")
                    .accessibilityHint("Zoomskyderen virker også, når kortet er låst")
                    placesMenu
                }
                .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                if zoom > 1.001 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            zoom = 1
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
        .shadow(color: .black.opacity(0.38), radius: 16, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Landsbykort")
        .modifier(VillageAmbienceLifecycle(scene: "village"))
        .sheet(isPresented: $ambienceOpen) { VillageAmbienceView(scene: "village", title: "landsbyen") }
    }

    private var villageHUD: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Label(paused ? "På pause" : night ? "Aften" : "Dag", systemImage: paused ? "pause.fill" : night ? "moon.stars.fill" : "sun.max.fill")
                if !bots.isEmpty { Label("\(bots.count) beboere", systemImage: "person.2.fill") }
            }
            Label(paused ? "På pause" : night ? "Aften" : "Dag", systemImage: paused ? "pause.fill" : night ? "moon.stars.fill" : "sun.max.fill")
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .fadedGlassSurface(tint: FadedBrand.panel)
    }

    private var placesMenu: some View {
        Menu {
            Button("Lys, lyd og stemning", systemImage: "sun.haze") { ambienceOpen = true }
            Section("Steder") {
                ForEach(VillageZoneID.allCases, id: \.self) { zone in
                    Button(zone.title) { onSelectBuilding(zone) }
                }
                Button("Kirkegården", action: onSelectCemetery)
                Button("Skaberens kontor", action: onSelectCreator)
            }
            if !bots.isEmpty {
                Section("Beboere") {
                    ForEach(bots.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { bot in
                        Button(bot.displayName + " · " + bot.zoneID.title) { onSelect(bot) }
                    }
                }
            }
        } label: {
            Label("Find", systemImage: "map")
                .font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 44)
                .fadedGlassSurface()
        }
        .accessibilityLabel("Find et sted eller en beboer")
    }

    private func mapContent(size: CGSize) -> some View {
        let placements = botPlacements(size: size)
        return ZStack {
            if let map = ambience.image("village") ?? VillageProductionArt.image(night ? "map-night" : "map-day") {
                Image(uiImage: map)
                    .resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .brightness(ambience.settings("village").brightness).saturation(ambience.settings("village").saturation)
                    .overlay { VillageAmbienceLight(settings: ambience.settings("village")) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            ForEach(VillageZoneID.allCases, id: \.self) { zone in
                Button { onSelectBuilding(zone) } label: {
                    Rectangle().fill(.clear).frame(width: 80, height: 76)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(buildingCenter(zone, size: size))
                .accessibilityLabel("Åbn \(zone.title)")
            }
            Button(action: onSelectCemetery) {
                Color.clear.frame(width: 80, height: 76).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(VillageMapLayout.point(VillageMapLayout.cemetery, in: size))
            .accessibilityLabel("Åbn Kirkegården")
            Button(action: onSelectCreator) {
                VillageCreatorMonument()
            }
            .buttonStyle(.plain)
            .position(VillageMapLayout.point(VillageMapLayout.creator, in: size))
            .accessibilityLabel("Åbn Skaberens kontor")
            ForEach(placements) { placement in
                botNode(placement.bot, at: placement.foot)
            }
            if ambience.image("village") == nil {
                VillageMapForeground(night: night)
                    .brightness(ambience.settings("village").brightness).saturation(ambience.settings("village").saturation)
                    .overlay { VillageAmbienceLight(settings: ambience.settings("village")) }
            }
            VillageWindowLights(night: night)
        }
        .frame(width: size.width, height: size.height)
    }

    private var mapStatus: some View {
        VStack(spacing: 8) {
            if offline && banner != VillageCopy.speech("offline_rest") {
                Text(VillageCopy.pcUnavailable)
                    .font(.caption2.weight(.semibold))
                    .padding(8)
                    .fadedGlassSurface(tint: FadedBrand.panel)
            }
            if let banner, !banner.isEmpty {
                Text(banner)
                    .font(.caption2.weight(.semibold))
                    .padding(8)
                    .fadedGlassSurface(tint: FadedBrand.panel)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
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
        VillageMapLayout.point(VillageMapLayout.building(zone), in: size)
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
            CGPoint(x: -28, y: 10), CGPoint(x: 28, y: 10),
            CGPoint(x: 0, y: -10), CGPoint(x: 0, y: 10),
            CGPoint(x: -14, y: -10), CGPoint(x: 14, y: 10),
            CGPoint(x: -14, y: 10), CGPoint(x: 14, y: -10)
        ]
        let spread = min(1, size.width / 330)
        return bots.sorted { $0.id < $1.id }.enumerated().map { index, bot in
            let point = VillageMapLayout.foot(for: bot, in: size)
            let slot = slots[index % slots.count]
            return BotPlacement(bot: bot, foot: CGPoint(x: point.x + slot.x * spread, y: point.y + slot.y))
        }.sorted {
            $0.foot.y == $1.foot.y ? $0.id < $1.id : $0.foot.y < $1.foot.y
        }
    }

    private func botNode(_ bot: VillageLifeBot, at foot: CGPoint) -> some View {
        return Button {
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
                    if showNames {
                        VStack(spacing: 2) {
                            Text(bot.displayName).font(.caption2.bold()).lineLimit(1)
                            if !cinematic {
                                Text(bot.poseLabel).font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                                if let live = bot.pcLiveLabel, bot.pcJobRunning || bot.pcJobQueued {
                                    Text(live).font(.system(size: 7)).foregroundStyle(.mint)
                                }
                                needDots(bot.needs)
                            }
                        }
                        .frame(width: 86)
                        .alignmentGuide(.bottom) { $0[.top] }
                        .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        // Normalized artwork feet sit at y=114 of 128; keep their contact point on the path.
        .position(x: foot.x, y: foot.y - 19)
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

private struct VillageChurchLandmark: View {
    let count: Int

    var body: some View {
        ZStack {
            Canvas { context, size in
                let sx = size.width / 112
                let sy = size.height / 92
                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
                var island = Path()
                island.move(to: point(5, 56)); island.addLine(to: point(54, 34))
                island.addLine(to: point(108, 56)); island.addLine(to: point(58, 82))
                island.closeSubpath()
                context.fill(island, with: .color(Color(red: 0.25, green: 0.43, blue: 0.40)))
                let church = CGRect(x: 54 * sx, y: 30 * sy, width: 29 * sx, height: 31 * sy)
                context.fill(Path(church), with: .color(Color(red: 0.70, green: 0.75, blue: 0.66)))
                var roof = Path()
                roof.move(to: point(49, 31)); roof.addLine(to: point(67, 17))
                roof.addLine(to: point(88, 31)); roof.closeSubpath()
                context.fill(roof, with: .color(Color(red: 0.22, green: 0.36, blue: 0.42)))
                context.fill(Path(CGRect(x: 65 * sx, y: 43 * sy, width: 8 * sx, height: 18 * sy)),
                             with: .color(Color(red: 0.72, green: 0.50, blue: 0.30)))
                for x in [CGFloat(27), CGFloat(43)] {
                    context.fill(Path(roundedRect: CGRect(x: x * sx, y: 47 * sy,
                                                          width: 10 * sx, height: 17 * sy), cornerRadius: 4 * sx),
                                 with: .color(Color(red: 0.67, green: 0.74, blue: 0.71)))
                }
            }
            VStack {
                Spacer()
                Text("Kirkegård · \(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
            }
        }
        .frame(width: 112, height: 92)
        .contentShape(Rectangle())
    }
}

private struct VillageCreatorMonument: View {
    var body: some View {
        VStack(spacing: 0) {
            if let image = VillageAssets.image(named: "creator", subdirectory: "new") {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(Circle())
                    .overlay(Circle().strokeBorder(FadedBrand.mint.opacity(0.7), lineWidth: 2))
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.38, green: 0.52, blue: 0.52))
                .frame(width: 38, height: 8)
            Text("SKABEREN").font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3).background(.black.opacity(0.65))
        }
        .frame(width: 52, height: 54)
        .contentShape(Rectangle())
    }
}
