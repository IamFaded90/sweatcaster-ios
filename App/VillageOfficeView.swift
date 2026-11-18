import Foundation
import Observation
import SwiftUI

struct VillageMemorial: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let role: String
    let bornAt: Date?
    let retiredAt: Date
}

/// Local village history is independent of the active bot list, so deleting a bot
/// cannot erase its memorial. Existing bots are treated as founding adults.
@MainActor @Observable final class VillageHistory {
    static let shared = VillageHistory()
    private static let birthsKey = "village.history.births.v1"
    private static let memorialsKey = "village.history.memorials.v1"
    private let defaults: UserDefaults

    private(set) var births: [UUID: Date]
    private(set) var memorials: [VillageMemorial]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        births = (defaults.data(forKey: Self.birthsKey)
            .flatMap { try? JSONDecoder().decode([UUID: Date].self, from: $0) }) ?? [:]
        memorials = (defaults.data(forKey: Self.memorialsKey)
            .flatMap { try? JSONDecoder().decode([VillageMemorial].self, from: $0) }) ?? []
    }

    func created(_ bot: VillageBot, at date: Date = .now) {
        guard births[bot.id] == nil else { return }
        births[bot.id] = date
        persist()
    }

    func retired(_ bot: VillageBot, at date: Date = .now) {
        guard !memorials.contains(where: { $0.id == bot.id }) else { return }
        memorials.append(VillageMemorial(id: bot.id, name: bot.name,
                                          role: bot.specialtyTitle, bornAt: births[bot.id], retiredAt: date))
        persist()
    }

    func restored(_ id: UUID) {
        memorials.removeAll { $0.id == id }
        persist()
    }

    func replace(births: [UUID: Date], memorials: [VillageMemorial]) {
        self.births = births
        self.memorials = memorials
        persist()
    }

    func ageLabel(for id: UUID, now: Date = .now) -> String {
        guard let birth = births[id] else { return "Voksen · landsbyens første" }
        let days = max(0, Calendar.current.dateComponents([.day], from: birth, to: now).day ?? 0)
        return "\(days < 7 ? "Ung" : "Voksen") · \(days) dage"
    }

    func isYoung(_ id: UUID, now: Date = .now) -> Bool {
        guard let birth = births[id] else { return false }
        return now.timeIntervalSince(birth) < 7 * 86_400
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(births) {
            defaults.set(data, forKey: Self.birthsKey)
        }
        if let data = try? JSONEncoder().encode(memorials) {
            defaults.set(data, forKey: Self.memorialsKey)
        }
    }
}

@MainActor struct VillageOfficeView: View {
    let bots: [VillageLifeBot]
    var onOpenProfile: (VillageLifeBot) -> Void
    var onOpenComputer: (VillageLifeBot) -> Void
    var onCreateBot: () -> Void
    var onOpenCemetery: () -> Void
    var onRetireBot: (VillageLifeBot) -> Void

    @Environment(\.fadedPalette) private var palette
    @State private var search = ""
    @State private var retiringBot: VillageLifeBot?
    @State private var confirmRetirement = false

