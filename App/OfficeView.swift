// Connects the office workers to the agent hub and draws the isometric village.

import Foundation
import SwiftUI
import UIKit

extension AgentHub {
    private struct VillagePiece: Identifiable {
        enum Kind {
            case building(Int)
            case agent(V2Hub.Agent)
            case bot(VillageBot, routine: Int, sleeping: Bool)
        }

        let id: String
        let kind: Kind
        let zone: Int
        let point: CGPoint
        let depth: CGFloat
    }

    var officeWorkers: [PixelOfficeWorker] {
        let sleeping = villageBotsSleep(hour: Calendar.current.component(.hour, from: .now))
        let local = localVillageBots.map { bot in
            let id = "bot:\(bot.id.uuidString)"
            return PixelOfficeWorker(id: id, name: bot.name, specialty: bot.specialtyTitle,
                                     colorIndex: officeColorIndex(id), status: sleeping ? .offline : .ready)
        }
        let remote = (snapshot?.agents ?? []).map { agent in
            let id = "agent:\(agent.id)"
            let role = snapshot?.rooms.first(where: { $0.id == agent.room_id })?.name ?? "PC-agent"
            let status: PixelOfficeWorker.Status = if offline || api == nil { .offline } else {
                switch agent.status {
                case .working: .working
                case .thinking: .thinking
                case .ready: .ready
                case .offline: .offline
                }
            }
            return PixelOfficeWorker(id: id, name: agent.name, specialty: role, colorIndex: officeColorIndex(id), status: status)
        }
        return local + remote
    }

    private func officeColorIndex(_ id: String) -> Int {
        id.utf8.reduce(0) { ($0 + Int($1)) % FadedColors.officeWorkers.count }
    }

    func openOfficeWorker(_ worker: PixelOfficeWorker) {
        if let bot = localVillageBots.first(where: { "bot:\($0.id.uuidString)" == worker.id }) { localBot = bot }
        else if let agent = snapshot?.agents.first(where: { "agent:\($0.id)" == worker.id }) { details = agent }
    }

    var villageVisible: Bool { isVisible && hubPhase == .active }
    private var villageMotionEnabled: Bool { villageVisible && !reduceMotion && !calmMotion }

    var village: some View {
        Group {
            if villageVisible {
                TimelineView(.periodic(from: .now, by: villageMotionEnabled ? 0.25 : 60)) { timeline in
                    villageScene(at: timeline.date)
                }
            } else {
                villageScene(at: .now)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                villageControl(cinematic ? "Afslut filmtilstand" : "Start filmtilstand", icon: cinematic ? "eye" : "video") {
                    cinematic.toggle()
                }
                if !cinematic && (villageZoom != 1 || villageOffset != .zero) {
                    villageControl("Nulstil udsnit", icon: "arrow.counterclockwise") {
                        villageZoom = 1
                        villageOffset = .zero
                    }
                }
            }
            .padding(8)
        }
    }

