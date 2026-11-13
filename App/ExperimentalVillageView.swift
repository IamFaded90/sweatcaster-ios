// Opt-in village preview. Local simulation and read-only job observations stay separate.

import Foundation
import SwiftUI

enum ExperimentalVillageGate {
    static var available: Bool {
        #if FADEDAI_VILLAGE_PREVIEW
        true
        #else
        false
        #endif
    }

    @MainActor static func record(_ ids: [String]) {
        let defaults = UserDefaults.standard
        guard available, defaults.bool(forKey: AppStorageKeys.villageExperimentalEnabled) else { return }
        let existing = completed(from: defaults.string(forKey: AppStorageKeys.villageExperimentalJobs) ?? "")
        let observed = Set(existing.union(ids).sorted().prefix(201))
        if observed != existing {
            defaults.set(observed.sorted().joined(separator: ","), forKey: AppStorageKeys.villageExperimentalJobs)
        }
    }

    static func completed(from value: String) -> Set<String> {
        Set(value.split(separator: ",").prefix(201).map(String.init))
    }
}

struct ExperimentalVillageWork {
    var online = false
    var video = 0
    var code = 0
    var approvals = 0
    var completedIDs: [String] = []

    var summary: String {
        if !online { return "PC’en er offline. Arbejdsstationerne hviler." }
        let details = [
            video > 0 ? "Videojobs · \(video)" : nil,
            code > 0 ? "Kodejobs · \(code)" : nil,
            approvals > 0 ? "Venter på dig · \(approvals)" : nil
        ].compactMap { $0 }
        return details.isEmpty ? "Ingen aktive PC-job." : details.joined(separator: "  •  ")
    }
}

enum ExperimentalVillageAction {
    case code, video, approvals, library
}

struct ExperimentalVillageSetting: View {
    @AppStorage(AppStorageKeys.villageExperimentalEnabled) private var enabled = false

    var body: some View {
        Toggle("Eksperimentel Landsby", isOn: $enabled).disabled(!ExperimentalVillageGate.available)
        FadedDetailText(ExperimentalVillageGate.available
                        ? "Forsøgsvisning med dagsplan og aldersfremskridt. Kan give fejl."
                        : "Åbnes efter den fysiske iPhone- og PC-validering.")
    }
}

struct VillageLiveRow: View {
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.villageExperimentalEnabled) private var enabled = false
    let work: ExperimentalVillageWork
    let open: () -> Void

    var body: some View {
        if ExperimentalVillageGate.available && enabled {
            FadedCard(size: .compact, accent: palette.cyan) {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    FadedSectionHeader("I landsbyen lige nu", detail: work.summary)
                    FadedSecondaryButton("Åbn Landsbyen", icon: "house.lodge", action: open)
                }
            }
            .onChange(of: work.completedIDs, initial: true) { _, ids in ExperimentalVillageGate.record(ids) }
        }
    }
}