    private var filteredBots: [VillageLifeBot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return bots }
        return bots.filter { $0.displayName.localizedCaseInsensitiveContains(query) ||
                             $0.zoneID.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                creatorCard
                NavigationLink {
                    VillageHexOffice(bots: bots, openProfile: onOpenProfile,
                                     openComputer: onOpenComputer, openCemetery: onOpenCemetery)
                } label: {
                    Label("Åbn kontorkort", systemImage: "map")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .fadedGlassSurface(radius: FadedRadius.medium)
                }
                NavigationLink {
                    ScannedOfficeRoomsView(bots: bots)
                } label: {
                    Label("Scan og indret mit værelse", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .fadedGlassSurface(radius: FadedRadius.medium)
                }
                Text("Personlige computere")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Hver bot har sit eget rum, også når PC’en er slukket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Find en bot", text: $search)
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .fadedGlassSurface(radius: FadedRadius.medium)
                HStack(spacing: 10) {
                    Button(action: onCreateBot) {
                        Label("Giv en ny bot liv", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(bots.count >= 10)
                    Button(action: onOpenCemetery) {
                        Label("Kirkegård · \(VillageHistory.shared.memorials.count)", systemImage: "leaf")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium)
                Text("Nyt liv begynder ungt · voksen efter 7 dage · minder bliver i landsbyen")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)

                LazyVStack(spacing: 10) {
                    ForEach(filteredBots) { bot in
                        officeBotRow(bot)
                    }
                }
                if filteredBots.isEmpty {
                    Text("Ingen botter matcher din søgning.")
                        .foregroundStyle(palette.secondary)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .navigationTitle("Kontoret")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Slet bot og gem minde?", isPresented: $confirmRetirement,
                            presenting: retiringBot) { bot in
            Button("Slet bot", role: .destructive) { onRetireBot(bot) }
        } message: { bot in
            Text("\(bot.displayName) fjernes fra telefonen. Et minde bliver i Kirkegården.")
        }
    }

    private func officeBotRow(_ bot: VillageLifeBot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VillagePixelImage(name: "room-" + VillageAssets.newArtName(name: bot.displayName, id: bot.id),
                                  folder: "new", width: 92, height: 74)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    if let id = UUID(uuidString: bot.id) {
                        Text(VillageHistory.shared.ageLabel(for: id))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FadedBrand.mint)
                    }
                    Text(bot.displayName).font(FadedTypography.section).lineLimit(1)
                    Text(bot.poseLabel + " · " + bot.zoneID.title)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2)
                    if bot.pcJobRunning, let live = bot.pcLiveLabel {
                        Text(live).font(.caption2).foregroundStyle(FadedBrand.mint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    onOpenProfile(bot)
                } label: {
                    Label("Profil", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium)
                .accessibilityLabel("Åbn profil for \(bot.displayName)")

                Button {
                    onOpenComputer(bot)
                } label: {
                    Label("Computer", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(palette.isDark ? FadedBrand.mint : palette.text)
                }
                .buttonStyle(.plain)
                .fadedGlassSurface(radius: FadedRadius.medium, tint: FadedBrand.mint.opacity(0.16),
                                   border: FadedBrand.mint.opacity(0.45))
                .accessibilityLabel("Åbn computer for \(bot.displayName)")
            }
            if UUID(uuidString: bot.id) != nil {
                Button(role: .destructive) {
                    retiringBot = bot
                    confirmRetirement = true
                } label: {
                    Label("Slet bot · til kirkegården", systemImage: "leaf")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .fadedGlassSurface(radius: FadedRadius.card)
        .accessibilityElement(children: .contain)
    }

    private var creatorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                if let image = VillageAssets.image(named: "creator", subdirectory: "new") {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 68, height: 68).clipShape(Circle())
                        .accessibilityLabel("Skaberen")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("DIG / SKABEREN").font(.caption2.weight(.bold)).foregroundStyle(FadedBrand.mint)
                    Text("Her begynder livet.").font(.title3.weight(.semibold))
                    Text("Dit kontor · dit værksted · din landsby")
                        .font(.caption).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
            }
            VillageInteriorArtwork(name: "office-slice", label: "Skaberens værksted")
                .frame(height: 180)
            HStack {
                Text("SKABERVÆRKSTEDET")
                Spacer()
                Text("\(bots.count) levende · \(VillageHistory.shared.memorials.count) minder")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.secondary)
        }
        .padding(16)
        .fadedGlassSurface(radius: FadedRadius.card)
    }

}

private struct VillageCreationScene: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                Canvas { context, size in
                    func fill(_ points: [CGPoint], _ color: Color) {
                        var path = Path()
                        if let first = points.first {
                            path.move(to: first)
                            for point in points.dropFirst() { path.addLine(to: point) }
                            path.closeSubpath()
                            context.fill(path, with: .color(color))
                        }
                    }
                    let mid = size.width / 2
                    fill([CGPoint(x: mid, y: 18), CGPoint(x: size.width - 10, y: 79),
                          CGPoint(x: mid, y: 144), CGPoint(x: 10, y: 79)],
                         Color(red: 0.19, green: 0.34, blue: 0.36))
                    fill([CGPoint(x: 10, y: 79), CGPoint(x: mid, y: 144),
                          CGPoint(x: mid, y: 159), CGPoint(x: 10, y: 94)],
                         Color(red: 0.10, green: 0.22, blue: 0.27))
                    fill([CGPoint(x: mid, y: 144), CGPoint(x: size.width - 10, y: 79),
                          CGPoint(x: size.width - 10, y: 94), CGPoint(x: mid, y: 159)],
                         Color(red: 0.07, green: 0.18, blue: 0.23))
                    fill([CGPoint(x: mid - 110, y: 74), CGPoint(x: mid - 54, y: 53),
                          CGPoint(x: mid - 16, y: 72), CGPoint(x: mid - 73, y: 94)],
                         Color(red: 0.50, green: 0.37, blue: 0.27))
                    fill([CGPoint(x: mid - 99, y: 72), CGPoint(x: mid - 65, y: 60),
                          CGPoint(x: mid - 45, y: 70), CGPoint(x: mid - 79, y: 83)],
                         Color(red: 0.91, green: 0.84, blue: 0.67))
                    context.stroke(Path(ellipseIn: CGRect(x: mid - 22, y: 77, width: 66, height: 31)),
                                   with: .color(FadedBrand.mint.opacity(0.7)), lineWidth: 2)
                    context.stroke(Path(ellipseIn: CGRect(x: mid - 34, y: 70, width: 90, height: 45)),
                                   with: .color(FadedBrand.mint.opacity(0.3)), lineWidth: 1)
                }
                Image(systemName: "sparkle")
                    .font(.system(size: 22)).foregroundStyle(FadedBrand.mint)
                    .position(x: width / 2 + 10, y: 81)
                if let image = VillageAssets.image(named: "creator", subdirectory: "new") {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 38, height: 38).clipShape(Circle())
                        .overlay(Circle().strokeBorder(FadedBrand.mint, lineWidth: 1))
                        .background(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3).fill(.gray)
                                .frame(width: 47, height: 11).offset(y: 9)
                        }
                        .position(x: width / 2 + 89, y: 80)
                }
            }
        }
        .frame(height: 160)
        .background(Color(red: 0.07, green: 0.16, blue: 0.20), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Skaberværkstedet med plads til en ny bot")
    }
}