    private func villageControl(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
                .frame(minWidth: 48, minHeight: 48)
                .foregroundStyle(palette.text)
                .fadedGlassSurface()
        }.accessibilityLabel(title)
    }

    private func villageScene(at date: Date) -> some View {
        let hour = Calendar.current.component(.hour, from: date)
        let night = hour < 7 || hour >= 20
        let shape = RoundedRectangle(cornerRadius: FadedRadius.media)
        return GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [night ? FadedColors.sunset : villageGround(night: false), FadedColors.deep],
                               startPoint: .top, endPoint: .bottom)
                villageTerrain(night: night)
                ForEach(villagePieces(hour: hour, time: date.timeIntervalSinceReferenceDate, size: geometry.size)) { piece in
                    villagePiece(piece, night: night)
                        .zIndex(Double(piece.depth))
                        .animation(villageMotionEnabled ? .easeInOut(duration: 0.75) : nil, value: piece.zone)
                }
            }
            .overlay { if offline { villageRain(at: date) } }
            .scaleEffect(villageZoom)
            .offset(villageOffset)
            .gesture(MagnifyGesture().onChanged { villageZoom = min(2, max(1, $0.magnification)) })
            .simultaneousGesture(DragGesture().onChanged { villageOffset = $0.translation })
            .foregroundStyle(FadedColors.text)
            .clipShape(shape)
        }
        .frame(height: 420)
        .overlay { shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false) }
        .overlay(alignment: .topLeading) {
            if !cinematic {
                Label(night ? "Nat" : "Dag", systemImage: night ? "moon.stars.fill" : "sun.max.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(FadedColors.text)
                    .padding(8).background(.black.opacity(0.74), in: Capsule()).padding(8)
            }
        }
    }

    private func villageTerrain(night: Bool) -> some View {
        Canvas { context, size in
            var tiles = Path()
            let step: CGFloat = 16
            for row in 0..<Int(size.height / step) {
                for column in 0..<Int(size.width / (2 * step)) where (row * 7 + column * 11) % 5 == 0 {
                    let x = CGFloat(column) * 2 * step + (row.isMultiple(of: 2) ? 0 : step)
                    let y = CGFloat(row) * step
                    tiles.move(to: CGPoint(x: x, y: y - step / 2))
                    tiles.addLine(to: CGPoint(x: x + step, y: y))
                    tiles.addLine(to: CGPoint(x: x, y: y + step / 2))
                    tiles.addLine(to: CGPoint(x: x - step, y: y))
                    tiles.closeSubpath()
                }
            }
            context.fill(tiles, with: .color(FadedColors.daylightWindow.opacity(night ? 0.07 : 0.12)))

            let plaza = CGPoint(x: size.width / 2, y: size.height * 0.57)
            let trails = Path { path in
                for zone in 0..<4 {
                    let room = villagePoint(zone, size: size)
                    path.move(to: CGPoint(x: room.x, y: room.y + 44))
                    path.addLine(to: CGPoint(x: (room.x + plaza.x) / 2, y: (room.y + plaza.y) / 2 + 24))
                    path.addLine(to: plaza)
                }
            }
            context.stroke(trails, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 19, lineCap: .round, lineJoin: .round))
            context.stroke(trails, with: .color(FadedColors.daylightWindow.opacity(night ? 0.22 : 0.38)),
                           style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))

            var trunks = Path()
            var leaves = Path()
            for tree in 0..<12 {
                let x = size.width * (0.08 + Double((tree * 31) % 83) / 100)
                let y = size.height * (0.11 + Double((tree * 47) % 75) / 100)
                trunks.addRect(CGRect(x: x + 4, y: y + 6, width: 4, height: 9))
                leaves.addRect(CGRect(x: x, y: y + 2, width: 13, height: 8))
                leaves.addRect(CGRect(x: x + 2, y: y, width: 9, height: 2))
            }
            context.fill(trunks, with: .color(FadedColors.daylightWindow.opacity(0.46)))
            context.fill(leaves, with: .color(palette.green.opacity(night ? 0.32 : 0.50)))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    var localVillageBots: [VillageBot] {
        VillageBot.list(from: localBotsData)
    }

    private func villageGround(night: Bool) -> Color {
        night ? FadedColors.sunset : Color(red: 0.28, green: 0.18, blue: 0.12)
    }

    private func villageRain(at date: Date) -> some View {
        Canvas { context, size in
            let phase = villageMotionEnabled ? Int(date.timeIntervalSince1970 * 24) % 100 : 0
            for drop in 0..<30 {
                let x = size.width * Double((drop * 37) % 100) / 100
                let y = size.height * Double((drop * 61 + phase) % 100) / 100
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x - 4, y: y + 10))
                }
                context.stroke(line, with: .color(.cyan.opacity(0.45)), lineWidth: 1)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func villageBuilding(_ zone: Int, center: CGPoint, night: Bool) -> some View {
        let names = ["Research Lab", "Video Studio", "Kaffeområde", "Sovekrog"]
        let symbols = ["books.vertical.fill", "film.fill", "cup.and.saucer.fill", "moon.stars.fill"]
        let colors = [palette.coral, palette.lime, palette.coral, palette.lime]
        let color = colors[zone]
        return ZStack {
            Canvas { context, _ in
                func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x, y: center.y + y) }
                func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Path {
                    Path { path in
                        path.move(to: a)
                        path.addLine(to: b)
                        path.addLine(to: c)
                        path.addLine(to: d)
                        path.closeSubpath()
                    }
                }
                func diamond(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> Path {
                    quad(point(x, y - height / 2), point(x + width / 2, y),
                         point(x, y + height / 2), point(x - width / 2, y))
                }
                let west = quad(point(-57, -28), point(0, 1), point(0, 47), point(-57, 18))
                let east = quad(point(0, 1), point(57, -28), point(57, 18), point(0, 47))
                let roof = diamond(0, -29, width: 132, height: 66)
                context.fill(diamond(10, 41, width: 154, height: 86), with: .color(.black.opacity(0.34)))
                context.fill(diamond(0, 22, width: 148, height: 80),
                             with: .color(night ? Color(red: 0.22, green: 0.16, blue: 0.12) : Color(red: 0.39, green: 0.28, blue: 0.19)))
                // Back the tinted faces with opaque color so a sprite behind a wall cannot show through it.
                for face in [west, east, roof] { context.fill(face, with: .color(villageGround(night: night))) }
                context.fill(west, with: .color(color.opacity(night ? 0.28 : 0.46)))
                context.fill(east, with: .color(color.opacity(night ? 0.18 : 0.28)))
                context.fill(roof, with: .color(color.opacity(night ? 0.64 : 0.82)))
                context.stroke(roof, with: .color(FadedColors.text.opacity(0.36)), lineWidth: 1.5)
                context.fill(quad(point(-13, 13), point(0, 20), point(0, 45), point(-13, 38)),
                             with: .color(.black.opacity(0.56)))
                let window = quad(point(17, 17), point(34, 8), point(34, 22), point(17, 31))
                if night { context.stroke(window, with: .color(FadedColors.daylightWindow.opacity(0.22)), lineWidth: 5) }
                context.fill(window, with: .color(FadedColors.daylightWindow.opacity(night ? 0.95 : 0.53)))
            }.accessibilityHidden(true)
            Label(names[zone], systemImage: symbols[zone])
                .font(.caption2.bold()).labelStyle(.titleAndIcon)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.black.opacity(0.72), in: Capsule())
                .position(x: center.x, y: center.y + 25)
        }.allowsHitTesting(false)
    }

    private func villagePieces(hour: Int, time: TimeInterval, size: CGSize) -> [VillagePiece] {
        var pieces = (0..<4).map { zone in
            let point = villagePoint(zone, size: size)
            return VillagePiece(id: "building-\(zone)", kind: .building(zone), zone: zone, point: point,
                                depth: point.y + 47)
        }
        var agentSlots = [0, 0, 0, 0]
        for (index, agent) in (snapshot?.agents ?? []).enumerated() {
            let sleeping = offline || agent.status == .offline
            let zone = sleeping ? 3 : agent.status == .ready ? 2 : agent.room_id.lowercased().contains("video") ? 1 : 0
            let phase = villageMotionEnabled && !sleeping ? time * 0.55 + Double(index) : nil
            let foot = villageFoot(zone, slot: agentSlots[zone], local: false, phase: phase, size: size)
            pieces.append(VillagePiece(id: "agent-\(agent.id)", kind: .agent(agent), zone: zone, point: foot,
                                       depth: foot.y))
            agentSlots[zone] += 1
        }
        var botSlots = [0, 0, 0, 0]
        let sleeping = villageBotsSleep(hour: hour)
        for (index, bot) in localVillageBots.enumerated() {
            let routine = (hour + index) % 3
            let zone = sleeping ? 3 : routine
            let phase = villageMotionEnabled && !sleeping ? time * 0.7 + Double(index) : nil
            let foot = villageFoot(zone, slot: botSlots[zone], local: true, phase: phase, size: size)
            pieces.append(VillagePiece(id: "bot-\(bot.id)", kind: .bot(bot, routine: routine, sleeping: sleeping),
                                       zone: zone, point: foot, depth: foot.y))
            botSlots[zone] += 1
        }
        return pieces
    }

    @ViewBuilder private func villagePiece(_ piece: VillagePiece, night: Bool) -> some View {
        switch piece.kind {
        case .building(let zone):
            villageBuilding(zone, center: piece.point, night: night)
        case .agent(let agent):
            villageAvatar(agent).position(x: piece.point.x, y: piece.point.y - 21)
        case .bot(let bot, let routine, let sleeping):
            localVillageAvatar(bot, routine: routine, sleeping: sleeping)
                .position(x: piece.point.x, y: piece.point.y - 5)
        }
    }

    func villageBotsSleep(hour: Int) -> Bool { offline || villagePause || hour < 7 || hour >= 22 }

    func botActivity(_ bot: VillageBot, routine: Int, sleeping: Bool) -> String {
        guard !sleeping else { return "Sover" }
        let routines: [String] = switch bot.personality ?? "Nysgerrig" {
        case "Rolig": ["Læser i biblioteket", "Ordner studiet", "Drikker te"]
        case "Sjov": ["Finder på historier", "Øver en scene", "Fortæller jokes"]
        case "Omsorgsfuld": ["Hjælper i laboratoriet", "Hjælper med video", "Laver kaffe til holdet"]
        default: ["Undersøger nye idéer", "Øver sig i studiet", "Holder kaffepause"]
        }
        return routines[routine]
    }

    private func localVillageAvatar(_ bot: VillageBot, routine: Int, sleeping: Bool) -> some View {
        let activity = botActivity(bot, routine: routine, sleeping: sleeping)
        let color = bot.color == "Grøn" ? palette.green : bot.color == "Lilla" ? palette.purple : palette.cyan
        return Button {
            if !cinematic { localBot = bot }
        } label: {
            VStack(spacing: 0) {
                Group {
                if let data = bot.sprite, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(systemName: sleeping ? "moon.stars.fill" : "sparkle").foregroundStyle(color)
                }
                }.frame(width: 38, height: 38, alignment: .bottom).opacity(sleeping ? 0.55 : 1)
                Text(bot.name).font(.caption2.bold()).lineLimit(1)
                if !sleeping { Text(activity).font(.system(size: 8)).lineLimit(1) }
            }.frame(width: 92, height: 66, alignment: .top)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!cinematic)
        .accessibilityHidden(cinematic)
        .accessibilityLabel(bot.name + ", " + (bot.personality ?? "Nysgerrig") + ", " + activity)
    }

    private func villagePoint(_ zone: Int, size: CGSize) -> CGPoint {
        let rooms = [CGPoint(x: -0.67, y: -0.21), CGPoint(x: -0.03, y: -0.49),
                     CGPoint(x: 0.07, y: 0.53), CGPoint(x: 0.71, y: 0.25)]
        return isometric(rooms[zone], origin: CGPoint(x: size.width / 2, y: size.height / 2),
                         halfTile: CGSize(width: size.width / 2, height: size.height / 4))
    }

    private func isometric(_ tile: CGPoint, origin: CGPoint, halfTile: CGSize) -> CGPoint {
        CGPoint(x: origin.x + (tile.x - tile.y) * halfTile.width,
                y: origin.y + (tile.x + tile.y) * halfTile.height)
    }

    private func villageFoot(_ zone: Int, slot: Int, local: Bool, phase: Double?, size: CGSize) -> CGPoint {
        let columns = local ? 5 : 4
        let lane = (CGFloat(slot % columns) - CGFloat(columns - 1) / 2) * (local ? 0.34 : 0.43)
        let row = CGFloat(slot / columns)
        let front = (local ? 2.25 : 1.63) + row * 0.42
        let wanderX = phase.map { CGFloat(sin($0)) * 0.32 } ?? 0
        let wanderY = phase.map { CGFloat(cos($0)) * 0.32 } ?? 0
        let tile = CGPoint(x: front + lane + wanderX, y: front - lane + wanderY)
        let foot = isometric(tile, origin: villagePoint(zone, size: size), halfTile: CGSize(width: 32, height: 16))
        let margin: CGFloat = local ? 46 : 22
        return CGPoint(x: min(max(margin, foot.x), max(margin, size.width - margin)),
                       y: min(foot.y, size.height - (local ? 20 : 5)))
    }

    private func villageAvatar(_ agent: V2Hub.Agent) -> some View {
        let sleeping = offline || agent.status == .offline
        let resting = agent.status == .ready
        let matchingSprite = localVillageBots.first {
            $0.name.localizedCaseInsensitiveCompare(agent.name) == .orderedSame ||
            $0.name.localizedCaseInsensitiveCompare(agent.id) == .orderedSame
        }?.sprite
        return Button {
            if !cinematic { details = agent }
        } label: {
            Group {
                if let matchingSprite, let image = UIImage(data: matchingSprite) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(systemName: sleeping ? "moon.zzz.fill" : icon(agent.icon)).font(.title2)
                }
            }
            .frame(width: 42, height: 42, alignment: .bottom)
            .opacity(sleeping ? 0.55 : 1)
            .modifier(AgentPulse(active: villageMotionEnabled && !sleeping && !resting))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name + ", " + (sleeping ? "Hviler" : status(agent.status)))
        .contextMenu {
            if !cinematic {
                Button("Vis historik og hukommelse") { details = agent }
            }
        }
        .allowsHitTesting(!cinematic)
        .accessibilityHidden(cinematic)
    }
}

private struct AgentPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fadedPalette) private var palette

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || reduceMotion)) { context in
            let intensity = active && !reduceMotion
                ? 0.18 + 0.12 * sin(context.date.timeIntervalSinceReferenceDate * 2)
                : 0.0
            content.overlay {
                RoundedRectangle(cornerRadius: FadedRadius.media).strokeBorder(palette.cyan.opacity(intensity), lineWidth: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