struct ExperimentalVillageView: View {
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.villageExperimentalFounders) private var founderRecord = ""
    @AppStorage(AppStorageKeys.villageExperimentalJobs) private var completedJobs = ""
    @State private var blessings: [UUID: Int] = [:]
    @State private var blessingDay: Date?
    @State private var events: [UUID: [String]] = [:]
    @State private var eventDay: Date?
    @State private var showSquare = false
    @State private var seedError: String?

    let bots: [VillageBot]
    let work: ExperimentalVillageWork
    let paused: Bool
    let isVisible: Bool
    let openProfile: (VillageBot) -> Void
    let openWork: (ExperimentalVillageAction) -> Void

    private static let traits = [
        "Flittig", "Nysgerrig", "Rolig", "Kreativ", "Social", "Perfektionist",
        "Workaholic", "Genius", "Omsorgsfuld", "Legesyg", "Tålmodig", "Ambitiøs"
    ]

    var body: some View {
        FadedCard(accent: palette.purple) {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedSectionHeader("Landsbyens univers", detail: "Eksperimentel. Dagsplan og energi er simulation.")
                eraProgress
                FadedDetailText(work.summary)
                if work.online && work.approvals > 0 {
                    FadedSecondaryButton("Gennemgå forslag", icon: "checklist") { openWork(.approvals) }
                }
                FadedSecondaryButton("Torvet · Gruppechat", icon: "person.2") { showSquare = true }
                    .disabled(bots.count < 2)
                if bots.count < 2 { FadedDetailText("Torvet kræver mindst to bots.") }
                FadedSecondaryButton("Bibliotek · Lokale modeller", icon: "books.vertical") { openWork(.library) }
                if bots.isEmpty && founderRecord.isEmpty {
                    FadedEmptyState(icon: "house.lodge", title: "De første hytter er tomme",
                                    detail: "Start med Adam til kode og Eva til video. De gemmes som almindelige bots.",
                                    actionTitle: "Opret Adam og Eva", action: createFounders)
                }
                if let seedError { FadedDetailText(seedError) }
                if isVisible {
                    TimelineView(.periodic(from: .now, by: 60)) { clock in residents(at: clock.date) }
                } else {
                    residents(at: .now)
                }
            }
        }
        .onChange(of: work.completedIDs, initial: true) { _, ids in ExperimentalVillageGate.record(ids) }
        .sheet(isPresented: $showSquare) {
            NavigationStack {
                TeamWorkflowView(mode: .group, bots: bots)
                    .toolbar { Button("Luk") { showSquare = false } }
            }
        }
    }

    private var eraProgress: some View {
        let count = ExperimentalVillageGate.completed(from: completedJobs).count
        let eras: [(name: String, start: Int)] = [("Stenalder", 0), ("Middelalder", 11), ("Moderne", 51), ("Rumalder", 201)]
        let current = eras.lastIndex(where: { $0.start <= count }) ?? 0
        let next = current + 1 < eras.count ? eras[current + 1] : nil
        return VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            Text(eras[current].name).font(FadedTypography.action)
            if let next {
                let start = eras[current].start
                FadedProgress(value: Double(count - start) / Double(next.start - start))
                    .accessibilityLabel("Fremskridt mod \(next.name)")
                FadedDetailText("\(next.start - count) afsluttede job til \(next.name).")
            } else {
                FadedProgress(value: 1).accessibilityLabel("Rumalderen er nået")
            }
            FadedDetailText("Tæller afsluttede job, som denne enhed har set i forsøgsvisningen.")
        }
    }

    @ViewBuilder private func residents(at date: Date) -> some View {
        ForEach(vacantFounderNames, id: \.self) { name in
            Label("\(name) · Hytten er tom", systemImage: "house")
                .font(.subheadline).foregroundStyle(palette.secondary)
        }
        ForEach(bots) { bot in
            Divider()
            resident(bot, at: date)
        }
    }

    private var vacantFounderNames: [String] {
        let saved = founderRecord.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard saved.count == 2 else { return [] }
        let residentIDs = Set(bots.map(\.id))
        return zip(["Adams hytte", "Evas hytte"], saved).compactMap { name, id in
            residentIDs.contains(id) ? nil : name
        }
    }

    private func resident(_ bot: VillageBot, at date: Date) -> some View {
        let hour = Calendar.current.component(.hour, from: date)
        let schedule = phase(at: hour)
        let level = energy(for: bot.id, base: schedule.energy, at: date)
        let specialty = bot.specialtyTitle
        let route: ExperimentalVillageAction = specialty.localizedCaseInsensitiveContains("video") ? .video : .code
        return VStack(alignment: .leading, spacing: FadedSpacing.s) {
            HStack(spacing: FadedSpacing.m) {
                VillageBotAvatar(bot: bot, size: 44, radius: FadedRadius.small)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(bot.name).font(FadedTypography.action)
                    FadedDetailText(specialty)
                }
            }
            FadedDetailText(traits(for: bot.id).joined(separator: " · "))
            FadedDetailText("\(schedule.activity) · \(schedule.mood) · Energi \(level)/100")
            if let partner = partner(for: bot) { FadedDetailText("Makker i simulationen: \(partner.name)") }
            if let latest = events[bot.id], !latest.isEmpty, eventDay == Calendar.current.startOfDay(for: date) {
                DisclosureGroup("Dagens simulerede minder") {
                    ForEach(Array(latest.enumerated()), id: \.offset) { event in FadedDetailText(event.element) }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { residentActions(bot, route: route, energy: level, at: date) }
                VStack(alignment: .leading) { residentActions(bot, route: route, energy: level, at: date) }
            }
        }
        .onChange(of: ScheduleEvent(day: Calendar.current.startOfDay(for: date), activity: schedule.activity), initial: true) { _, event in
            if isVisible { note(event.activity, for: bot.id, at: date) }
        }
    }

    private struct ScheduleEvent: Equatable {
        let day: Date
        let activity: String
    }

    @ViewBuilder private func residentActions(_ bot: VillageBot, route: ExperimentalVillageAction,
                                              energy: Int, at date: Date) -> some View {
        FadedSecondaryButton("Profil", icon: "person.crop.circle") { openProfile(bot) }
            .accessibilityLabel("Profil for \(bot.name)")
        FadedSecondaryButton("Velsign", icon: "sparkles") { bless(bot.id, at: date) }
            .disabled(energy >= 100)
            .accessibilityHint(energy >= 100 ? "Botten har fuld energi." : "Giver op til 20 energi i denne visning.")
        if let specialty = bot.specialty, ["kode", "video"].contains(specialty.lowercased()) {
            FadedSecondaryButton("Åbn opgavebord", icon: "arrow.up.right") { openWork(route) }
                .accessibilityHint("Åbner værktøjet. Du vælger og starter selv jobbet.")
        }
    }

    private func phase(at hour: Int) -> (activity: String, mood: String, energy: Int) {
        if paused || !work.online { return ("Hviler", "Rolig", 80) }
        switch hour {
        case 7: return ("Vågner", "Træt", 75)
        case 8..<12: return ("Arbejdstid", "Koncentreret", 90)
        case 12: return ("Pause", "Glad", 70)
        case 13..<18: return ("Arbejdstid", "Koncentreret", 65)
        case 18..<22: return ("Fri", "Stolt", 55)
        default: return ("Sover", "Træt", 40)
        }
    }

    private func traits(for id: UUID) -> [String] {
        let bytes = id.uuidString.utf8
        let seed = bytes.enumerated().reduce(0) { $0 + ($1.offset + 1) * Int($1.element) }
        return [0, 4, 8].map { Self.traits[(seed + $0) % Self.traits.count] }
    }

    private func partner(for bot: VillageBot) -> VillageBot? {
        let sorted = bots.sorted { $0.id.uuidString < $1.id.uuidString }
        guard sorted.count > 1, let index = sorted.firstIndex(where: { $0.id == bot.id }) else { return nil }
        let partnerIndex = index.isMultiple(of: 2) ? index + 1 : index - 1
        return sorted.indices.contains(partnerIndex) ? sorted[partnerIndex] : nil
    }

    private func energy(for id: UUID, base: Int, at date: Date) -> Int {
        let boost = Calendar.current.startOfDay(for: date) == blessingDay ? blessings[id, default: 0] : 0
        return min(100, base + boost)
    }

    private func bless(_ id: UUID, at date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if day != blessingDay {
            blessings.removeAll()
            blessingDay = day
        }
        blessings[id] = min(60, blessings[id, default: 0] + 20)
        note("Blev velsignet", for: id, at: date)
    }

    private func note(_ activity: String, for id: UUID, at date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        if eventDay != day {
            events.removeAll()
            eventDay = day
        }
        let timestamp = date.formatted(.dateTime.hour().minute())
        events[id] = Array((["\(timestamp) · \(activity)"] + events[id, default: []]).prefix(3))
    }

    private func createFounders() {
        guard ExperimentalVillageGate.available, founderRecord.isEmpty else { return }
        do {
            let store = MigratedAppData.shared
            let data = store.villageBots
            if !data.isEmpty {
                guard let existing = try? VillageBot.listRecovering(from: data), existing.isEmpty else { return }
            }
            let adam = VillageBot(name: "Adam", color: "Blå",
                                  prompt: "Hjælp med kode. Forklar og foreslå ændringer, som brugeren gennemgår.",
                                  personality: "Nysgerrig", specialty: "Kode")
            let eva = VillageBot(name: "Eva", color: "Lilla",
                                 prompt: "Hjælp med videoplaner. Foreslå klip, fortælling og opskrift.",
                                 personality: "Omsorgsfuld", specialty: "Video")
            try store.saveVillageBots(JSONEncoder().encode([adam, eva]))
            founderRecord = [adam.id, eva.id].map(\.uuidString).joined(separator: ",")
            seedError = nil
        } catch {
            AppDiagnostics.record(error)
            seedError = "Botterne kunne ikke gemmes. Prøv igen, eller tjek lagerpladsen."
        }
    }
}