@MainActor struct VillageCemeteryView: View {
    @Environment(\.fadedPalette) private var palette
    private var memorials: [VillageMemorial] { VillageHistory.shared.memorials }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Alle, du har givet liv, har en plads i landsbyens historie.")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                memorialGarden
                if memorials.isEmpty {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("En stille mindehave").font(.headline)
                            Text("Her kommer en navngiven gravsten, når du sletter en bot i Kontoret.")
                                .font(.subheadline).foregroundStyle(palette.secondary)
                        }
                    }
                }
                ForEach(memorials.reversed()) { memorial in
                    FadedCard {
                        HStack(spacing: 14) {
                            Image(systemName: "leaf.fill")
                                .font(.title2).foregroundStyle(FadedBrand.mint)
                                .frame(width: 48, height: 58)
                                .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(memorial.name).font(.headline)
                                Text(memorial.role).font(.caption).foregroundStyle(palette.secondary)
                                Text(memorial.bornAt.map {
                                    "\(max(0, Calendar.current.dateComponents([.day], from: $0, to: memorial.retiredAt).day ?? 0)) dage i landsbyen"
                                } ?? "En af landsbyens første")
                                    .font(.caption).foregroundStyle(palette.secondary)
                                Text("Skabt af dig. Husket her.").font(.caption2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle("Kirkegården")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var memorialGarden: some View {
        VillageInteriorArtwork(name: "cemetery", label: "Kirkegården")
            .frame(height: 230)
        .accessibilityLabel("Mindehave med \(memorials.count) minder")
    }
}

@MainActor struct VillageTaskDeskView: View {
    let bots: [VillageBot]
    let onOpenComputer: (VillageBot) -> Void
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Du skriver. De tager opgaven med sig.")
                    .font(.title3.weight(.semibold))
                Text("Vælg en bot. Opgaven sendes fra bottens egen computer, hvor du også kan følge resultatet og filerne.")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                if !bots.isEmpty {
                    NavigationLink { VillageChiefPlanner(bots: bots) } label: {
                        Label("Planlæg med Chief", systemImage: "crown")
                    }.buttonStyle(FadedButtonStyle(kind: .secondary))
                }
                if bots.isEmpty {
                    FadedEmptyState(icon: "person.2", title: "Ingen bots endnu",
                                    detail: "Opret først en bot i Kontoret.")
                }
                ForEach(bots) { bot in
                    Button { onOpenComputer(bot) } label: {
                        FadedCard {
                            HStack(spacing: 12) {
                                VillageBotAvatar(bot: bot, size: 44, radius: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(bot.name).font(.headline)
                                    Text(bot.specialtyTitle).font(.caption).foregroundStyle(palette.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").foregroundStyle(FadedBrand.mint)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Åbn opgaver for \(bot.name)")
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle("Opgaver")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor struct VillageBuildingRoomView: View {
    let zone: VillageZoneID
    @ObservedObject var life: VillageLifeSimulator
    let onOpenProfile: (VillageLifeBot) -> Void
    @Environment(\.fadedPalette) private var palette

    private var imageName: String {
        switch zone {
        case .research: "room-research-lab"
        case .video: "room-media-studio"
        case .cafe: "room-cafe"
        case .sleep: "room-sleeping-corner"
        }
    }

    private var description: String {
        switch zone {
        case .research: "Bøger, noter og computere til fordybelse."
        case .video: "Farver, skitser og et stort arbejdsbord."
        case .cafe: "Sofaer, kaffe og et bord til samtaler."
        case .sleep: "Senge, planter og dæmpet aftenlys."
        }
    }

    private var residents: [VillageLifeBot] {
        life.bots.filter { $0.zoneID == zone && $0.destinationZoneID == nil }
    }

    private var incoming: [VillageLifeBot] {
        life.bots.filter { $0.zoneID != zone && $0.destinationZoneID == zone }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(description).font(.subheadline).foregroundStyle(palette.secondary)
                VillageInteriorArtwork(name: imageName, label: zone.title,
                                       residents: residents, animateResidents: !life.paused)
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel(zone.title)
                Text("Her lige nu").font(.headline)
                if residents.isEmpty {
                    FadedCard {
                        Text("Ingen bot er her lige nu.").font(.subheadline)
                            .foregroundStyle(palette.secondary)
                    }
                }
                ForEach(residents) { bot in residentRow(bot, status: bot.poseLabel) }
                if !incoming.isEmpty {
                    Text("På vej hertil").font(.headline)
                    ForEach(incoming) { bot in residentRow(bot, status: "På vej") }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle(zone.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func residentRow(_ bot: VillageLifeBot, status: String) -> some View {
        Button { onOpenProfile(bot) } label: {
            FadedCard {
                HStack {
                    VillageBotSprite(bot: bot, size: 36)
                    Text(bot.displayName).font(.headline)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(palette.secondary)
                    Image(systemName: "chevron.right")
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Åbn profil for \(bot.displayName)")
        .accessibilityValue(status)
    }
}

struct VillageZoomSlider: View {
    @Binding var zoom: Double

    var body: some View {
        let percentage = zoom.formatted(.percent.precision(.fractionLength(0)))
        HStack(spacing: 12) {
            Text("Zoom").accessibilityHidden(true)
            Slider(value: $zoom, in: VillageCamera.zoomRange)
                .accessibilityLabel("Kortzoom")
                .accessibilityValue(percentage)
            Text(percentage)
                .monospacedDigit()
                .frame(minWidth: 54, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }
}

@MainActor struct VillageSettingsView: View {
    @Binding var lightMode: String
    @Binding var showNames: Bool
    @Binding var reduceMotion: Bool
    @Binding var zoom: Double
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tilpas stemningen og find den visning, der passer dig.")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stemning").font(.headline)
                        Picker("Lys i landsbyen", selection: $lightMode) {
                            Text("Følg tiden").tag("auto")
                            Text("Daglys").tag("day")
                            Text("Aftenlys").tag("night")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                FadedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Kort og bevægelse").font(.headline)
                        Toggle("Vis botternes navne på kortet", isOn: $showNames)
                        Toggle("Reducer bevægelse", isOn: $reduceMotion)
                        VStack(alignment: .leading, spacing: 8) {
                            VillageZoomSlider(zoom: $zoom)
                            Button("Nulstil zoom og placering") { zoom = 1 }
                                .frame(minHeight: 44)
                        }
                        Text("Telefonens egen indstilling for reduceret bevægelse gælder også.")
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                }
                FadedCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lyd i landsbyen").font(.headline)
                        Text("Landsbyen har endnu ingen egen lydafspiller.")
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .foregroundStyle(palette.text)
        .navigationTitle("Indstillinger")
        .navigationBarTitleDisplayMode(.inline)
    }
}
